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
function catalog(page) {
    return {
        querySelectorAll(selector) {
            if (selector === 'img') return [element({ src: '/placeholder.gif', 'data-src': cover })];
            if (selector.includes('comic-list?page=')) return [element({ href: '/comic-list?page=3' })];
            return [element({ href: `/comic/${page === 1 ? 'alpha' : `series-${page}`}` }, `Series ${page}`)];
        }
    };
}
function runtime() {
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
            return { ok: true, text: async () => Number(new URL(url).searchParams.get('page')) || 1 };
        },
        DOMParser: class { parseFromString(page) { return catalog(page); } }
    });
    const source = fs.readFileSync(`${__dirname}/plugin.js`, 'utf8');
    vm.runInContext(source.replace('    globalThis.ComicViewerSource = {',
        '    globalThis.parsers = { imageURL, pageURLs, chapterEntries, localCardImage };\n    globalThis.ComicViewerSource = {'), context);
    return { source: context.ComicViewerSource, parsers: context.parsers, calls };
}
test('first browse requests one page, extracts lazy cover, and caches repeated browsing', async () => {
    const { source, calls } = runtime();
    const result = await source.parseCatalog();
    assert.equal(calls.length, 1);
    assert.equal(result.comics[0].cover.url, cover);
    assert.equal(result.catalogs[0].url, `${origin}/comic-list?page=2`);
    await source.parseCatalog();
    assert.equal(calls.length, 1);
    const last = await source.parseCatalog({ url: `${origin}/comic-list?page=3` });
    assert.equal(calls.length, 2);
    assert.equal(last.catalogs.length, 0);
});
test('full catalog is opt-in and caches all three pages', async () => {
    const { source, calls } = runtime();
    source.settings = { fullCatalog: true };
    const result = await source.parseCatalog();
    assert.equal(result.comics.length, 3);
    assert.equal(calls.length, 3);
    assert.equal(result.catalogs.length, 0);
    await source.parseCatalog();
    assert.equal(calls.length, 3);
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
    await source.parseCatalog();
    await source.parseCatalog({ refresh: true });
    assert.equal(calls.length, 2);
    source.clearCache();
    await source.parseCatalog();
    assert.equal(calls.length, 3);
});
test('already cancelled operation does not fetch', async () => {
    const { source, calls } = runtime();
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(source.parseCatalog({ signal: controller.signal }), { name: 'AbortError' });
    assert.equal(calls.length, 0);
});
