// GetComics source plugin. Port of scripts/getURLs.py and scripts/extractData_v2.py.
// Browse a listing page, then open a post to load its download mirrors on demand.
(() => {
    const ORIGIN = "https://getcomics.org";
    const CACHE_PREFIX = "comicviewer.getcomics.v1.";
    const LIST_TTL = 15 * 60 * 1000;
    const POST_TTL = 24 * 60 * 60 * 1000;
    const MAX_CACHE_PAGES = 40;
    const FILE_EXTENSION = /\.(zip|cbz|cbr|rar|7z|pdf|tar|gz)$/i;
    const DOWNLOAD_HEADING = /^(?:The\s+)?Free\s+(?:[A-Za-z0-9]+\s+)*Comics?\s+Download$|^(?:The\s+)?Free\s+Download$/i;
    const NOTES_HEADING = /^Notes?\s*:?$/i;
    const MIRROR_NAMES = /(?:terabox|vikingfile|pixeldrain|datanodes|mediafire|mega|ufile|dropapk|zippyshare|1fichier|anonfiles|gofile|krakenfiles|workupload|uploadhaven|sendspace|rapidgator|nitroflare|uploaded|turbobit|ddownload|filefactory|userscloud|clicknupload|katfile|keep2share|k2s|mexa|fboom|filerio|uptobox|ddl\.to|mirrored\.to|multiup)/i;
    const NON_POST_PATHS = new Set(["sitemap", "page", "cat", "category", "tag", "author", "search", "feed",
        "support", "dmca", "contact", "about", "wp-admin", "wp-content", "wp-includes", "wp-json", "share", "dls", "cdn-cgi"]);
    const RETRYABLE = new Set([408, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524]);
    const clean = value => (value || "").replace(/\s+/g, " ").trim();

    function httpURL(raw, base = ORIGIN) {
        if (!raw || !clean(raw) || /^\s*#/.test(raw)) return null;
        try {
            const url = new URL(raw, base);
            return ["http:", "https:"].includes(url.protocol) && !url.username && !url.password ? url : null;
        } catch (_) { return null; }
    }
    function siteURL(raw, base = ORIGIN) {
        const url = httpURL(raw, base);
        if (!url || !["getcomics.org", "www.getcomics.org"].includes(url.hostname.toLowerCase()) || url.port) return null;
        url.protocol = "https:"; url.hostname = "getcomics.org"; url.hash = "";
        return url;
    }
    function postURL(raw, base) {
        const url = siteURL(raw, base);
        if (!url) return null;
        const parts = url.pathname.split("/").filter(Boolean);
        if (parts.length !== 2 || NON_POST_PATHS.has(parts[0].toLowerCase()) || /\.(xml|php)$/i.test(parts[1])) return null;
        url.search = "";
        url.pathname = `/${parts.join("/")}/`;
        return url.href;
    }
    function coverURL(node, base) {
        if (!node) return null;
        const background = node.matches?.("[data-background-image], .cover-background")
            ? node : node.querySelector("[data-background-image], .cover-background");
        for (const candidate of [background?.getAttribute("data-background-image"),
            background?.getAttribute("style")?.match(/background-image\s*:\s*url\(\s*['"]?([^'")]+)['"]?\s*\)/i)?.[1]]) {
            const url = httpURL(candidate, base);
            if (url) return url.href;
        }
        for (const image of node.querySelectorAll(".post-header-image img, .cover-background-image, img")) {
            for (const attribute of ["data-src", "data-lazy-src", "data-original", "src"]) {
                const raw = image.getAttribute(attribute);
                if (/placeholder|transparent|spacer|loading/i.test(raw || "")) continue;
                const url = httpURL(raw, base);
                if (url) return url.href;
            }
            for (const attribute of ["data-srcset", "srcset"]) {
                const raw = image.getAttribute(attribute)?.split(",")[0]?.trim().split(/\s+/)[0];
                const url = httpURL(raw, base);
                if (url) return url.href;
            }
        }
        return null;
    }
    function resource(url, referrer) { return url ? { url, referrer } : null; }
    function size(text) { return clean(text).match(/Size\s*:\s*([0-9]+(?:\.[0-9]+)?\s*(?:TB|GB|MB|KB))/i)?.[1] || null; }

    function mirrors(doc, base) {
        const scope = doc.querySelector(".post-contents, .post-content, .entry-content") || doc.querySelector("article") || doc.body;
        const elements = Array.from(scope.querySelectorAll("*"));
        const start = elements.findIndex(node => DOWNLOAD_HEADING.test(clean(node.textContent)));
        if (start < 0) return [];
        const result = [], seen = new Set();
        for (const node of elements.slice(start + 1)) {
            if (NOTES_HEADING.test(clean(node.textContent))) break;
            if (node.tagName !== "A") continue;
            const url = httpURL(node.getAttribute("href"), base);
            if (!url) continue;
            const host = url.hostname.toLowerCase().replace(/^www\./, "");
            const label = clean(node.textContent + " " + (node.getAttribute("title") || ""));
            const isRedirect = host === "getcomics.org" && url.pathname.startsWith("/dls/");
            const isFile = FILE_EXTENSION.test(url.pathname);
            const isHost = MIRROR_NAMES.test(host) || MIRROR_NAMES.test(label);
            const isDownloadLabel = /\b(download|mirror|direct|server|link|file)\b/i.test(label);
            if (!isRedirect && !isFile && !isHost && !isDownloadLabel) continue;
            // Paths, fragments (e.g. MEGA keys), and signed queries are case-sensitive.
            if (seen.has(url.href)) continue;
            seen.add(url.href); result.push(url.href);
        }
        return result;
    }

    function parsePost(doc, target) {
        const title = clean(doc.querySelector("h1.post-title, h1.entry-title")?.textContent);
        if (!title) throw new Error("GetComics post title was not found. Check the source session or page markup.");
        const main = doc.querySelector(".post-contents, .post-content, .entry-content") || doc.body;
        const cover = coverURL(doc.querySelector(".cover-background") || doc.querySelector("article"), target)
            || httpURL(doc.querySelector('meta[property="og:image"]')?.getAttribute("content"), target)?.href;
        const links = mirrors(doc, target);
        const comic = { id: target, title, link: target, cover: resource(cover, target),
            size: size(main.textContent), mirrors: links, hasMirrors: links.length > 0, canRead: false };
        const formats = links.map(raw => new URL(raw).pathname.match(FILE_EXTENSION)?.[1]?.toLowerCase()).filter(Boolean);
        if (formats.length && new Set(formats).size === 1) comic.format = formats[0];
        return { name: title, comics: [comic], catalogs: [] };
    }

    function parseListing(doc, target) {
        const isSitemap = new URL(target).pathname.replace(/\/$/, "") === "/sitemap";
        const comics = [], seen = new Set();
        if (isSitemap) {
            // Match the actual sitemap lists, not the site's menu/sidebar/footer links.
            for (const anchor of doc.querySelectorAll(".lcp_catlist a[href]")) {
                const link = postURL(anchor.getAttribute("href"), target);
                if (!link || seen.has(link)) continue;
                seen.add(link);
                comics.push({ id: link, title: clean(anchor.textContent) || new URL(link).pathname,
                    link, opensCatalog: true, mirrors: [], hasMirrors: false });
            }
        } else {
            for (const article of doc.querySelectorAll("article.post, article.cover-post")) {
                const anchor = article.querySelector(".post-title a[href], .entry-title a[href]");
                const link = postURL(anchor?.getAttribute("href"), target);
                if (!link || seen.has(link)) continue;
                seen.add(link);
                comics.push({ id: link, title: clean(anchor.textContent), link, opensCatalog: true,
                    cover: resource(coverURL(article, target), target), size: size(article.textContent), mirrors: [], hasMirrors: false });
            }
        }
        if (!comics.length) throw new Error("No GetComics posts found. Open the source session to check for a challenge or changed markup.");
        const catalogs = [];
        if (isSitemap) {
            const current = Number(new URL(target).searchParams.get("lcp_page0") || 1);
            const nextPages = [...doc.querySelectorAll('a[href*="lcp_page0="]')].map(anchor => siteURL(anchor.getAttribute("href"), target))
                .filter(url => url && url.pathname.replace(/\/$/, "") === "/sitemap")
                .map(url => Number(url.searchParams.get("lcp_page0"))).filter(page => Number.isSafeInteger(page) && page > current);
            if (nextPages.length) catalogs.push({ name: `Next sitemap page (${Math.min(...nextPages)})`, url: `${ORIGIN}/sitemap/?lcp_page0=${Math.min(...nextPages)}` });
        } else {
            const next = siteURL(doc.querySelector('link[rel="next"], a[rel="next"], a.pagination-older, a.next.page-numbers')?.getAttribute("href"), target);
            if (next && next.href !== target && /^\/(?:page\/\d+\/)?$|^\/cat\/[^/]+\/(?:page\/\d+\/)?$/.test(next.pathname)) {
                catalogs.push({ name: "Next page", url: next.href });
            }
            if (new URL(target).pathname === "/") catalogs.push({ name: "All posts (sitemap)", url: `${ORIGIN}/sitemap/` });
        }
        return { name: isSitemap ? "GetComics · Sitemap" : "GetComics", comics, catalogs };
    }

    function cacheKeys() {
        const keys = [];
        for (let i = 0; i < localStorage.length; i++) {
            const key = localStorage.key(i);
            if (key?.startsWith(CACHE_PREFIX)) keys.push(key);
        }
        return keys;
    }
    function clearCache() { for (const key of cacheKeys()) localStorage.removeItem(key); }
    function readCache(key, ttl) {
        try {
            const cached = JSON.parse(localStorage.getItem(key));
            if (cached && Date.now() - cached.savedAt < ttl && Array.isArray(cached.result?.comics)) return cached.result;
        } catch (_) {}
        return null;
    }
    function saveCache(key, result) {
        try {
            const keys = cacheKeys().filter(k => k !== key).sort((a, b) => {
                try { return JSON.parse(localStorage.getItem(a)).savedAt - JSON.parse(localStorage.getItem(b)).savedAt; } catch (_) { return 0; }
            });
            while (keys.length >= MAX_CACHE_PAGES) localStorage.removeItem(keys.shift());
            localStorage.setItem(key, JSON.stringify({ savedAt: Date.now(), result }));
        } catch (_) { /* Parsing still succeeds if persistent storage is unavailable. */ }
    }
    function sleep(ms, signal) {
        return new Promise((resolve, reject) => {
            if (signal?.aborted) return reject(new DOMException("Aborted", "AbortError"));
            const abort = () => { clearTimeout(timer); reject(new DOMException("Aborted", "AbortError")); };
            const timer = setTimeout(() => { signal?.removeEventListener("abort", abort); resolve(); }, ms);
            signal?.addEventListener("abort", abort, { once: true });
        });
    }
    async function fetchDocument(target, context) {
        for (let attempt = 1; attempt <= 3; attempt++) {
            context.signal?.throwIfAborted();
            const controller = new AbortController();
            const abort = () => controller.abort();
            context.signal?.addEventListener("abort", abort, { once: true });
            const timeout = setTimeout(abort, 25000);
            let response, html;
            try {
                response = await fetch(target, { credentials: "include", signal: controller.signal });
                if (response.ok) html = await response.text();
            } catch (error) {
                if (context.signal?.aborted || attempt === 3) throw error;
                response = null;
                context.diagnostic?.({ type: "retry", attempt, reason: error.name });
            } finally {
                clearTimeout(timeout); context.signal?.removeEventListener("abort", abort);
            }
            if (response) {
                context.diagnostic?.({ type: "response", status: response.status, attempt });
                if (response.ok) {
                    if (response.url && !siteURL(response.url)) throw new Error("GetComics redirected outside its site.");
                    return new DOMParser().parseFromString(html, "text/html");
                }
                if (!RETRYABLE.has(response.status) || attempt === 3) throw new Error(`GetComics returned HTTP ${response.status}. Open the source session if access is blocked.`);
            }
            const retryAfter = Number(response?.headers.get("Retry-After"));
            const delay = response?.status === 429 ? Math.min(15000, Math.max(1500, retryAfter > 0 ? retryAfter * 1000 : 15000)) : attempt * 1000;
            await sleep(delay, context.signal);
        }
        throw new Error("GetComics request failed.");
    }

    globalThis.ComicViewerSource = {
        manifest: {
            id: "getcomics", name: "GetComics", version: "1.0.1", apiVersion: 1,
            homepage: `${ORIGIN}/`, description: "Browse GetComics posts and load download mirrors on demand",
            capabilities: ["browse", "browser-session", "static-session"], operationTimeoutSeconds: 120
        },
        browseURL: `${ORIGIN}/`,
        clearCache,
        async parseCatalog(context = {}) {
            const target = siteURL(context.url || `${ORIGIN}/`);
            if (!target) throw new Error("GetComics catalog URLs must stay on getcomics.org.");
            context.signal?.throwIfAborted();
            const post = postURL(target.href);
            const key = CACHE_PREFIX + target.href;
            if (context.refresh) { try { localStorage.removeItem(key); } catch (_) {} }
            const cached = readCache(key, post ? POST_TTL : LIST_TTL);
            context.diagnostic?.({ type: "cache", hit: !!cached });
            if (cached) return cached;
            const doc = await fetchDocument(target.href, context);
            const result = post ? parsePost(doc, post) : parseListing(doc, target.href);
            if (post && !result.comics[0].hasMirrors) context.diagnostic?.({ type: "warning", message: "No mirrors in the download section; check markup or open the source page." });
            saveCache(key, result);
            return result;
        }
    };
})();
