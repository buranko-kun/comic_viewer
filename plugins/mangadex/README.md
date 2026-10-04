# MangaDex plugin

Source plugin for [MangaDex](https://mangadex.org/).

## Install

**Comic Viewer → Preferences → Sources → Source plugins** → choose `plugin.js`.

Plugin id: `mangadex`

## Behaviour

| Level | Source | Result |
|--------|--------|--------|
| Home / browse | Official API popular / search | Series (`opensCatalog`) |
| Series | `/title/{uuid}` → `/manga/{id}/feed` | Chapters (`canRead`) |
| Chapter | `/chapter/{uuid}` → at-home server | Page image URLs |

## Notes

- Uses the **public MangaDex API** (`api.mangadex.org`). No account required for reading.
- Default language filter: **English**. Other languages can be added later if needed.
- Follows MangaDex Acceptable Use Policy: credits the platform; no ads/paid overlay on their content.
- Rate limits exist on the at-home image servers — the plugin requests pages only when the reader needs them.

## Files

- `plugin.js`
- `README.md`
