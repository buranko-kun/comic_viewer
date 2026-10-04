# Internet Archive Comics plugin

Source plugin for the [Internet Archive Comics collection](https://archive.org/details/comics).

## Install

**Comic Viewer → Preferences → Sources → Source plugins** → choose `plugin.js`.

Plugin id: `archiveorg.comics`

## Behaviour

| Level | Source | Result |
|--------|--------|--------|
| Collection browse | Advanced Search API `collection:comics` | Items / nested collections |
| Nested collection | `collection:{id}` search | Child items |
| Item | `/metadata/{identifier}` | CBR / CBZ / PDF / ZIP download links |

Download URLs:

```text
https://archive.org/download/{identifier}/{filename}
```

Covers: `https://archive.org/services/img/{identifier}`

## Notes

- Public APIs only; no login required for metadata and most downloads.
- Some items are borrow-only or restricted; those may not list open files.
- Large CBR/CBZ files stream from IA; respect their bandwidth guidelines.

## Files

- `plugin.js`
- `README.md`
