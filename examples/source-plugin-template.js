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
//
// The output of parseCatalog() is converted into the app's normalized RemoteComic model.

globalThis.ComicViewerSource = {
    manifest: {
        id: "example.my-source",
        name: "My Comic Source",
        version: "1.0.0",
        homepage: "https://example.com",
        description: "Example source plugin"
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
    }
};
