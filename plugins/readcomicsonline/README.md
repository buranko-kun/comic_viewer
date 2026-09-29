# ReadComicsOnline plugin

This directory is a temporary, self-contained source package for ReadComicsOnline.

It exists in the ComicViewer repository only so the complete working source is easy to inspect, test, copy to local storage, and preserve while the built-in Swift connector is removed.

## Files

- `plugin.js`: the complete ComicViewer source plugin.
- This README documents the plugin's site-specific assumptions and setup.

## What the plugin provides

- Fast page-by-page catalog browsing with a Next page folder.
- Optional full catalog discovery: enable **Load entire catalog** in the source settings.
  This restores full-collection global search but can take several minutes on the first load.
  In default paged mode, global search only includes the root page's entries.
- A 14-day per-page and full-catalog cache in the plugin WebView's persistent local storage.
- Lazy-loaded cover extraction. Issue cards use the series cover instead of guessing a chapter filename.
- Series to chapter navigation.
- Chapter cards marked as readable with `canRead: true`.
- Exact chapter image discovery through `parsePages()`.
- CDN image URL filtering, de-duplication, and natural sorting.

## ComicViewer requirements

The plugin expects the generic ComicViewer source-plugin contract with:

- `manifest`
- `browseURL`
- `parseCatalog()`
- `parsePages()`
- support for `opensCatalog` and `canRead` catalog item capabilities

The plugin runs entirely in the ComicViewer plugin WebView. It uses normal browser JavaScript APIs,
DOM parsing, same-origin requests, cookies, and localStorage. No Swift source or filesystem access is
required by the plugin itself.

## Cloudflare / session behavior

The source can present a browser challenge. The plugin relies on the persistent WebView browser
session for the site's cookies and storage. Any future generic session/challenge support in
ComicViewer should remain source-agnostic; this directory should not require a ReadComics-specific
Swift implementation.

## Temporary repository policy

This is intentionally a temporary external-source package. Once the plugin has been verified and the
core app no longer contains any source-specific implementation, copy this directory to local storage
or a separate plugin repository and remove it from the ComicViewer repository.

The core app must not import, reference, or otherwise depend on files in this directory.

## Updating and verification

Install the local `plugin.js` again through Preferences → Sources to replace the installed copy
with version 1.3.0. A repository edit does not update an already-installed plugin. The new cache
namespace discards old parsed results that may contain missing or incorrect covers.

Run the offline parser and request-count regression checks:

```sh
node --test plugins/readcomicsonline/plugin.test.cjs
```

The Node suite provides fast logic regressions. The WebKit suite exercises actual saved HTML:

```sh
tools/test-source-plugin plugins/readcomicsonline/plugin.js plugins/readcomicsonline/fixtures/suite.json
```

The HTML is synthetic and sanitized, not a claim about the current live site. Live markup and image
delivery must also be checked in the app's authenticated session. Version 1.3.0 supplies image
referrer/cookie context, cancellation-aware fetches, refresh/cache hooks, and request diagnostics.
Full-catalog operations have a 900-second bound; individual requests time out after 25 seconds.
