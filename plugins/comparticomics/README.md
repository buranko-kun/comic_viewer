# CompartiComics plugin

Source plugin for [CompartiComics](https://comparticomics.lat) — a large Spanish-language comic archive library (CBR / CBZ / RAR downloads).

## Install

In **Comic Viewer** → **Preferences** → **Sources** → **Source plugins**:

- Choose this `plugin.js` from disk, or
- Paste a raw URL if you host the file (GitHub raw, etc.)

Plugin id: `comparticomics` (updating a file with the same id replaces the script and keeps enable/disable state).

## What it does

| Level | Behaviour |
|--------|-----------|
| Root (`/biblioteca`) | Latest groups + category list as child catalogs |
| Category (`?cat=…`) | Paginated groups from `/api/groups` |
| Search (`?q=…`) | Same API with text query |
| Multi-volume group | Nested catalog of each volume |
| Single volume | Direct download link |

Each downloadable item uses:

```text
https://comparticomics.lat/api/download/{volumeId}
```

Covers are loaded from the site CDN:

```text
https://pub-66468df6e7e04d23a0daed8394f7fb9c.r2.dev/{cover_msg_id}.jpg
```

## Important limits

- **Archive source, not page streamer.** Entries have `canRead: false`. Comic Viewer should treat `link` as an archive download (CBR/CBZ/RAR), not run `parsePages()`.
- **Guest rate limits.** The site enforces daily file-count and bandwidth caps for anonymous users. Registering on the site raises limits; donations fund bandwidth.
- **Spanish catalog.** Almost all comics are in Spanish (per site policy).
- **Session / popups.** Donation modals may appear in the embedded browser. Use **Preferences → Sources** → open the plugin homepage so cookies persist for the plugin WebView.

## API surface used

- `GET /api/categories`
- `GET /api/groups?category=&q=&page=&page_size=`
- `GET /api/group/{cover_msg_id}`
- `GET /api/download/{volume_id}` (archive binary)
- Cover CDN as above

No Swift or filesystem access is required; the plugin runs entirely in the Comic Viewer plugin WebView.

## Files

- `plugin.js` — complete `globalThis.ComicViewerSource` implementation
- `README.md` — this file
