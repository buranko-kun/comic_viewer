# ComicViewer catalog format

Host a JSON file (any static web host works — nginx, S3, GitHub Pages, a VPS) and point the
app at its URL in **Settings → Sources** (or list one URL per line in a `.txt` and import it).
The app fetches every configured source, normalizes them, and shows the comics in the
**Online** section. Adding a new server never requires changing the app — just serve JSON in
this shape.

## Manifest shape

```json
{
  "name": "Your Server Name",
  "comics": [ /* … */ ],
  "catalogs": [ /* optional child manifests, shown as folders */ ]
}
```

### A comic

| field         | required | notes                                                                 |
|---------------|----------|-----------------------------------------------------------------------|
| `title`       | yes      | Display title.                                                        |
| `id`          | no       | Stable unique id; falls back to the title.                            |
| `description` | no       | Shown under the title and in the detail popover.                     |
| `cover`       | no       | Image URL (absolute or relative to the manifest).                    |
| `series`      | no       | Series/grouping name.                                                 |
| `format`      | no       | `cbz` / `cbr` / `zip`. Inferred from a mirror's extension if omitted. |
| `mirrors`     | yes      | Download URLs, tried in order. `url`/`download` singular also accepted. |
| `metadata`    | no       | Freeform map; values may be strings, numbers, or booleans.           |

Only archive formats the reader can open (`cbz`, `cbr`, `zip`, …) are downloadable; other
formats (e.g. PDF/EPUB) appear disabled.

### Child catalogs (folders)

`catalogs` may contain either a bare URL string or a `{ "name": …, "url": … }` object. Each
becomes a folder you can drill into — use them to split large collections and keep manifests
small.

All URLs (`cover`, `mirrors`, `catalogs`) may be **relative to the manifest URL**.

See `index.json` in this folder for a complete example. (OPDS feeds are also accepted — the
app auto-detects them — but JSON is the simplest to host.)
