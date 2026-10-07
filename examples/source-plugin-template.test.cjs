const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const script = fs.readFileSync(path.join(__dirname, 'source-plugin-template.js'), 'utf8');
function source(selectors = {}) {
    const context = vm.createContext({
        document: { querySelectorAll: selector => selectors[selector] || [] }
    });
    vm.runInContext(script, context);
    return context.ComicViewerSource;
}
const plain = value => JSON.parse(JSON.stringify(value));

test('example manifest declares a generic readable source', () => {
    const plugin = source();
    assert.equal(plugin.manifest.id, 'example.my-source');
    assert.equal(plugin.manifest.apiVersion, 1);
    assert.deepEqual(plain(plugin.manifest.capabilities), ['browse', 'read']);
    assert.equal(new URL(plugin.browseURL).hostname, 'example.com');
});

test('catalogue cards keep their own titles, links, and covers', () => {
    const cards = ['one', 'two'].map(id => ({ querySelector(selector) {
        return {
            a: { href: `https://example.com/issues/${id}` },
            img: { src: `https://example.com/covers/${id}.jpg` },
            '.title': { textContent: ` Example ${id} ` }
        }[selector];
    }}));
    const result = plain(source({ '.comic-card': cards }).parseCatalog());
    assert.deepEqual(result.comics.map(comic => comic.title), ['Example one', 'Example two']);
    assert.deepEqual(result.comics.map(comic => comic.cover), [
        'https://example.com/covers/one.jpg', 'https://example.com/covers/two.jpg'
    ]);
    assert.equal(result.comics[1].link, 'https://example.com/issues/two');
    assert.equal(result.comics[0].canRead, true);
});

test('missing optional card elements return safe fallback values', () => {
    const plugin = source({ '.comic-card': [{ querySelector: () => null }] });
    const comic = plain(plugin.parseCatalog()).comics[0];
    assert.equal(comic.id, '0');
    assert.equal(comic.title, 'Untitled');
    assert.equal(comic.cover, null);
    assert.equal(comic.link, null);
});

test('reader extracts page URLs in DOM order and omits empty URLs', async () => {
    const plugin = source({ '.reader img': [
        { src: 'https://example.com/pages/one.jpg' },
        { src: '' },
        { src: 'https://example.com/pages/two.jpg' }
    ] });
    assert.deepEqual(plain(await plugin.parsePages()).pages, [
        'https://example.com/pages/one.jpg', 'https://example.com/pages/two.jpg'
    ]);
});
