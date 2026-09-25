# Comic Viewer source plugins

Source plugins let people add online scrapers without changing or forking Comic Viewer. A plugin
is a small JavaScript file installed from a URL (including raw GitHub) or a local .js file.

## How it works

The plugin runs inside a dedicated WKWebView page context. It can use browser JavaScript, DOM APIs,
and web requests available to that page. It does not receive Swift objects, filesystem access, or
native application APIs.

Because plugins are third-party code, only install plugins you trust.

## Plugin shape

A plugin assigns a source object to globalThis.ComicViewerSource.

    globalThis.ComicViewerSource = {
        manifest: {
            id: "example.my-source",
            name: "My Comic Source",
            version: "1.0.0",
            homepage: "https://example.com",
            description: "Example source"
        },

        browseURL: "https://example.com/comics",

        parseCatalog() {
            return {
                name: "My Comic Source",
                comics: [],
                catalogs: []
            };
        }
    };

manifest, browseURL, and parseCatalog() are required. parseCatalog() can be async.

browseURL can be a URL string or a function that returns one.

searchURL(query) is optional in the v1 schema. The current Online screen already performs local search
across loaded plugin results; a network search hook is reserved for a future source-aware search UI.

## Catalog result

Each comic may provide:

- id
- title
- description
- cover
- series
- format
- mirrors
- hasMirrors
- link
- size
- mustRead
- mustReadTitle
- metadata

Child folders use:

    catalogs: [
        { name: "Spider-Man", url: "https://example.com/comics/spider-man" }
    ]

Relative cover, link, mirror, and child-catalog URLs are resolved against the page being parsed.

## Installing

Open Preferences -> Sources. Under Source plugins, paste a plugin URL or choose a local .js file.

Installed plugins can be enabled or disabled, updated, or removed without rebuilding the app.

A GitHub URL in the form github.com/owner/repo/blob/ref/path.js is automatically converted to the
raw file URL.

## Updating

The app uses manifest.id as the stable plugin identity. Installing or updating another plugin with
the same id replaces the installed script while preserving the existing enabled/disabled setting.
