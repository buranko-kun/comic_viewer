# GetComics source plugin

Ports the discovery and extraction logic from `scripts/getURLs.py` and
`scripts/extractData_v2.py` into ComicViewer's source plugin API. The original
scripts are unchanged.

## Install and browse

1. Open ComicViewer → Settings → Sources → **Install local .js…**.
2. Select `plugins/getcomics/plugin.js`.
3. Browse GetComics. Listing cards include covers; open a card to fetch that
   post's title, cover, size, and download mirrors.
4. Use the resolved comic's download controls to choose a mirror. **Next page**
   loads another listing; **All posts (sitemap)** opens the paginated text index.

Sitemap entries get covers when their post is opened. This plugin provides
archive download links, not streaming reader pages. Some mirrors lead to host
landing pages and may require opening the browser; extraction does not guarantee
that every host is supported by the app's downloader.

## Performance and recovery

Version 1.0.1 uses the app's `static-session` capability: a blank same-origin
worker provides fetch, cookies, and storage without loading homepage scripts or
ads first. This requires an app build with `static-session` support. After updating
the app, reload or reinstall the plugin to update the installed manifest.

Each browse operation fetches one page rather than crawling the whole site.
Listings are cached for 15 minutes and post details for 24 hours, with a maximum
of 40 cached pages. Refresh bypasses the requested page's cache; the source
development panel's clear-cache operation removes all GetComics cache entries.
Requests support cancellation, a 25-second timeout per attempt, and up to three
attempts for transient failures. HTTP rejection and unexpected listing markup
produce actionable errors instead of a silently empty catalog.

Signed mirror URLs and MEGA fragment keys are preserved. Mirror extraction starts
at the free-download heading and stops at Notes, excluding surrounding adverts.

## Verification

```sh
tools/test-source-plugin plugins/getcomics/plugin.js plugins/getcomics/fixtures/suite.json
```

To check actual network startup (not mocked fixtures), run the app executable with
`--plugin-live plugins/getcomics/plugin.js https://getcomics.org/`. This uses the
browser session and writes the plugin cache; it prints counts rather than mirror URLs.

The eight offline WebKit fixtures cover covers, warm-cache request counts,
pagination, sitemap deduplication, exact signed mirror URLs, missing mirrors,
HTTP rejection, challenge markup, and wrong-site URLs. The fixture runner also
supports assertions on mirrors, sizes, formats, and mirror availability.

During development, three captured live-page checks passed (home, post, sitemap).
The post result matched the original Python extractor's title, cover, size, and
five mirrors. No comic archives were downloaded during verification.
