# Comic Book Plus plugin

Source plugin for [Comic Book Plus](https://comicbookplus.com) — public-domain Golden and Silver Age comics (and related material).

## Install

In **Comic Viewer** → **Preferences** → **Sources** → **Source plugins**:

- Choose this `plugin.js` from disk, or<br>
- Paste a raw URL if you host the file

Plugin id: `comicbookplus`

## What it does

| Page type | URL shape | Plugin behaviour |
|-----------|-----------|------------------|
| Categories / home | `/?cbplus=categories`, `/` | Genre catalogs + featured/latest issues |
| Genre | `/?cbplus=adventure` (etc.) | Series catalogs (`?cid=`) |
| Series | `/?cid=885` | Issue list (`?dlid=`), each `canRead: true` |
| Issue | `/?dlid=40191` | Readable entry + `parsePages()` |

### Online reading (guest)

Issues use the site’s free HTML viewer:

- Cover / first page: `#maincomic` → e.g. `https://box01.comicbookplus.com/viewer/{xx}/{hash}/0.jpg`
- Page count: `[itemprop="numberOfPages"]`
- Pages: `0.jpg` … `{n-1}.jpg` under the same viewer folder<br>

`parsePages()` builds that list. Comic Viewer streams the images into the reader (`canRead: true`).

Image requests generally need a normal browser **Referer** from comicbookplus.com; the plugin WebView provides that when pages are loaded from the issue URL.

### Downloads

CBR/CBZ **file** downloads require a free CB+ account and are rate-limited by the site. This plugin does **not** automate archive downloads; it only uses the public online reader.

## Session / blocking

The site may show “unusual activity” blocks for some IPs or headless clients. Open the plugin homepage from **Preferences → Sources** so cookies/session live in the same WebView the plugin uses.

## Files

- `plugin.js` — `globalThis.ComicViewerSource` implementation<br>
- `README.md` — this file<br>
