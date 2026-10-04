// Comic Viewer source plugin for ZipComic (zipcomic.com).
// Install from Preferences -> Sources -> Source plugins.
//
// Aggregator-style comic reader similar to ReadComicOnline.
// Series and issue pages expose readable chapters; Cloudflare may appear.
//
// Open the homepage once in the plugin source browser and solve any
// challenge so the WebView session works.

(() => {
    const ORIGIN = "https://zipcomic.com";

    function absolute(raw, base = location.href) {
        if (!raw) return null;
        try {
            return new URL(raw, base).href;
        } catch (_) {
            return null;
        }
    }

    function clean(text) {
        return (text || "").replace(/\s+/g, " ").trim();
    }

    function pathOf(url = location.href) {
        try {
            return new URL(url).pathname;
        } catch (_) {
            return "";
        }
    }

    function pageTitle() {
        const t = clean(document.title || "");
        return t
            .replace(/\s*[-–—|]\s*ZipComic.*$/i, "")
            .replace(/\s*Hot Comic.*$/i, "")
            .trim() || "ZipComic";
    }

    function isSeriesOrList() {
        const p = pathOf();
        // Home, genre, or series index pages
        return p === "/" || /\/(genre|publisher|comic|series|list|hot|latest)/i.test(p);
    }

    function looksLikeIssue(href) {
        if (!href) return false;
        try {
            const path = new URL(href).pathname;
            return /issue|chapter|ch-|read|full|\d+/i.test(path) && !/genre|publisher|list/i.test(path);
        } catch (_) {
            return false;
        }
    }

    function parseListItems() {
        const items = [];
        const seen = new Set();

        const anchors = document.querySelectorAll(
            "a[href], .comic-item a, .item a, .series a, .cover a, article a"
        );
        for (const a of anchors) {
            const href = absolute(a.getAttribute("href"));
            if (!href || !href.startsWith(ORIGIN) || seen.has(href)) continue;
            const title = clean(a.getAttribute("title") || a.textContent);
            if (!title || title.length < 2) continue;
            if (/login|register|home|contact|about|privacy/i.test(title)) continue;

            seen.add(href);
            let cover = null;
            const img = a.querySelector("img") || a.parentElement?.querySelector("img");
            if (img?.src) cover = absolute(img.src);

            const issue = looksLikeIssue(href);
            items.push({
                title: title.slice(0, 150),
                url: href,
                cover: cover || undefined,
                opensCatalog: !issue,
                canRead: issue,
            });
            if (items.length >= 60) break;
        }
        return items;
    }

    function parseReaderImages() {
        const imgs = [];
        const seen = new Set();
        const nodes = document.querySelectorAll(
            "#divImage img, .viewer img, .reader img, .page img, img[data-src], img.comic-page"
        );
        for (const img of nodes) {
            const src =
                img.getAttribute("data-src") ||
                img.getAttribute("data-original") ||
                img.getAttribute("src");
            const url = absolute(src);
            if (!url || seen.has(url)) continue;
            if (/blank|spinner|loading|pixel|logo|avatar/i.test(url)) continue;
            seen.add(url);
            imgs.push(url);
        }
        // JS array fallback
        if (imgs.length === 0) {
            try {
                for (const s of document.querySelectorAll("script")) {
                    const text = s.textContent || "";
                    const m = text.match(/(?:images|pages|lstImages)\s*=\s*\[([^\]]+)\]/i);
                    if (!m) continue;
                    const parts = m[1].match(/https?:\/\/[^"'\s,]+/g) || [];
                    for (const p of parts) {
                        const u = absolute(p.replace(/\\u002F/g, "/").replace(/\\/g, ""));
                        if (u && !seen.has(u)) {
                            seen.add(u);
                            imgs.push(u);
                        }
                    }
                    if (imgs.length) break;
                }
            } catch (_) {}
        }
        return imgs;
    }

    const source = {
        manifest: {
            id: "zipcomic",
            name: "ZipComic",
            version: "1.0.0",
            description: "Comic aggregator (zipcomic.com). Series / issues / page images.",
            author: "Comic Viewer community",
            homepage: ORIGIN,
            browseURL: ORIGIN + "/",
        },

        async parseCatalog() {
            const imgs = parseReaderImages();
            if (imgs.length > 0) {
                return [
                    {
                        title: pageTitle(),
                        url: location.href,
                        canRead: true,
                    },
                ];
            }
            return parseListItems();
        },

        async parsePages() {
            let imgs = parseReaderImages();
            if (imgs.length) return imgs;
            await new Promise((r) => setTimeout(r, 600));
            return parseReaderImages();
        },

        canRead() {
            return parseReaderImages().length > 0 || looksLikeIssue(location.href);
        },

        opensCatalog() {
            return isSeriesOrList() && parseReaderImages().length === 0;
        },
    };

    globalThis.ComicViewerSource = source;
})();
