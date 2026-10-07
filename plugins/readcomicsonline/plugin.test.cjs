// Run with: node --test plugins/readcomicsonline/plugin.test.cjs
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const origin = 'https://readcomicsonline.ru';
const cover = `${origin}/uploads/manga/alpha/cover/cover.jpg`;
const element = (attrs, textContent = '') => ({
    getAttribute: key => attrs[key] ?? null, textContent,
    querySelectorAll: () => [], parentElement: null
});
function catalog(page, pageCount = 3) {
    return {
        querySelectorAll(selector) {
            if (selector === 'img') return [element({ src: '/placeholder.gif', 'data-src': cover })];
            if (selector.includes('comic-list?page=')) return [element({ href: `/comic-list?page=${pageCount}` })];
            return [element({ href: `/comic/${page === 1 ? 'alpha' : `series-${page}`}` }, `Series ${page}`)];
        }
    };
}
function runtime({ pageCount = 3, onFetch } = {}) {
    const calls = [], cache = new Map();
    const context = vm.createContext({
        URL, document: { baseURI: `${origin}/comic/unrelated/` },
        location: { href: origin },
        localStorage: { getItem: k => cache.get(k) ?? null, setItem: (k, v) => cache.set(k, v),
            removeItem: k => cache.delete(k), key: i => [...cache.keys()][i] ?? null,
            get length() { return cache.size; } },
        setTimeout: (fn, ms) => ms < 25000 ? setTimeout(fn, 0) : setTimeout(fn, ms),
        clearTimeout, AbortController, DOMException,
        fetch: async url => {
            calls.push(url);
            if (onFetch) return onFetch(url);
            return { ok: true, text: async () => Number(new URL(url).searchParams.get('page')) || 1 };
        },
        DOMParser: class { parseFromString(page) { return catalog(page, pageCount); } }
    });
    const source = fs.readFileSync(`${__dirname}/plugin.js`, 'utf8');
    vm.runInContext(source.replace('    globalThis.ComicViewerSource = {',
        '    globalThis.parsers = { imageURL, pageURLs, chapterEntries, localCardImage };\n    globalThis.ComicViewerSource = {'), context);
    return { source: context.ComicViewerSource, parsers: context.parsers, calls };
}
async function completeCatalog(source, context = {}) {
    let result = await source.parseCatalog(context);
    const comics = [...result.comics];
    while (result.continuationURL) {
        result = await source.parseCatalog({ url: result.continuationURL });
        comics.push(...result.comics);
    }
    return comics;
}
test('first batch appears after one request and subsequent batches complete the cached catalogue', async () => {
    const { source, calls } = runtime();
    const first = await source.parseCatalog();
    assert.equal(calls.length, 1);
    assert.equal(first.comics.length, 1);
    assert.equal(first.comics[0].cover.url, cover);
    assert.equal(first.catalogs.length, 0);
    assert.equal(first.continuationURL, `${origin}/comic-list?page=2`);
    const second = await source.parseCatalog({ url: first.continuationURL });
    assert.equal(second.comics.length, 2);
    assert.equal(second.continuationURL, null);
    assert.equal(calls.length, 3);
    const warm = await source.parseCatalog();
    assert.equal(warm.comics.length, 3);
    assert.equal(warm.continuationURL, undefined);
    assert.equal(calls.length, 3);
});
test('legacy paged setting does not produce pagination folders', async () => {
    const { source, calls } = runtime();
    source.settings = { fullCatalog: false };
    const first = await source.parseCatalog();
    assert.equal(first.catalogs.length, 0);
    const comics = await completeCatalog(source);
    assert.equal(comics.length, 3);
    assert.equal(calls.length, 3);
});
test('larger batches use at most two requests and preserve website page order', async () => {
    let active = 0, peak = 0;
    const { source, calls } = runtime({ pageCount: 9, onFetch: async url => {
        active++; peak = Math.max(peak, active);
        const page = Number(new URL(url).searchParams.get('page'));
        await new Promise(resolve => setTimeout(resolve, page % 2 ? 10 : 20));
        active--;
        return { ok: true, text: async () => page };
    }});
    const first = await source.parseCatalog();
    assert.equal(calls.length, 1);
    const batch = await source.parseCatalog({ url: first.continuationURL });
    assert.equal(batch.comics.length, 6);
    assert.equal(peak, 2);
    assert.deepEqual(Array.from(batch.comics, c => c.title), [2,3,4,5,6,7].map(n => `Series ${n}`));
    assert.equal(batch.continuationURL, `${origin}/comic-list?page=8`);
    await source.parseCatalog({ url: batch.continuationURL });
    const warm = await source.parseCatalog();
    assert.equal(warm.comics.length, 9);
    assert.equal(calls.length, 9);
});
test('site rejection retries without losing pages and slows subsequent batches to one request', async () => {
    let active = 0, peak = 0, rejected = false;
    const { source } = runtime({ pageCount: 15, onFetch: async url => {
        active++; peak = Math.max(peak, active);
        const page = Number(new URL(url).searchParams.get('page'));
        await new Promise(resolve => setTimeout(resolve, 5));
        active--;
        if (page === 3 && !rejected) {
            rejected = true;
            return { ok: false, status: 520 };
        }
        return { ok: true, text: async () => page };
    }});
    const first = await source.parseCatalog();
    const batch = await source.parseCatalog({ url: first.continuationURL });
    assert.equal(batch.comics.length, 6);
    assert.equal(rejected, true);
    peak = 0;
    const slower = await source.parseCatalog({ url: batch.continuationURL });
    assert.equal(slower.comics.length, 6);
    assert.equal(peak, 1);
});
test('reader discovers lazy images, deduplicates, and naturally sorts pages', () => {
    const { parsers } = runtime();
    const prefix = 'https://cdn.readcomicsonline.ru/uploads/manga/alpha/chapters/1/';
    const images = ['10.jpg', '2.jpg', '2.jpg'].map(name => element({
        src: '/placeholder.gif', 'data-original': prefix + name
    }));
    images.push(element({ src: cover }));
    assert.deepEqual(Array.from(parsers.pageURLs({ querySelectorAll: () => images }, origin)),
        [prefix + '2.jpg', prefix + '10.jpg']);
});
test('relative chapters resolve against fetched series, using its actual cover', () => {
    const { parsers } = runtime();
    const entries = parsers.chapterEntries({ querySelectorAll: () => [element({ href: '1' }, '#1')] },
        { slug: 'alpha', title: 'Alpha', cover }, `${origin}/comic/alpha/`);
    assert.equal(entries.length, 1);
    assert.equal(entries[0].link, `${origin}/comic/alpha/1`);
    assert.equal(entries[0].cover.url, cover);
});
test('missing cover does not borrow an unrelated card image', () => {
    const { parsers } = runtime();
    const anchor = element({ href: '/comic/missing' });
    anchor.parentElement = { querySelectorAll: selector => selector === 'img'
        ? [element({ src: cover })]
        : [anchor, element({ href: '/comic/alpha' })] };
    assert.equal(parsers.localCardImage(anchor, origin), null);
});

test('explicit refresh bypasses cached parsed data', async () => {
    const { source, calls } = runtime();
    await completeCatalog(source);
    await completeCatalog(source, { refresh: true });
    assert.equal(calls.length, 6);
    source.clearCache();
    await completeCatalog(source);
    assert.equal(calls.length, 9);
});
test('already cancelled operation does not fetch', async () => {
    const { source, calls } = runtime();
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(source.parseCatalog({ signal: controller.signal }), { name: 'AbortError' });
    assert.equal(calls.length, 0);
});
