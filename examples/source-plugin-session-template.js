// Fetch-based source: the app establishes homepage origin; context.url is the requested page.
// Keep cache keys prefixed with your plugin ID and clear only your own cached results.
globalThis.ComicViewerSource = {
    manifest: {
        id: "example.session", name: "Session source", version: "1.0.0", apiVersion: 1,
        homepage: "https://example.com", capabilities: ["browse", "read", "browser-session"]
    },
    browseURL: "https://example.com/comics",
    async document(context) {
        const response = await fetch(context.url, { credentials: "include", signal: context.signal });
        context.diagnostic({ type: "response", status: response.status });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return new DOMParser().parseFromString(await response.text(), "text/html");
    },
    async parseCatalog(context) {
        const doc = await this.document(context);
        return { comics: Array.from(doc.querySelectorAll(".comic-card")).map(card => {
            const anchor = card.querySelector("a");
            const image = card.querySelector("img");
            return {
                id: anchor.getAttribute("href"), title: anchor.textContent.trim(),
                link: new URL(anchor.getAttribute("href"), context.url).href, canRead: true,
                cover: image ? {
                    url: new URL(image.getAttribute("data-src") || image.getAttribute("src"), context.url).href,
                    referrer: context.url, useBrowserCookies: true
                } : null
            };
        }), catalogs: [] };
    },
    async parsePages(context) {
        const doc = await this.document(context);
        return { pages: Array.from(doc.querySelectorAll(".reader img")).map(image => ({
            url: new URL(image.getAttribute("data-src") || image.getAttribute("src"), context.url).href,
            referrer: context.url, useBrowserCookies: true
        })) };
    }
};
