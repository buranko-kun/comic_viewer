// Comic Viewer source plugin for Comic Book Plus (comicbookplus.com).
// Install from Preferences -> Sources -> Source plugins (local file or raw URL).
//
// Public-domain Golden/Silver Age comics. Online reading is free for guests;
// CBR/CBZ downloads require a free site account and are not exposed here.
//
// If the site blocks automated access, open this plugin's homepage from
// Preferences -> Sources so the embedded WebView can establish a normal session.

(() => {
    const ORIGIN = "https://comicbookplus.com";
    const VIEWER_HOST = "https://box01.comicbookplus.com";

    function absolute(raw, base = location.href) {
        if (!raw) return null;
        try {
            return new URL(raw, base).href;
        } catch (_) {
            return null;
        }
    }

    function clean(text) {
        return (text || "")
            .replace(/<[^>]+>/g, " ")
            .replace(/\s+/g, " ")
            .trim();
    }

    function param(name, url = location.href) {
        try {
            return new URL(url).searchParams.get(name);
        } catch (_) {
            return null;
        }
    }

    function isIssuePage(url = location.href) {
        return !!param("dlid", url);
    }

    function isSeriesPage(url = location.href) {
        return !!param("cid", url);
    }

    function isCategoryPage(url = location.href) {
        const cb = param("cbplus", url);
        if (!cb) return false;
        // Genre pages and the categories index.
        return cb === "categories" || !/^(search|login|register|recentactivity|mycomicbookplus)/i.test(cb);
    }

    function pageTitle() {
        const og = document.querySelector('meta[property="og:title"]')?.getAttribute("content");
        const t = clean(og || document.title || "");
        return t.replace(/\s*[-–—]\s*Comic Book Plus\s*$/i, "").trim() || "Comic Book Plus";
    }

    function issueCoverFromDoc(doc = document) {
        const og = doc.querySelector('meta[property="og:image"]')?.getAttribute("content");
        if (og) return absolute(og);
        const main = doc.querySelector("#maincomic");
        if (main?.getAttribute("src")) {
            const src = absolute(main.getAttribute("src"));
            // Prefer largethumb beside 0.jpg when possible.
            if (src && /\/\d+\.(?:jpg|jpeg|png|webp)$/i.test(src)) {
                return src.replace(/\/\d+\.(jpg|jpeg|png|webp)$/i, "/largethumb.jpg");
            }
            return src;
        }
        return null;
    }

    function numberOfPages(doc = document) {
        const el = doc.querySelector('[itemprop="numberOfPages"]');
        const n = Number(clean(el?.textContent || ""));
        return Number.isFinite(n) && n > 0 ? n : 0;
    }

    function viewerBaseFromMainComic(doc = document) {
        const main = doc.querySelector("#maincomic");
        const src = main?.getAttribute("src");
        if (!src) return null;
        try {
            const url = new URL(src, location.href);
            // .../viewer/b5/hash/0.jpg → .../viewer/b5/hash/
            return url.href.replace(/\/[^/]+$/, "/");
        } catch (_) {
            return null;
        }
    }

    function buildPageURLs(base, pages) {
        if (!base || !pages) return [];
        const list = [];
        for (let i = 0; i < pages; i++) {
            list.push(`${base}${i}.jpg`);
        }
        return list;
    }

    function issueEntryFromDlid(dlid, title, cover, series) {
        const id = String(dlid);
        return {
            id: `dlid-${id}`,
            title: title || `Issue ${id}`,
            cover: cover || null,
            series: series || null,
            link: `${ORIGIN}/?dlid=${id}`,
            canRead: true,
            opensCatalog: false,
            hasMirrors: false,
            mirrors: [],
            metadata: { dlid: id }
        };
    }

    /**
     * Series (cid) pages list issues as schema.org/Book rows.
     */
    function parseSeriesIssues(doc = document) {
        const series = pageTitle();
        const comics = [];
        const seen = new Set();

        for (const row of doc.querySelectorAll('[itemtype="https://schema.org/Book"]')) {
            const discussion = row.querySelector('meta[itemprop="discussionUrl"]')?.getAttribute("content")
                || row.querySelector('a[href*="dlid="]')?.getAttribute("href");
            if (!discussion) continue;

            let dlid = null;
            try {
                dlid = new URL(discussion, ORIGIN).searchParams.get("dlid");
            } catch (_) {
                const m = String(discussion).match(/dlid=(\d+)/);
                dlid = m ? m[1] : null;
            }
            if (!dlid || seen.has(dlid)) continue;
            seen.add(dlid);

            const thumb = row.querySelector('meta[itemprop="thumbnailUrl"]')?.getAttribute("content");
            let title = clean(row.querySelector('[itemprop="name"]')?.textContent);
            if (!title) {
                const anchor = row.querySelector('a.Wanchor, a[href*="dlid="]');
                title = clean(anchor?.textContent);
            }
            if (!title) title = `Issue ${dlid}`;

            comics.push(issueEntryFromDlid(dlid, title, absolute(thumb), series));
        }

        // Fallback: any dlid links with visible text.
        if (comics.length === 0) {
            for (const a of doc.querySelectorAll('a[href*="dlid="]')) {
                const href = absolute(a.getAttribute("href"));
                if (!href) continue;
                let dlid;
                try {
                    dlid = new URL(href).searchParams.get("dlid");
                } catch (_) {
                    continue;
                }
                if (!dlid || seen.has(dlid) || !/^\d+$/.test(dlid)) continue;
                seen.add(dlid);
                comics.push(issueEntryFromDlid(dlid, clean(a.textContent) || `Issue ${dlid}`, null, series));
            }
        }

        comics.sort((a, b) =>
            a.title.localeCompare(b.title, undefined, { numeric: true, sensitivity: "base" })
        );

        return {
            name: series,
            comics,
            catalogs: [
                { name: "Categories", url: `${ORIGIN}/?cbplus=categories` },
                { name: "Home", url: `${ORIGIN}/` }
            ]
        };
    }

    function parseIssueAsReadable() {
        const dlid = param("dlid");
        const title = pageTitle();
        const cover = issueCoverFromDoc();
        const pages = numberOfPages();
        const entry = issueEntryFromDlid(dlid, title, cover, null);
        entry.description = pages ? `${pages} pages · online reader` : "Online reader";
        entry.metadata.pageCount = pages || null;

        // Also surface same-series siblings if present on the page sidebar.
        const siblings = [];
        const seen = new Set([String(dlid)]);
        for (const a of document.querySelectorAll('a[href*="dlid="]')) {
            const href = absolute(a.getAttribute("href"));
            if (!href) continue;
            let id;
            try {
                id = new URL(href).searchParams.get("dlid");
            } catch (_) {
                continue;
            }
            if (!id || seen.has(id) || !/^\d+$/.test(id)) continue;
            const label = clean(a.textContent);
            if (!label || label.length < 2) continue;
            seen.add(id);
            siblings.push(issueEntryFromDlid(id, label, null, null));
            if (siblings.length >= 40) break;
        }

        return {
            name: title,
            comics: [entry, ...siblings],
            catalogs: [
                { name: "Categories", url: `${ORIGIN}/?cbplus=categories` },
                { name: "Latest uploads", url: `${ORIGIN}/?cbplus=latestuploads_l_s_0` },
                { name: "Home", url: `${ORIGIN}/` }
            ]
        };
    }

    function parseCategoryOrHome() {
        const comics = [];
        const catalogs = [];
        const seenCid = new Set();
        const seenDlid = new Set();

        // Genre / series links (?cid=)
        for (const a of document.querySelectorAll('a[href*="cid="]')) {
            const href = absolute(a.getAttribute("href"));
            if (!href) continue;
            let cid;
            try {
                cid = new URL(href).searchParams.get("cid");
            } catch (_) {
                continue;
            }
            if (!cid || seenCid.has(cid)) continue;
            const title = clean(a.textContent);
            if (!title || title.length < 2) continue;
            // Skip pure count labels like "24 Books"
            if (/^\d+\s+Books?$/i.test(title)) continue;
            seenCid.add(cid);
            catalogs.push({
                name: title,
                url: `${ORIGIN}/?cid=${cid}`
            });
        }

        // Genre index links (?cbplus=genre)
        if (param("cbplus") === "categories" || location.pathname === "/" || !param("cbplus")) {
            for (const a of document.querySelectorAll('a[href*="cbplus="]')) {
                const href = absolute(a.getAttribute("href"));
                if (!href) continue;
                let cb;
                try {
                    cb = new URL(href).searchParams.get("cbplus");
                } catch (_) {
                    continue;
                }
                if (!cb || /^(categories|latestuploads|recentactivity|mycomicbookplus|sponsor|insite|search)/i.test(cb)) {
                    continue;
                }
                const title = clean(a.textContent);
                if (!title || title.length < 3 || /more\s*\.*/i.test(title)) continue;
                catalogs.push({ name: title, url: href });
            }
        }

        // Latest / featured issues on the page
        for (const a of document.querySelectorAll('a[href*="dlid="]')) {
            const href = absolute(a.getAttribute("href"));
            if (!href) continue;
            let dlid;
            try {
                dlid = new URL(href).searchParams.get("dlid");
            } catch (_) {
                continue;
            }
            if (!dlid || seenDlid.has(dlid) || !/^\d+$/.test(dlid)) continue;
            const title = clean(a.textContent);
            if (!title || title.length < 2) continue;
            seenDlid.add(dlid);

            let cover = null;
            const img = a.querySelector("img[src]") || a.parentElement?.querySelector("img[src]");
            if (img) cover = absolute(img.getAttribute("src"));

            comics.push(issueEntryFromDlid(dlid, title, cover, null));
            if (comics.length >= 60) break;
        }

        // De-dupe catalogs by URL
        const catSeen = new Set();
        const uniqueCatalogs = [];
        for (const c of catalogs) {
            if (catSeen.has(c.url)) continue;
            catSeen.add(c.url);
            uniqueCatalogs.push(c);
        }

        // Stable top-level shortcuts
        const shortcuts = [
            { name: "Categories", url: `${ORIGIN}/?cbplus=categories` },
            { name: "Latest uploads", url: `${ORIGIN}/?cbplus=latestuploads_l_s_0` },
            { name: "Home", url: `${ORIGIN}/` }
        ];
        for (const s of shortcuts) {
            if (!catSeen.has(s.url)) {
                uniqueCatalogs.unshift(s);
                catSeen.add(s.url);
            }
        }

        return {
            name: pageTitle() || "Comic Book Plus",
            comics,
            catalogs: uniqueCatalogs.slice(0, 200)
        };
    }

    function blockedNotice() {
        const text = clean(document.body?.innerText || "").slice(0, 500);
        if (/unusual activity|access to this page is blocked|An Error Has Occurred/i.test(text)) {
            return {
                name: "Comic Book Plus",
                comics: [],
                catalogs: [{ name: "Open site in source browser", url: ORIGIN }]
            };
        }
        return null;
    }

    globalThis.ComicViewerSource = {
        manifest: {
            id: "comicbookplus",
            name: "Comic Book Plus",
            version: "1.0.0",
            homepage: ORIGIN,
            description:
                "Public-domain Golden & Silver Age comics from comicbookplus.com. Streams the free online reader (page images). Archive downloads require a free account on the site.",
            tags: ["comic", "english", "public-domain", "golden-age", "silver-age"],
            capabilities: ["browse", "search", "read"]
        },

        browseURL: `${ORIGIN}/?cbplus=categories`,

        searchURL(query) {
            // Site uses Google CSE; deep-link to a title search via Google site filter as a practical entry.
            // Users can also browse categories. A dedicated network search hook may be added later by the app.
            return `${ORIGIN}/?cbplus=categories`;
        },

        async parseCatalog() {
            const blocked = blockedNotice();
            if (blocked) return blocked;

            if (isIssuePage()) {
                return parseIssueAsReadable();
            }
            if (isSeriesPage()) {
                return parseSeriesIssues();
            }
            return parseCategoryOrHome();
        },

        parsePages() {
            const blocked = blockedNotice();
            if (blocked) return { pages: [] };

            const pages = numberOfPages();
            const base = viewerBaseFromMainComic();
            if (!base || !pages) {
                // Fallback: only the current main image if metadata is missing.
                const main = document.querySelector("#maincomic")?.getAttribute("src");
                return { pages: main ? [absolute(main)].filter(Boolean) : [] };
            }
            return { pages: buildPageURLs(base, pages) };
        }
    };
})();
