// Comic Viewer source plugin for GlobalComix (globalcomix.com).
// Install from Preferences -> Sources -> Source plugins.
//
// Catalog is parsed from the page DOM and window.__INITIAL_STATE__ (React Query cache).
// Series pages list releases under /c/{slug}/r/{uuid}.
// Full-page streaming often requires a free/Gold account on the site; this plugin
// focuses on browse + release discovery. parsePages() best-efforts reader images.

(() => {
    const ORIGIN = "https://globalcomix.com";

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

    function isSeriesPath(pathname = pathOf()) {
        return /^\/c\/[^/]+\/?$/i.test(pathname);
    }

    function isReleasePath(pathname = pathOf()) {
        return /^\/c\/[^/]+\/r\/[^/]+\/?$/i.test(pathname);
    }

    function isBrowsePath(pathname = pathOf()) {
        return /^\/browse\//i.test(pathname) || pathname === "/";
    }

    function pageTitle() {
        const t = clean(document.title || "");
        return t
            .replace(/\s*[|–—].*GlobalComix.*$/i, "")
            .replace(/\s*Comics?\s*$/i, "")
            .trim() || "GlobalComix";
    }

    function readInitialState() {
        try {
            if (window.__INITIAL_STATE__) return window.__INITIAL_STATE__;
        } catch (_) {}
        for (const script of document.querySelectorAll("script")) {
            const text = script.textContent || "";
            if (!text.includes("__INITIAL_STATE__")) continue;
            const idx = text.indexOf("__INITIAL_STATE__");
            const eq = text.indexOf("=", idx);
            if (eq < 0) continue;
            let i = eq + 1;
            while (text[i] && /\s/.test(text[i])) i++;
            if (text[i] !== "{") continue;
            let depth = 0;
            let inStr = false;
            let esc = false;
            for (let j = i; j < text.length; j++) {
                const ch = text[j];
                if (inStr) {
                    if (esc) esc = false;
                    else if (ch === "\\") esc = true;
                    else if (ch === '"') inStr = false;
                    continue;
                }
                if (ch === '"') inStr = true;
                else if (ch === "{") depth++;
                else if (ch === "}") {
                    depth--;
                    if (depth === 0) {
                        try {
                            return JSON.parse(text.slice(i, j + 1));
                        } catch (_) {
                            return null;
                        }
                    }
                }
            }
        }
        return null;
    }

    function queriesFromState(state) {
        return Array.isArray(state?.queries) ? state.queries : [];
    }

    function seriesFromSearchPayload(payload) {
        const series = payload?.results?.series?.items;
        if (!Array.isArray(series)) return [];
        return series.map((s) => ({
            id: String(s.id || s.slug),
            title: clean(s.name) || s.slug,
            description: clean(
                [s.artist_name, s.releases_count_string, s.is_free ? "Free" : null]
                    .filter(Boolean)
                    .join(" · ")
            ),
            cover: absolute(s.cover_image_url),
            link: absolute(s.url || `/c/${s.slug}`),
            opensCatalog: true,
            canRead: false,
            hasMirrors: false,
            mirrors: [],
            metadata: { comicId: s.id, slug: s.slug, isFree: s.is_free }
        }));
    }

    function seriesFromDom() {
        const comics = [];
        const seen = new Set();
        for (const a of document.querySelectorAll('a[href*="/c/"]')) {
            const href = absolute(a.getAttribute("href"));
            if (!href) continue;
            let path;
            try {
                path = new URL(href).pathname;
            } catch (_) {
                continue;
            }
            // Series only: /c/slug  (not /c/slug/r/uuid)
            if (!/^\/c\/[^/]+\/?$/i.test(path)) continue;
            if (seen.has(path)) continue;
            const title = clean(a.getAttribute("title") || a.textContent);
            if (!title || title.length < 2) continue;
            seen.add(path);
            const img =
                a.querySelector("img[src], img[data-src]") ||
                a.parentElement?.querySelector("img[src], img[data-src]");
            comics.push({
                id: path,
                title,
                cover: absolute(
                    img?.getAttribute("src") || img?.getAttribute("data-src")
                ),
                link: href,
                opensCatalog: true,
                canRead: false,
                hasMirrors: false,
                mirrors: []
            });
            if (comics.length >= 80) break;
        }
        return comics;
    }

    function releasesFromState(state) {
        for (const q of queriesFromState(state)) {
            const key = JSON.stringify(q.queryKey || []);
            if (!/get-comic-releases|releases/i.test(key)) continue;
            const payload = q.state?.data?.data?.payload;
            const results = payload?.results;
            if (!Array.isArray(results)) continue;
            return results.map((r) => {
                const slug = r.comic_slug || r.slug;
                const relSlug = r.slug;
                const uuid =
                    r.uuid ||
                    r.release_uuid ||
                    (typeof r.url === "string" && r.url.match(/\/r\/([^/]+)/)?.[1]);
                // Prefer explicit release path when present in INITIAL_STATE HTML links
                let link = r.url ? absolute(r.url) : null;
                if (!link && uuid && r.comic_slug) {
                    link = `${ORIGIN}/c/${r.comic_slug}/r/${uuid}`;
                }
                return {
                    id: String(r.id || relSlug || link),
                    title: clean(r.name || r.title || relSlug) || "Release",
                    series: clean(r.comic_name),
                    cover: absolute(r.cover_image_url || r.cover),
                    link,
                    canRead: true,
                    opensCatalog: false,
                    hasMirrors: false,
                    mirrors: [],
                    description: clean(
                        [
                            r.is_free || r.license_type === "free" ? "Free" : "May require account",
                            r.page_count ? `${r.page_count} pages` : null
                        ]
                            .filter(Boolean)
                            .join(" · ")
                    ),
                    metadata: {
                        releaseId: r.id,
                        comicId: r.comic_id,
                        slug: relSlug
                    }
                };
            });
        }
        return [];
    }

    function releasesFromDom(seriesTitle) {
        const comics = [];
        const seen = new Set();
        for (const a of document.querySelectorAll('a[href*="/r/"]')) {
            const href = absolute(a.getAttribute("href"));
            if (!href) continue;
            let path;
            try {
                path = new URL(href).pathname;
            } catch (_) {
                continue;
            }
            if (!/^\/c\/[^/]+\/r\/[^/]+\/?$/i.test(path)) continue;
            if (seen.has(path)) continue;
            seen.add(path);
            const title = clean(a.getAttribute("title") || a.textContent) || path.split("/").pop();
            const img =
                a.querySelector("img") || a.parentElement?.querySelector("img");
            comics.push({
                id: path,
                title,
                series: seriesTitle || null,
                cover: absolute(img?.getAttribute("src") || img?.getAttribute("data-src")),
                link: href,
                canRead: true,
                opensCatalog: false,
                hasMirrors: false,
                mirrors: []
            });
        }
        return comics;
    }

    function browseCatalogs() {
        return [
            { name: "Comics", url: `${ORIGIN}/browse/comics` },
            { name: "Manga", url: `${ORIGIN}/browse/manga` },
            { name: "Web comics", url: `${ORIGIN}/browse/web-comics` },
            { name: "Graphic novels", url: `${ORIGIN}/browse/graphic-novels` },
            { name: "New", url: `${ORIGIN}/new` }
        ];
    }

    function genreCatalogsFromDom() {
        const catalogs = [];
        const seen = new Set();
        for (const a of document.querySelectorAll('a[href*="/browse/comics/"]')) {
            const href = absolute(a.getAttribute("href"));
            const title = clean(a.textContent);
            if (!href || !title || title.length < 2 || seen.has(href)) continue;
            seen.add(href);
            catalogs.push({ name: title, url: href });
        }
        return catalogs;
    }

    function parseBrowseCatalog(state) {
        let comics = [];
        for (const q of queriesFromState(state)) {
            const key = JSON.stringify(q.queryKey || []);
            if (!/search-query|browse/i.test(key)) continue;
            const pages = q.state?.data?.pages;
            if (Array.isArray(pages)) {
                for (const page of pages) {
                    const payload = page?.data?.payload || page?.payload;
                    comics = comics.concat(seriesFromSearchPayload(payload));
                }
            } else {
                const payload = q.state?.data?.data?.payload;
                comics = comics.concat(seriesFromSearchPayload(payload));
            }
        }
        if (comics.length === 0) comics = seriesFromDom();

        // de-dupe by link
        const seen = new Set();
        comics = comics.filter((c) => {
            if (!c.link || seen.has(c.link)) return false;
            seen.add(c.link);
            return true;
        });

        return {
            name: pageTitle() || "GlobalComix Comics",
            comics,
            catalogs: [...browseCatalogs(), ...genreCatalogsFromDom()].slice(0, 40)
        };
    }

    function parseSeriesCatalog(state) {
        const title = pageTitle();
        let comics = releasesFromState(state).filter((c) => c.link);
        if (comics.length === 0) comics = releasesFromDom(title);

        // Attach missing links from DOM by matching titles when possible
        if (comics.some((c) => !c.link)) {
            const dom = releasesFromDom(title);
            comics = comics.map((c, i) => ({
                ...c,
                link: c.link || dom[i]?.link || null
            }));
        }

        return {
            name: title,
            comics: comics.filter((c) => c.link),
            catalogs: browseCatalogs()
        };
    }

    function pageImagesFromDom() {
        const seen = new Set();
        const pages = [];
        for (const img of document.querySelectorAll(
            "img[src], img[data-src], img[data-lazy-src]"
        )) {
            const raw =
                img.getAttribute("data-src") ||
                img.getAttribute("data-lazy-src") ||
                img.getAttribute("src");
            const href = absolute(raw);
            if (!href || seen.has(href)) continue;
            if (/logo|avatar|icon|emoji|spinner|social|pixel/i.test(href)) continue;
            if (
                !/\/img\/|\/page|processed|release|cdn|cloudfront/i.test(href) &&
                !/\.(jpe?g|png|webp)(\?|$)/i.test(href)
            ) {
                continue;
            }
            // Prefer large page assets over tiny covers
            const w = Number(img.naturalWidth || img.getAttribute("width") || 0);
            if (w && w < 200) continue;
            seen.add(href);
            pages.push(href);
        }
        return pages;
    }

    globalThis.ComicViewerSource = {
        manifest: {
            id: "globalcomix",
            name: "GlobalComix",
            version: "1.0.0",
            homepage: ORIGIN,
            description:
                "Browse series and releases on GlobalComix. Many titles need a free/Gold account to read all pages online.",
            tags: ["comic", "english", "marvel", "dc", "manga"],
            capabilities: ["browse", "search", "read"]
        },

        browseURL: `${ORIGIN}/browse/comics`,

        searchURL(query) {
            return `${ORIGIN}/search?q=${encodeURIComponent(query || "")}`;
        },

        async parseCatalog() {
            const state = readInitialState();

            if (isReleasePath()) {
                return {
                    name: pageTitle(),
                    comics: [
                        {
                            id: pathOf(),
                            title: pageTitle(),
                            link: location.href,
                            canRead: true,
                            opensCatalog: false,
                            hasMirrors: false,
                            mirrors: []
                        }
                    ],
                    catalogs: browseCatalogs()
                };
            }

            if (isSeriesPath()) {
                return parseSeriesCatalog(state);
            }

            return parseBrowseCatalog(state);
        },

        parsePages() {
            // Best-effort: GlobalComix reader is heavily JS-driven and often gated.
            // When page images are present in the DOM, surface them.
            return { pages: pageImagesFromDom() };
        }
    };
})();
