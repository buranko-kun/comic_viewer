// Comic Viewer source plugin for ReadComicsOnline.
// Install from the raw GitHub URL:
// https://raw.githubusercontent.com/buranko-kun/comic_viewer/main/plugins/readcomicsonline/plugin.js
//
// The site may present a browser challenge. Open this plugin's source browser session
// from Preferences -> Sources; the runtime reuses the same persistent website data store.

(() => {
    const ORIGIN = "https://readcomicsonline.ru";
    const CACHE_KEY = "comicviewer.readcomics.catalog.v3";
    let operationContext = {};
    const CACHE_MAX_AGE = 14 * 24 * 60 * 60 * 1000;

    function absolute(raw, base = document.baseURI) {
        if (!raw) return null;
        try { return new URL(raw, base).href; } catch (_) { return null; }
    }

    function imageResource(url, referrer) {
        return url ? { url, referrer, useBrowserCookies: true } : null;
    }

    function clearCache() {
        for (let i = localStorage.length - 1; i >= 0; i--) {
            const key = localStorage.key(i);
            if (key && key.startsWith("comicviewer.readcomics.catalog.")) localStorage.removeItem(key);
        }
    }

    function diagnostic(event) { operationContext.diagnostic?.(event); }

    function clean(text) {
        return (text || "")
            .replace(/\s+/g, " ")
            .trim();
    }

    function imageURL(image, baseURL) {
        if (!image) return null;

        // Lazy loaders often leave a placeholder in src. Check every candidate.
        for (const attribute of ["data-src", "data-lazy-src", "data-original",
                                 "data-original-src", "src"]) {
            const href = absolute(image.getAttribute(attribute), baseURL);
            if (href && /\/uploads\/manga\//i.test(href)) return href;
        }

        const srcset = image.getAttribute("srcset") || image.getAttribute("data-srcset");
        if (srcset) {
            for (const candidate of srcset.split(",")) {
                const rawCandidate = candidate.trim().split(/\s+/)[0];
                const href = absolute(rawCandidate, baseURL);
                if (href && /\/uploads\/manga\//i.test(href)) return href;
            }
        }

        return null;
    }

    function localCardImage(anchor, baseURL) {
        const candidates = [];
        let node = anchor;
        for (let depth = 0; node && depth < 8; depth++, node = node.parentElement) {
            const series = new Set([...node.querySelectorAll('a[href*="/comic/"]')]
                .map(a => slugFromURL(absolute(a.getAttribute("href"), baseURL)))
                .filter(Boolean));
            if (series.size > 1) break;
            const localImages = node.querySelectorAll("img");
            for (const image of localImages) {
                const href = imageURL(image, baseURL);
                if (href && !candidates.includes(href)) candidates.push(href);
            }
            if (candidates.length) break;
        }

        return candidates.find(href => /\/uploads\/manga\//i.test(href)) || null;
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

    function parseCatalogPage(doc, baseURL) {
        const cards = [];
        const seen = new Set();
        const covers = new Map();
        for (const image of doc.querySelectorAll("img")) {
            const href = imageURL(image, baseURL);
            const folder = href && new URL(href).pathname.match(/\/uploads\/manga\/([^/]+)\/cover\//i);
            if (folder) covers.set(folder[1].toLowerCase(), href);
        }

        for (const anchor of doc.querySelectorAll('a[href*="/comic/"]')) {
            const href = absolute(anchor.getAttribute("href"), baseURL);
            if (!href) continue;

            let url;
            try { url = new URL(href); } catch (_) { continue; }
            if (url.origin !== ORIGIN || !url.pathname.match(/^\/comic\/[a-z0-9-]+\/?$/i)) continue;

            const slug = slugFromURL(href);
            if (!slug || seen.has(slug)) continue;

            const cover = covers.get(slug.toLowerCase()) || localCardImage(anchor, baseURL);

            seen.add(slug);
            cards.push({
                id: slug,
                title: clean(anchor.textContent) || slug,
                cover: imageResource(cover, baseURL),
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

    const RETRYABLE_STATUS = new Set([
        429, 500, 502, 503, 504, 520, 521, 522, 523, 524
    ]);

    function sleep(ms) {
        const signal = operationContext.signal;
        return new Promise((resolve, reject) => {
            if (signal?.aborted) return reject(new DOMException("Aborted", "AbortError"));
            const finish = () => { signal?.removeEventListener("abort", abort); resolve(); };
            const timer = setTimeout(finish, ms);
            const abort = () => { clearTimeout(timer); reject(new DOMException("Aborted", "AbortError")); };
            signal?.addEventListener("abort", abort, { once: true });
        });
    }

    async function fetchDocument(url) {
        const maxAttempts = 4;

        for (let attempt = 1; attempt <= maxAttempts; attempt++) {
            operationContext.signal?.throwIfAborted();
            const controller = new AbortController();
            const abort = () => controller.abort();
            operationContext.signal?.addEventListener("abort", abort, { once: true });
            const timer = setTimeout(abort, 25000);
            let response;
            let html;
            try {
                response = await fetch(url, { credentials: "include", signal: controller.signal });
                if (response.ok) html = await response.text();
            } catch (error) {
                if (operationContext.signal?.aborted || attempt === maxAttempts) throw error;
                diagnostic({ type: "retry", attempt, reason: error.name });
                await sleep(1000 * attempt);
                continue;
            } finally {
                clearTimeout(timer);
                operationContext.signal?.removeEventListener("abort", abort);
            }
            diagnostic({ type: "response", status: response.status, attempt });

            if (response.ok) {
                return new DOMParser().parseFromString(html, "text/html");
            }

            if (!RETRYABLE_STATUS.has(response.status) || attempt === maxAttempts) {
                throw new Error(
                    `ReadComicsOnline returned HTTP ${response.status} for ${url}`
                );
            }

            await sleep(1000 * attempt);
        }

        throw new Error(`ReadComicsOnline request failed for ${url}`);
    }

    async function fetchCatalogPage(page) {
        return fetchCatalogPageURL(`${ORIGIN}/comic-list?page=${page}`, true);
    }

    async function fetchCatalogPageURL(url, paced = false) {
        const key = `${CACHE_KEY}.page.${url}`;
        try {
            const cached = JSON.parse(localStorage.getItem(key));
            if (cached && Array.isArray(cached.result?.cards) && cached.result.cards.length
                && Date.now() - cached.savedAt < CACHE_MAX_AGE) {
                diagnostic({ type: "cache", hit: true, ageMs: Date.now() - cached.savedAt });
                return cached.result;
            }
        } catch (_) {}
        diagnostic({ type: "cache", hit: false });
        if (paced) await sleep(750);
        const doc = await fetchDocument(url);
        const result = parseCatalogPage(doc, url);
        if (!result.cards.length) throw new Error("No catalog entries found. Open the source browser to check the session.");
        try { localStorage.setItem(key, JSON.stringify({ savedAt: Date.now(), result })); } catch (_) {}
        return result;
    }

    async function loadFullCatalog(first) {
        if (first.cards.length === 0 && first.pageCount <= 1) {
            throw new Error("ReadComicsOnline returned no catalog entries. The Cloudflare check may need solving.");
        }

        const all = [...first.cards];
        const seen = new Set(all.map(item => item.id));

        // ReadComicsOnline can return HTTP 520 when several catalog pages are
        // requested concurrently. Fetch one page at a time and keep a small delay between requests.
        for (let page = 2; page <= first.pageCount; page++) {
            const result = await fetchCatalogPage(page);
            for (const item of result.cards) {
                if (seen.has(item.id)) continue;
                seen.add(item.id);
                all.push(item);
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

    function seriesInfo(doc, pageURL) {
        const title = clean(
            doc.querySelector('meta[property="og:title"]')?.getAttribute("content")
            || doc.title
        ).replace(/\s*[—-]\s*Read Comics Online\s*$/i, "");

        const cover = absolute(
            doc.querySelector('meta[property="og:image"]')?.getAttribute("content"),
            pageURL
        );

        let slug = null;
        try {
            slug = new URL(pageURL).pathname.split("/").filter(Boolean)[1] || null;
        } catch (_) {}

        return { title: title || "Untitled", cover, slug };
    }

    function chapterEntries(doc, info, baseURL) {
        const hashLabeled = new Map();
        const anyChapter = new Map();

        for (const anchor of doc.querySelectorAll('a[href*="/comic/"]')) {
            const href = absolute(anchor.getAttribute("href"), baseURL);
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
                cover: imageResource(info.cover, baseURL),
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

    function pageURLs(doc, baseURL) {
        const seen = new Set();
        const pages = [];

        for (const image of doc.querySelectorAll("img")) {
            const href = imageURL(image, baseURL);
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
            version: "1.3.0",
            apiVersion: 1,
            operationTimeoutSeconds: 900,
            homepage: `${ORIGIN}/comic/spawn-1992`,
            description: "ReadComicsOnline catalog and streamed chapter reader",
            capabilities: ["browse", "read", "browser-session"],
            settings: [{
                id: "fullCatalog",
                title: "Load entire catalog",
                description: "Fetch every catalog page for global search. The first load can take several minutes; otherwise browse one page at a time.",
                type: "bool",
                defaultValue: false
            }]
        },

        browseURL: `${ORIGIN}/comic-list?page=1`,

        clearCache,

        async parseCatalog(context = {}) {
            operationContext = context;
            if (context.refresh) clearCache();
            const target = absolute(context.url || `${ORIGIN}/comic-list?page=1`);
            if (!target) throw new Error("Invalid catalog URL");

            const targetURL = new URL(target);
            if (targetURL.origin !== ORIGIN) {
                throw new Error("ReadComicsOnline target must stay on readcomicsonline.ru");
            }

            if (targetURL.pathname === "/comic-list") {
                const isFirstPage = (targetURL.searchParams.get("page") || "1") === "1";
                const fullCatalog = globalThis.ComicViewerSource.settings?.fullCatalog === true && isFirstPage;
                if (fullCatalog) {
                    const cached = cachedCatalog();
                    if (cached) {
                        return { name: "ReadComicsOnline", comics: cached, catalogs: [] };
                    }
                }

                const first = await fetchCatalogPageURL(targetURL.href);
                if (fullCatalog) {
                    const comics = await loadFullCatalog(first);
                    saveCatalog(comics);
                    return { name: "ReadComicsOnline", comics, catalogs: [] };
                }
                const page = Math.max(1, Number(targetURL.searchParams.get("page")) || 1);
                const catalogs = page < first.pageCount ? [{
                    name: `Next page (${page + 1})`,
                    url: `${ORIGIN}/comic-list?page=${page + 1}`
                }] : [];
                return { name: `ReadComicsOnline · Page ${page}`, comics: first.cards, catalogs };
            }

            if (/^\/comic\/[a-z0-9-]+\/?$/i.test(targetURL.pathname)) {
                const doc = await fetchDocument(targetURL.href);
                const info = seriesInfo(doc, targetURL.href);
                if (!info.slug) return { name: "ReadComicsOnline", comics: [], catalogs: [] };

                return {
                    name: info.title,
                    comics: chapterEntries(doc, info, targetURL.href),
                    catalogs: []
                };
            }

            return { name: "ReadComicsOnline", comics: [], catalogs: [] };
        },

        async parsePages(context = {}) {
            operationContext = context;
            const target = absolute(context.url || location.href);
            if (!target) return { pages: [] };

            const targetURL = new URL(target);
            if (targetURL.origin !== ORIGIN) {
                throw new Error("ReadComicsOnline page must stay on readcomicsonline.ru");
            }

            const doc = await fetchDocument(targetURL.href);
            const pages = pageURLs(doc, targetURL.href);
            if (!pages.length) throw new Error("No chapter images found. Check the source session or page selectors.");
            return { pages: pages.map(url => imageResource(url, targetURL.href)) };
        }

    };
})();
