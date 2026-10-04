// Comic Viewer source plugin for Digital Comic Museum (digitalcomicmuseum.com).
// Install from Preferences -> Sources -> Source plugins.
//
// Public-domain Golden Age comics (pre-1960, researched PD status).
// Browse by publisher (cid=) or series lists. Downloads require a free
// site account. Online PREVIEW reading works when logged in.
//
// Cloudflare is present: open the homepage once in the plugin source
// browser and solve any challenge so the WebView session is established.

(() => {
    const ORIGIN = "https://digitalcomicmuseum.com";

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

    function param(name, url = location.href) {
        try {
            return new URL(url).searchParams.get(name);
        } catch (_) {
            return null;
        }
    }

    function pathOf(url = location.href) {
        try {
            return new URL(url).pathname;
        } catch (_) {
            return "";
        }
    }

    function isPreviewPath(pathname = pathOf()) {
        return /\/preview\//i.test(pathname);
    }

    function isCategoryOrSeries(url = location.href) {
        const cid = param("cid", url);
        return !!cid || pathOf(url) === "/" || pathOf(url) === "/index.php";
    }

    function pageTitle() {
        const t = clean(document.title || "");
        return t
            .replace(/\s*[-–—|]\s*Digital Comic Museum.*$/i, "")
            .replace(/^Digital Comic Museum\s*[-–—]?\s*/i, "")
            .trim() || "Digital Comic Museum";
    }

    function isLoggedIn() {
        const txt = document.body?.innerText || "";
        return /Logged in as:\s*\S+/i.test(txt) && !/Logged in as:\s*Guest/i.test(txt);
    }

    // --- Catalog parsing ---------------------------------------------------

    function parsePublisherLinks() {
        const items = [];
        const seen = new Set();
        for (const a of document.querySelectorAll('a[href*="cid="]')) {
            const href = absolute(a.getAttribute("href"));
            if (!href || seen.has(href)) continue;
            const cid = param("cid", href);
            if (!cid) continue;
            const title = clean(a.textContent);
            if (!title || title.length < 2) continue;
            // Skip pure numeric or utility links
            if (/^(home|downloads|search|log\s*in|register)$/i.test(title)) continue;
            seen.add(href);
            items.push({
                title,
                url: href,
                opensCatalog: true,
            });
        }
        return items;
    }

    function parseIssueRows() {
        const items = [];
        const seen = new Set();

        // Table rows typical of DCM listing pages
        for (const row of document.querySelectorAll("tr")) {
            const cells = row.querySelectorAll("td");
            if (cells.length < 2) continue;

            let name = "";
            let size = null;
            let previewUrl = null;
            let downloadUrl = null;
            let did = null;

            for (const a of row.querySelectorAll("a[href]")) {
                const href = absolute(a.getAttribute("href"));
                if (!href) continue;
                const t = clean(a.textContent);
                if (/preview/i.test(href) || /preview/i.test(t)) {
                    previewUrl = href;
                    did = param("did", href);
                } else if (/download|getfile|file\.php|did=/i.test(href) || /download/i.test(t)) {
                    downloadUrl = href;
                    if (!did) did = param("did", href);
                } else if (t && t.length > 3 && !/comment|select|preview|download/i.test(t)) {
                    if (!name || t.length > name.length) name = t;
                }
            }

            // Fallback: first substantial cell text as title
            if (!name) {
                for (const cell of cells) {
                    const t = clean(cell.textContent);
                    if (t && t.length > 4 && !/^\d+(\.\d+)?\s*(MB|KB|GB)$/i.test(t) && !/^\d{1,2}[-/]\w+/i.test(t)) {
                        name = t.split(/\s{2,}/)[0].slice(0, 120);
                        break;
                    }
                }
            }

            // Size from any cell matching file size pattern
            for (const cell of cells) {
                const m = clean(cell.textContent).match(/([\d.]+)\s*(MB|KB|GB|B)/i);
                if (m) {
                    size = m[0];
                    break;
                }
            }

            if (!name || name.length < 3) continue;
            const key = did || name;
            if (seen.has(key)) continue;
            seen.add(key);

            const entry = {
                title: name,
                url: previewUrl || downloadUrl || location.href,
            };
            if (size) entry.subtitle = size;
            if (previewUrl) {
                entry.canRead = true;
                entry.url = previewUrl;
            }
            if (downloadUrl) {
                entry.downloadUrl = downloadUrl;
                // Prefer downloadable archive when available
                if (!previewUrl) {
                    entry.url = downloadUrl;
                }
            }
            items.push(entry);
        }

        // Also catch standalone preview / download links outside tables
        if (items.length === 0) {
            for (const a of document.querySelectorAll('a[href*="did="], a[href*="preview"]')) {
                const href = absolute(a.getAttribute("href"));
                if (!href || seen.has(href)) continue;
                const title = clean(a.textContent) || `Issue ${param("did", href) || ""}`;
                if (!title || /comment|select/i.test(title)) continue;
                seen.add(href);
                const entry = { title, url: href };
                if (/preview/i.test(href)) entry.canRead = true;
                items.push(entry);
            }
        }

        return items;
    }

    function parsePreviewPages() {
        // Preview viewer: /preview/index.php?did=ID&page=N
        const did = param("did");
        if (!did) return [];

        const pages = [];
        // Try to discover total pages from select or page indicators
        let maxPage = 0;
        const sel = document.querySelector("select[name*='page'], select#page, select.selectPage, select");
        if (sel) {
            for (const opt of sel.options) {
                const n = parseInt(opt.value || opt.textContent, 10);
                if (Number.isFinite(n) && n > maxPage) maxPage = n;
            }
        }
        // Fallback: look for page links
        for (const a of document.querySelectorAll('a[href*="page="]')) {
            const n = parseInt(param("page", a.href), 10);
            if (Number.isFinite(n) && n > maxPage) maxPage = n;
        }
        // Another common pattern: thumbnail strip
        const thumbs = document.querySelectorAll('img[src*="page="], a[href*="page="] img');
        if (thumbs.length > maxPage) maxPage = thumbs.length;

        if (maxPage < 1) maxPage = 1; // at least current page

        const base = `${ORIGIN}/preview/index.php?did=${encodeURIComponent(did)}&page=`;
        for (let i = 1; i <= maxPage; i++) {
            pages.push(base + i);
        }
        return pages;
    }

    // Try to extract direct image URLs from the current preview page
    function currentPreviewImage() {
        const img =
            document.querySelector("#page img") ||
            document.querySelector(".preview img") ||
            document.querySelector("img[src*='preview']") ||
            document.querySelector("img[src*='did=']") ||
            document.querySelector("img[src*='/comics/']") ||
            document.querySelector("img[src*='/files/']");
        if (img?.src) return absolute(img.src);
        // Meta / og
        const og = document.querySelector('meta[property="og:image"]')?.content;
        if (og) return absolute(og);
        return null;
    }

    // --- Plugin contract ---------------------------------------------------

    const source = {
        manifest: {
            id: "digitalcomicmuseum",
            name: "Digital Comic Museum",
            version: "1.0.0",
            description:
                "Public-domain Golden Age comics. Browse by publisher. Free account needed for downloads & full preview.",
            author: "Comic Viewer community",
            homepage: ORIGIN,
            browseURL: ORIGIN + "/",
        },

        async parseCatalog() {
            const items = [];

            if (isPreviewPath()) {
                // Single issue preview → treat as readable entry
                const title = pageTitle();
                const img = currentPreviewImage();
                items.push({
                    title: title || `DCM #${param("did") || ""}`,
                    url: location.href,
                    canRead: true,
                    cover: img || undefined,
                });
                return items;
            }

            // Publisher / series listing
            const issues = parseIssueRows();
            if (issues.length > 0) {
                return issues;
            }

            // Top-level publisher index
            const pubs = parsePublisherLinks();
            if (pubs.length > 0) {
                return pubs;
            }

            // Fallback: any meaningful internal links
            const seen = new Set();
            for (const a of document.querySelectorAll("a[href]")) {
                const href = absolute(a.getAttribute("href"));
                if (!href || !href.startsWith(ORIGIN) || seen.has(href)) continue;
                const t = clean(a.textContent);
                if (!t || t.length < 3) continue;
                if (/log\s*in|register|forum|donate|home|search/i.test(t)) continue;
                seen.add(href);
                const opens = !!param("cid", href);
                items.push({
                    title: t.slice(0, 120),
                    url: href,
                    opensCatalog: opens,
                });
                if (items.length >= 80) break;
            }
            return items;
        },

        async parsePages() {
            if (!isPreviewPath()) return [];

            // Prefer actual image URLs when the current page has them
            const img = currentPreviewImage();
            if (img) {
                // Build sequential page URLs from the did + page pattern
                const did = param("did");
                const current = parseInt(param("page") || "1", 10) || 1;
                let max = current;
                const sel = document.querySelector("select");
                if (sel) {
                    for (const opt of sel.options) {
                        const n = parseInt(opt.value || opt.textContent, 10);
                        if (Number.isFinite(n) && n > max) max = n;
                    }
                }
                // Heuristic: many Golden Age books are 36–68 pages
                if (max < 2) max = 52;

                const pages = [];
                // If we only have the current image URL pattern, try to generalize
                // Otherwise fall back to preview page URLs (viewer will load each)
                for (let i = 1; i <= max; i++) {
                    pages.push(`${ORIGIN}/preview/index.php?did=${encodeURIComponent(did)}&page=${i}`);
                }
                return pages;
            }

            return parsePreviewPages();
        },

        canRead() {
            return isPreviewPath() || !!document.querySelector('a[href*="preview"]');
        },

        opensCatalog() {
            return isCategoryOrSeries() && !isPreviewPath();
        },
    };

    globalThis.ComicViewerSource = source;
})();
