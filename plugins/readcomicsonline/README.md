# ReadComicsOnline plugin

This directory is a temporary, self-contained source package for ReadComicsOnline.

It exists in the ComicViewer repository only so the complete working source is easy to inspect, test, copy to local storage, and preserve while the built-in Swift connector is removed.

## Files

- `plugin.js`: the complete ComicViewer source plugin.
- This README documents the plugin's site-specific assumptions and setup.

## What the plugin provides

- Full paginated catalog discovery from the site's comic list.
- A 14-day catalog cache in the plugin WebView's persistent local storage.
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
