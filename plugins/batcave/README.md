# BatCave plugin

Source plugin for [batcave.biz](https://batcave.biz) — large online comic library (Marvel, DC, Image, etc.).

## Install

**Comic Viewer → Preferences → Sources → Source plugins** → choose this `plugin.js` (or a raw URL).

Plugin id: `batcave`

## Cloudflare (required once)

The site is protected by Cloudflare. Before browsing:

1. Open **Preferences → Sources**
2. Open this plugin’s homepage in the embedded source browser
3. Complete **Verify you are human**

The plugin WebView reuses that session.

## Behaviour

| Page | URL pattern | Result |
|------|-------------|--------|
| Comics list / popular | `/comix/`, `/comix/page/N/` | Series cards (`opensCatalog`) |
| Home / latest | `/`, `/page/N/` | Latest series |
| Search | `/search/{query}/` | Series results |
| Series | `/{id}-{slug}.html` | Chapters from `window.__DATA__` (`canRead`) |
| Reader | `/reader/{newsId}/{chapterId}…` | Page list via API |

### Page images

`POST /engine/ajax/controller.php?mod=api&action=reader/getChapterData`<br>
Body: `{ "news_id": "…", "chapter_id": "…" }`<br>
→ `data.images[]` (absolute or site-relative URLs)

Falls back to reader DOM images if the API fails.

## Notes

- Structure aligned with the public Keiyoushi / Tachiyomi BatCave extension selectors and API.
- No archive download automation — online page streaming only.
- If Cloudflare blocks again, re-open the source browser and verify.

## Files

- `plugin.js`
- `README.md`
