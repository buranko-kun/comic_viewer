// Comic Viewer Source Plugin template.
//
// Install this file from Preferences -> Sources -> Source plugins.
// The plugin executes in the page context of browseURL and can use browser JavaScript + the DOM.
// It cannot access the Comic Viewer filesystem or native APIs.
//
// Required:
//   manifest
//   browseURL
//   parseCatalog()
//
// Optional:
//   searchURL(query)
//   parsePages()
//
// The manifest metadata is deliberately similar to HakuNeko's connector metadata:
// tags describe the source for filtering/discovery, while capabilities tell the app which
// operations the source intends to provide.

globalThis.ComicViewerSource = {
    manifest: {
        id: "example.my-source",
        name: "My Comic Source",
        version: "1.0.0",
        homepage: "https://example.com",
        description: "Example source plugin",
        tags: ["comic", "english"],
        capabilities: ["browse", "search", "read"]
    },

    browseURL: "https://example.com/comics",

    searchURL(query) {
        return "https://example.com/search?q=" + encodeURIComponent(query);
    },

    parseCatalog() {
        const comics = Array.from(document.querySelectorAll(".comic-card")).map((card, index) => {
            const anchor = card.querySelector("a");
            const image = card.querySelector("img");
            const title = card.querySelector(".title");

            return {
                id: anchor ? anchor.href : String(index),
                title: title ? title.textContent.trim() : "Untitled",
                link: anchor ? anchor.href : null,
                cover: image ? image.src : null,
                mirrors: []
            };
        });

        return {
            name: "My Comic Source",
            comics,
            catalogs: []
        };
    },

    async parsePages() {
        return {
            pages: Array.from(document.querySelectorAll("img"))
                .map(image => image.src)
                .filter(Boolean)
        };
    }
};
