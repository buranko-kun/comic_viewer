# Comic Viewer source plugins

A source plugin is one JavaScript file assigning `globalThis.ComicViewerSource`. Install it from
Preferences → Sources using a local `.js` file or an HTTP(S) URL. GitHub blob URLs are normalized
to raw URLs. No app rebuild, package manager, or JavaScript build step is required.

Plugins run in WebKit's page context with browser JavaScript and DOM APIs. They have no native
filesystem API. Install only scripts you trust. The optional declarations in
`examples/source-plugin.d.ts` describe the supported API. Start with
`examples/source-plugin-template.js` (page DOM) or `examples/source-plugin-session-template.js`
(authenticated, fetch-based scraping).

## Development loop

1. Install your local file once, then choose **Develop** beside the source in Preferences.
2. Edit the original file and select **Reload from file**. The panel shows the installed SHA-256;
   a version bump is not required. Files are copied on installation, not watched automatically.
3. Run Validate manifest, Browse root/URL, Resolve pages, or Probe image. Inspect the normalized
   result, optional raw JSON, console/diagnostic events, field-path warnings, and timings.
4. Use **Open source session** for login/challenges. Its browser shares persistent website data
   with the scraper but cannot navigate its worker.
5. Use **Clear plugin cache** when the plugin implements `clearCache()`. It must remove only its
   own cached results, not authentication state. Source refresh also passes `context.refresh`.

Invalid scripts, identity-changing updates, and failed registry writes preserve the last installed
version. Reload invalidates only that plugin's worker/results. Settings use Apply/Cancel and refresh
only the changed source. Successful sources remain visible while others load. Development previews
use the same resource transport as Browse and Reader.

Recent diagnostics stay in memory (50 runs). Raw/normalized captures are enabled only while the
panel is open and limited to 64 KiB each. Copy displayed output explicitly if it is needed for local
investigation. Diagnostic report export excludes payloads and plugin-authored console messages,
and redacts URL query values. There is no telemetry upload.

## Contract

Required members:

```js
globalThis.ComicViewerSource = {
    manifest: { id: "example.source", name: "Example", version: "1.0", apiVersion: 1 },
    browseURL: "https://example.com/comics",
    parseCatalog(context) { return { name: "Example", comics: [], catalogs: [] }; }
};
```

`manifest.apiVersion` defaults to 1 for old plugins; unsupported versions fail validation.
`browseURL` may also be an async function. Optional manifest fields include homepage, description,
tags, capabilities, settings, and `operationTimeoutSeconds` (1–900, default 60). Navigation has an
independent 30-second timeout. A timed-out or cancelled worker is discarded before its next run.
There are at most two active plugin operations; each source's operations serialize.

Both parsing hooks receive an optional context (old no-argument functions remain supported):

- `url`: requested catalog or issue URL.
- `settings`: effective source settings, also available as `ComicViewerSource.settings`.
- `refresh`: bypass parsed-data caches when true.
- `operationID`: diagnostic identifier.
- `signal`: cancellation signal for fetch/sleep helpers; host cancellation also terminates the worker.
- `diagnostic(event)`: optional structured cache/retry/request information; events are bounded.

Without `browser-session`, the app loads the target page before parsing. With that capability, the
app establishes `manifest.homepage` origin and the plugin fetches `context.url` itself. A fetched
DOMParser document does not inherit the response URL: explicitly resolve relative attributes against
`context.url`. Do not use the unrelated session page's `location` for fetched documents.

`parseCatalog` returns optional `name`, `comics`, and `catalogs` arrays. Each comic may contain id,
title, description, cover, series, format, mirrors, hasMirrors, link, size, mustRead, mustReadTitle,
metadata, opensCatalog, and canRead. A child catalog has `{name, url}`. Relative URLs resolve against
the requested page. HTTP(S) is required; invalid optional fields generate warnings. Existing primitive
coercions remain supported with warnings. Duplicate IDs are disambiguated.

Set `opensCatalog: true` to browse a series; set `canRead: true` to resolve an issue through
`parsePages(context)`, returning `{pages: [...]}` in reading order. Declaring `read` requires a
`parsePages` hook. Duplicate page requests are removed. Browse and Search use the same opening
behavior. Local search covers loaded root entries; `searchURL` remains reserved and is not invoked.

## Images and authenticated resources

Cover and page entries accept either a string URL (legacy, no browser cookies) or:

```js
{ url: "https://cdn.example.com/page.jpg", referrer: context.url, useBrowserCookies: true }
```

Relative resource/referrer URLs are supported. Plugin identity is attached by the host, not supplied
by scripts. Browser cookies are selected by destination domain/path, expiry, and secure flag, and
reselected for redirects. Cross-origin referrers are reduced to their origin. HTTPS-to-HTTP redirects
are rejected. Cookie values are not written into history or exported reports.

The resource context survives reader/history restoration; caches separate image size, context,
source revision, and cookie-session epoch. Cookie-backed covers are memory-only. Native HTTP
transport can still be rejected by browser-bound challenges: use Probe image to distinguish an HTTP
rejection from bad extraction or invalid image bytes. Opening the source session does not guarantee
that a website will permit native image downloads.

## Settings

A setting declares id, title, type, defaultValue, optional description, and optional options.
Types: string/text/password, number, bool/boolean/toggle, and select/picker. IDs must be unique;
default values must match the type and select options. Settings persist separately from plugin code.

## Automated tests

Run the production WebKit runtime against saved HTML without live site access:

```sh
tools/test-source-plugin examples/source-plugin-template.js examples/source-plugin-fixtures/suite.json
```

The wrapper builds into `build/plugin-tests`; set `COMIC_VIEWER_TEST_BINARY` to reuse an existing
Debug app executable. Exit status is nonzero for errors, failed expectations, or timeouts.

A suite has a `cases` array. A case accepts:

- name, url, operation (`catalog` or `pages`), settings, repeat (default 1).
- html or htmlFile: initial DOM; files are relative to the suite.
- responses: URL → `{status, body, headers}` or `{status, file, headers}` for fetch fixtures.
- expected: normalized-output subset; arrays require exact length and order.
- expectedError: required error substring instead of successful output.
- requestCount: total fetch calls, including repeated warm runs.

Each case has fresh nonpersistent storage. Repeats share that case's cache. Actual DOM selectors run
unchanged; fetch uses declared fixture responses, external subresources are blocked, and undeclared
requests fail. Cookies, redirects and native image decoding are tested separately against a loopback
HTTP server in XCTest. Fixture success does not establish live-site compatibility.

The macOS CI workflow runs XCTest, Node regressions, and the generic template WebKit HTML suite. Live-site smoke
checks remain manual: login if necessary, root → next page → series → issue, confirm visible covers
and reader pages, and compare cold/warm diagnostic timings and request counts.
