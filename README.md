# ReadComicsOnline Comic Viewer plugin

Standalone source plugin for ComicViewer.

## Install

Install from the raw GitHub URL below, or download `plugin.js` and use Preferences -> Sources -> Install local .js.

`https://raw.githubusercontent.com/buranko-kun/comic_viewer/readcomicsonline-plugin/plugin.js`

## Requirements

ComicViewer with the generic source-plugin system supporting:
- `manifest`
- `browseURL`
- `parseCatalog()`
- `parsePages()`
- `opensCatalog`
- `canRead`

## Behavior

Provides:
- full paginated catalog discovery
- 14-day catalog cache in persistent plugin storage
- series -> chapter navigation
- direct streamed chapter reading
- CDN page discovery, de-duplication, and natural sorting
- a generic ComicViewer browser session for login/cookie/browser challenges

The plugin contains all ReadComicsOnline-specific site logic. The ComicViewer core does not depend on it.

## Source

Website: https://readcomicsonline.ru

The site may present a browser challenge. Open the plugin's browser session from Preferences -> Sources before browsing if needed.
