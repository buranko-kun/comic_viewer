// Comic Viewer source plugin for ReadComicOnline (readcomiconline.li).
// Install from Preferences -> Sources -> Source plugins.
//
// Aggregator-style comic reader. Series at /Comic/{slug}, issues at
// /Comic/{slug}/Issue-N?id=… or /Full. Page images are loaded in the
// reader; Cloudflare + anti-bot measures are common.
//
// Open the site once in the plugin source browser and solve any CAPTCHA /
// challenge so the WebView session is usable.

(() => {
    const ORIGIN = "https://readcomiconline.li";
    // Backup domains sometimes used
    const ORIGINS = [ORIGIN, "https://rcostation.xyz"];

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

    function param(name, url = location.href) {
        try {
            return new URL(url).searchParams.get(name);
        } catch (_) {
            return null;
        }
    }

    function isSeriesPath(pathname = pathOf()) {
        // /Comic/Title or /Comic/Title/
        return /^\/Comic\/[^/]+\/?$/i.test(pathname);
    }

    function isIssuePath(pathname = pathOf()) {
        // /Comic/Title/Issue-12 or /Comic/Title/Full or /Comic/Title/Annual-1
        return /^\/Comic\/[^/]+\/.+/i.test(pathname);
    }

    function isBrowsePath(pathname = pathOf()) {
        return pathname === "/" || /^\/(ComicList|Genre|Publisher|Writer|Artist|Search)/i.test(pathname);
    }

    function pageTitle() {
        const t = clean(document.title || "");
        return t
            .replace(/\s*[-–—|]\s*ReadComicOnline.*$/i, "")
            .replace(/\s*Read comics online.*$/i, "")
            .trim() || "ReadComicOnline";
    }

    // --- Catalog -----------------------------------------------------------

    function parseSeriesList() {
        const items = [];
        const seen = new Set();

        // Common list patterns
        const anchors = document.querySelectorAll(
            'a[href*="/Comic/"], .list-comic a, .item a, .series a, .cover a, .bigBarContainer a'
        );
        for (const a of anchors) {
            const href = absolute(a.getAttribute("href"));
            if (!href || seen.has(href)) continue;
            if (!/\/Comic\/[^/]+\/?$/i.test(new URL(href).pathname) && !/\/Comic\/[^/]+$/i.test(href)) {
                // allow only series-level links here
                if (!isSeriesPath(new URL(href).pathname)) continue;
            }
            const title = clean(a.getAttribute("title") || a.textContent);
            if (!title || title.length < 2) continue;
            if (/read online|login|register|home/i.test(title)) continue;
            seen.add(href);
            let cover = null;
            const img = a.querySelector("img") || a.parentElement?.querySelector("img");
            if (img?.src) cover = absolute(img.src);
            items.push({
                title: title.slice(0, 150),
                url: href,
                cover: cover || undefined,
                opensCatalog: true,
            });
            if (items.length >= 60) break;
        }
        return items;
    }

    function parseIssueList() {
        const items = [];
        const seen = new Set();

        // Issue links live in .listing or similar tables/lists
        const container =
            document.querySelector(".listing") ||
            document.querySelector("#chapterList") ||
            document.querySelector(".chapter-list") ||
            document.body;

        for (const a of container.querySelectorAll('a[href*="/Comic/"]')) {
            const href = absolute(a.getAttribute("href"));
            if (!href || seen.has(href)) continue;
            const path = new URL(href).pathname;
            if (!isIssuePath(path)) continue;
            // Prefer links that look like Issue-N or Full
            if (!/Issue-|Annual-|Full|Special/i.test(path) && !param("id", href)) continue;

            let title = clean(a.getAttribute("title") || a.textContent);
            // Clean common "Read X Issue N comic online" noise
            title = title
                .replace(/^Read\s+/i, "")
                .replace(/\s+comic\s+online.*$/i, "")
                .replace(/\s+online$/i, "")
                .trim();
            if (!title || title.length < 2) continue;

            seen.add(href);
            items.push({
                title: title.slice(0, 150),
                url: href,
                canRead: true,
            });
        }

        // Newest first is common on these sites; keep DOM order or reverse if needed
        return items;
    }

    function parseReaderImages() {
        // Reader pages load images via #divImage, .viewer_img, or similar
        const imgs = [];
        const seen = new Set();

        const candidates = document.querySelectorAll(
            "#divImage img, .viewer_img img, #divContent img, .page-img img, img[data-src], img.page"
        );
        for (const img of candidates) {
            const src =
                img.getAttribute("data-src") ||
                img.getAttribute("data-original") ||
                img.getAttribute("src");
            const url = absolute(src);
            if (!url || seen.has(url)) continue;
            if (/blank|spinner|loading|pixel|avatar|logo/i.test(url)) continue;
            seen.add(url);
            imgs.push(url);
        }

        // Some versions put URLs in a JS array (lstImages / etc.)
        if (imgs.length === 0) {
            try {
                const scripts = document.querySelectorAll("script");
                for (const s of scripts) {
                    const text = s.textContent || "";
                    // look for arrays of image URLs
                    const m = text.match(/(?:lstImages|images|pages)\s*=\s*\[([^\]]+)\]/i);
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

    // --- Plugin contract ---------------------------------------------------

    const source = {
        manifest: {
            id: "readcomiconline",
            name: "ReadComicOnline",
            version: "1.0.0",
            description:
                "Comic aggregator (readcomiconline.li). Series → issues → page images. Cloudflare common.",
            author: "Comic Viewer community",
            homepage: ORIGIN,
            browseURL: ORIGIN + "/",
        },

        async parseCatalog() {
            if (isIssuePath()) {
                return [
                    {
                        title: pageTitle(),
                        url: location.href,
                        canRead: true,
                    },
                ];
            }

            if (isSeriesPath()) {
                const issues = parseIssueList();
                if (issues.length) return issues;
            }

            // Browse / home / genre / publisher
            const series = parseSeriesList();
            if (series.length) return series;

            // Fallback
            const items = [];
            const seen = new Set();
            for (const a of document.querySelectorAll("a[href]")) {
                const href = absolute(a.getAttribute("href"));
                if (!href || seen.has(href)) continue;
                if (!href.includes("/Comic/")) continue;
                const t = clean(a.textContent);
                if (!t || t.length < 2) continue;
                seen.add(href);
                const path = new URL(href).pathname;
                items.push({
                    title: t.slice(0, 120),
                    url: href,
                    opensCatalog: isSeriesPath(path),
                    canRead: isIssuePath(path),
                });
                if (items.length >= 50) break;
            }
            return items;
        },

        async parsePages() {
            if (!isIssuePath()) return [];
            // Force single-page mode if possible (some readers use readType=)
            // Images are usually already in the DOM after the page loads
            let imgs = parseReaderImages();
            if (imgs.length) return imgs;

            // Soft retry: wait a tick for lazy-loaded images (WebView context)
            await new Promise((r) => setTimeout(r, 800));
            imgs = parseReaderImages();
            return imgs;
        },

        canRead() {
            return isIssuePath() || parseReaderImages().length > 0;
        },

        opensCatalog() {
            return isSeriesPath() || isBrowsePath();
        },
    };

    globalThis.ComicViewerSource = source;
})();
