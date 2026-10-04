# GlobalComix plugin

Source plugin for [GlobalComix](https://globalcomix.com/browse/comics).

## Install

**Comic Viewer → Preferences → Sources → Source plugins** → choose `plugin.js`.

Plugin id: `globalcomix`

## Behaviour

| Page | Pattern | Result |
|------|---------|--------|
| Browse / genres | `/browse/comics`, `/browse/comics/{genre}` | Series (`opensCatalog`) from `__INITIAL_STATE__` or DOM |
| Series | `/c/{slug}` | Releases under `/c/{slug}/r/{uuid}` (`canRead`) |
| Release reader | `/c/{slug}/r/{uuid}` | Best-effort `parsePages()` from DOM images |

## Notes

- Official API (`api.globalcomix.com`) requires a proprietary client header; the plugin uses embedded React Query state + DOM instead.
- Many series are **Gold** / account-gated. Free releases may still only show previews without login.
- For best results, open GlobalComix in the plugin source browser and log in if you have an account.

## Files

- `plugin.js`
- `README.md`
