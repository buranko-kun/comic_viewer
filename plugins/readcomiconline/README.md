# ReadComicOnline plugin

Source plugin for [ReadComicOnline](https://readcomiconline.li/).

## Install

**Comic Viewer → Preferences → Sources → Source plugins** → choose `plugin.js`.

Plugin id: `readcomiconline`

## Behaviour

| Page | Pattern | Result |
|------|---------|--------|
| Home / lists | `/`, genre, publisher, search | Series (`opensCatalog`) |
| Series | `/Comic/{slug}` | Issue list (`canRead`) |
| Issue reader | `/Comic/{slug}/Issue-N?id=…` or `/Full` | Page images via `parsePages()` |

## Notes

- **Cloudflare / CAPTCHA** is frequent. Open the site in the plugin source browser and solve the challenge once; the session usually sticks.
- Disable aggressive ad-blockers if the site complains — some features depend on scripts.
- Image URLs are often loaded dynamically; the plugin scrapes `#divImage` / `data-src` and common JS image arrays.
- Backup domain sometimes used: `rcostation.xyz`.

## Files

- `plugin.js`
- `README.md`
