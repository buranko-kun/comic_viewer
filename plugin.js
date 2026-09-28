// Comic Viewer source plugin for ReadComicsOnline.
// Install from the raw GitHub URL:
// https://raw.githubusercontent.com/buranko-kun/comic_viewer/main/plugins/readcomicsonline/plugin.js
//
// The site may present a browser challenge. Open this plugin's source browser session
// from Preferences -> Sources; the runtime reuses the same persistent website data store.

(() => {
    const ORIGIN = "https://readcomicsonline.ru";
    const CDN_ORIGIN = "https://cdn.readcomicsonline.ru";
    const CACHE_KEY = "comicviewer.readcomics.catalog.v1";
    const CACHE_MAX_AGE = 14 * 24 * 60 * 60 * 1000;

    function absolute(raw, base = document.baseURI) {
        if (!raw) return null;
        try { return new URL(raw, base).href; } catch (_) { return null; }
    }

    function clean(text) {
        return (text || "")
            .replace(/\s+/g, " ")
            .trim();
    }

    function slugFromURL(href) {
        try {
            const path = new URL(href).pathname.split("/").filter(Boolean);
            if (path[0] !== "comic" || !path[1]) return null;
            return path[1];
        } catch (_) {
            return null;
        }
    }

    function parseSeriesCard(card) {
        const anchor = card.querySelector('a[href*="/comic/"]');
        if (!anchor) return null;

        const href = absolute(anchor.getAttribute("href"));
        const slug = href && slugFromURL(href);
        if (!href || !slug) return null;

        const title = clean(anchor.textContent) || slug;
        const image = card.querySelector("img[src], img[data-src]");
        const cover = image
            ? absolute(image.getAttribute("src") || image.getAttribute("data-src"))
            : null;

        return {
            id: slug,
            title,
            cover,
            link: href,
            opensCatalog: true
        };
    }

    function parseCatalogPage(doc, baseURL) {
        const cards = [];
        const seen = new Set();

        for (const anchor of doc.querySelectorAll('a[href*="/comic/"]')) {
            const href = absolute(anchor.getAttribute("href"), baseURL);
            if (!href) continue;

            let url;
            try { url = new URL(href); } catch (_) { continue; }
            if (url.origin !== ORIGIN || !url.pathname.match(/^\/comic\/[a-z0-9-]+\/?$/i)) continue;

            const slug = slugFromURL(href);
            if (!slug || seen.has(slug)) continue;

            const card = anchor.closest(".card") || anchor.parentElement;
            if (!card) continue;

            const image = card.querySelector("img[src], img[data-src]");
            const cover = image
                ? absolute(image.getAttribute("src") || image.getAttribute("data-src"), baseURL)
                : null;

            seen.add(slug);
            cards.push({
                id: slug,
                title: clean(anchor.textContent) || slug,
                cover,
                link: href,
                opensCatalog: true
            });
        }

        let pageCount = 1;
        for (const anchor of doc.querySelectorAll('a[href*="comic-list?page="]')) {
            const href = absolute(anchor.getAttribute("href"), baseURL);
            if (!href) continue;
            try {
                const page = Number(new URL(href).searchParams.get("page"));
                if (Number.isFinite(page)) pageCount = Math.max(pageCount, page);
            } catch (_) {}
        }

        return { cards, pageCount };
    }

    async function fetchCatalogPage(page) {
        const url = `${ORIGIN}/comic-list?page=${page}`;
        const response = await fetch(url, { credentials: "include" });
        if (!response.ok) throw new Error(`Catalog page returned HTTP ${response.status}`);
        const html = await response.text();
        const doc = new DOMParser().parseFromString(html, "text/html");
        return parseCatalogPage(doc, url);
    }

    async function loadFullCatalog() {
        const first = parseCatalogPage(document, location.href);
        if (first.cards.length === 0 && first.pageCount <= 1) {
            throw new Error("ReadComicsOnline returned no catalog entries. The Cloudflare check may need solving.");
        }

        const all = [...first.cards];
        const seen = new Set(all.map(item => item.id));

        // The site currently exposes many paginated catalog pages. Fetch a small batch at a time
        // instead of launching hundreds of requests simultaneously.
        for (let page = 2; page <= first.pageCount; page += 6) {
            const batch = [];
            for (let i = page; i <= Math.min(first.pageCount, page + 5); i++) {
                batch.push(fetchCatalogPage(i));
            }
            const results = await Promise.all(batch);
            for (const result of results) {
                for (const item of result.cards) {
                    if (seen.has(item.id)) continue;
                    seen.add(item.id);
                    all.push(item);
                }
            }
        }

        all.sort((a, b) => a.title.localeCompare(b.title, undefined, { numeric: true, sensitivity: "base" }));
        return all;
    }

    function cachedCatalog() {
        try {
            const raw = localStorage.getItem(CACHE_KEY);
            if (!raw) return null;
            const value = JSON.parse(raw);
            if (!value || !Array.isArray(value.comics) || !value.savedAt) return null;
            if (Date.now() - value.savedAt > CACHE_MAX_AGE) return null;
            return value.comics;
        } catch (_) {
            return null;
        }
    }

    function saveCatalog(comics) {
        try {
            localStorage.setItem(CACHE_KEY, JSON.stringify({
                savedAt: Date.now(),
                comics
            }));
        } catch (_) {}
    }

    function seriesInfo() {
        const title = clean(
            document.querySelector('meta[property="og:title"]')?.getAttribute("content")
            || document.title
        ).replace(/\s*[—-]\s*Read Comics Online\s*$/i, "");

        const cover = absolute(
            document.querySelector('meta[property="og:image"]')?.getAttribute("content")
        );

        let slug = null;
        try {
            slug = new URL(location.href).pathname.split("/").filter(Boolean)[1] || null;
        } catch (_) {}

        return { title: title || "Untitled", cover, slug };
    }

    function sortChapter(a, b) {
        const an = /^\d+$/.test(a.segment) ? Number(a.segment) : null;
        const bn = /^\d+$/.test(b.segment) ? Number(b.segment) : null;
        if (an !== null && bn !== null) return an - bn;
        if (an !== null) return -1;
        if (bn !== null) return 1;
        return a.segment.localeCompare(b.segment, undefined, { numeric: true, sensitivity: "base" });
    }

    function chapterEntries(info) {
        const hashLabeled = new Map();
        const anyChapter = new Map();

        for (const anchor of document.querySelectorAll('a[href*="/comic/"]')) {
            const href = absolute(anchor.getAttribute("href"));
            if (!href) continue;

            let url;
            try { url = new URL(href); } catch (_) { continue; }
            const parts = url.pathname.split("/").filter(Boolean);
            if (parts.length !== 3 || parts[0] !== "comic" || parts[1] !== info.slug || !parts[2]) continue;

            const segment = decodeURIComponent(parts[2]);
            const entry = {
                id: `${info.slug}#${segment}`,
                title: clean(anchor.textContent) || segment,
                link: url.href,
                series: info.title,
                cover: issueCover(info, segment),
                canRead: true
            };

            if (!anyChapter.has(segment)) anyChapter.set(segment, entry);
            if (clean(anchor.textContent).includes("#") && !hashLabeled.has(segment)) {
                hashLabeled.set(segment, entry);
            }
        }

        const chosen = hashLabeled.size ? [...hashLabeled.values()] : [...anyChapter.values()];
        chosen.sort((a, b) => {
            const an = /^\d+$/.test(a.id.split("#").pop()) ? Number(a.id.split("#").pop()) : null;
            const bn = /^\d+$/.test(b.id.split("#").pop()) ? Number(b.id.split("#").pop()) : null;
            if (an !== null && bn !== null) return an - bn;
            if (an !== null) return -1;
            if (bn !== null) return 1;
            return a.title.localeCompare(b.title, undefined, { numeric: true, sensitivity: "base" });
        });

        return chosen.map(entry => ({
            ...entry,
            hasMirrors: false,
            mirrors: []
        }));
    }

    function issueCover(info, segment) {
        const cover = info.cover || "";
        const match = cover.match(/\/uploads\/manga\/([^/]+)\//);
        const folder = match ? match[1] : info.slug;
        if (!folder || !segment) return null;
        return `${CDN_ORIGIN}/uploads/manga/${folder}/chapters/${encodeURIComponent(segment)}/01.jpg`;
    }

    function pageURLs() {
        const seen = new Set();
        const pages = [];

        for (const image of document.querySelectorAll("img[src], img[data-src]")) {
            const raw = image.getAttribute("src") || image.getAttribute("data-src");
            const href = absolute(raw);
            if (!href) continue;

            try {
                const url = new URL(href);
                if (url.hostname !== "cdn.readcomicsonline.ru") continue;
                if (!/\/uploads\/manga\/[^/]+\/chapters\/[^/]+\/[^/]+\.(?:jpg|jpeg|png|webp|gif)$/i.test(url.pathname)) {
                    continue;
                }
                if (seen.has(url.href)) continue;
                seen.add(url.href);
                pages.push(url.href);
            } catch (_) {}
        }

        pages.sort((a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" }));
        return pages;
    }

    globalThis.ComicViewerSource = {
        manifest: {
            id: "readcomicsonline",
            name: "ReadComicsOnline",
            version: "1.0.0",
            homepage: ORIGIN,
            description: "ReadComicsOnline catalog and streamed chapter reader"
        },

        browseURL: `${ORIGIN}/comic-list?page=1`,

        async parseCatalog() {
            const isCatalog = location.pathname === "/comic-list";
            if (isCatalog) {
                const cached = cachedCatalog();
                if (cached) {
                    return { name: "ReadComicsOnline", comics: cached, catalogs: [] };
                }

                const comics = await loadFullCatalog();
                saveCatalog(comics);
                return { name: "ReadComicsOnline", comics, catalogs: [] };
            }

            const info = seriesInfo();
            if (!info.slug) return { name: "ReadComicsOnline", comics: [], catalogs: [] };

            return {
                name: info.title,
                comics: chapterEntries(info),
                catalogs: []
            };
        },

        parsePages() {
            return { pages: pageURLs() };
        }
    };
})();
