# ZipComic plugin

Source plugin for [ZipComic](https://zipcomic.com/).

## Install

**Comic Viewer → Preferences → Sources → Source plugins** → choose `plugin.js`.

Plugin id: `zipcomic`

## Behaviour

| Page | Result |
|------|--------|
| Home / lists / series | Catalog entries (`opensCatalog` or `canRead`) |
| Reader | Page images via `parsePages()` |

## Notes

- Similar aggregator style to ReadComicOnline.
- Cloudflare may appear on first visit — solve it in the plugin source browser.
- DOM + common image-array patterns used for page discovery.

## Files

- `plugin.js`
- `README.md`
