# Digital Comic Museum plugin

Source plugin for [Digital Comic Museum](https://digitalcomicmuseum.com/).

## Install

**Comic Viewer → Preferences → Sources → Source plugins** → choose `plugin.js`.

Plugin id: `digitalcomicmuseum`

## Behaviour

| Page | Pattern | Result |
|------|---------|--------|
| Home / publisher index | `/` or `/index.php` | Publisher categories (`opensCatalog`) |
| Publisher / series | `?cid=` | Issue list with Preview / Download links |
| Preview reader | `/preview/index.php?did=…&page=…` | `canRead` + `parsePages()` |

## Notes

- All material is researched public-domain Golden Age (generally pre-1960).
- **Free account required** for downloads and full PREVIEW reading. Register on the site, then log in inside the plugin source browser.
- Cloudflare challenge may appear on first visit — solve it once in the source browser; the session usually persists.
- Downloads are CBR/CBZ/ZIP; the plugin surfaces Preview URLs for in-app reading when available.

## Files

- `plugin.js`
- `README.md`
