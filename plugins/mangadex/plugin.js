// Comic Viewer source plugin for MangaDex (mangadex.org).
// Install from Preferences -> Sources -> Source plugins.
//
// Uses the public MangaDex API (api.mangadex.org). No login required for
// browsing or reading. Credits MangaDex and scanlation groups per their AUP.
//
// Focus: English chapters by default; other languages available via feed.

(() => {
    const ORIGIN = "https://mangadex.org";
    const API = "https://api.mangadex.org";
    const COVER_BASE = "https://uploads.mangadex.org/covers";
    const LIMIT = 30;

    function absolute(raw, base = ORIGIN) {
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

    function uuidFromPath(pathname = pathOf()) {
        // /title/{uuid}/... or /chapter/{uuid}
        const m = pathname.match(/\/(title|chapter)\/([0-9a-f-]{36})/i);
        return m ? { type: m[1].toLowerCase(), id: m[2] } : null;
    }

    function titleFromAttrs(attrs) {
        if (!attrs) return "Untitled";
        const t = attrs.title || {};
        return t.en || t["ja-ro"] || t.ja || Object.values(t)[0] || "Untitled";
    }

    function coverUrl(mangaId, fileName, size = 256) {
        if (!mangaId || !fileName) return null;
        // size: 256 or 512
        return `${COVER_BASE}/${mangaId}/${fileName}.${size}.jpg`;
    }

    async function fetchJSON(url) {
        const r = await fetch(url, {
            headers: { Accept: "application/json" },
            credentials: "omit",
        });
        if (!r.ok) throw new Error(`MangaDex API ${r.status} for ${url}`);
        return r.json();
    }

    // --- API helpers -------------------------------------------------------

    async function searchManga(query, offset = 0) {
        const params = new URLSearchParams({
            limit: String(LIMIT),
            offset: String(offset),
            "order[relevance]": "desc",
            "includes[]": "cover_art",
            "contentRating[]": "safe",
            "contentRating[]": "suggestive",
            "contentRating[]": "erotica",
            "hasAvailableChapters": "true",
        });
        // contentRating repeated — rebuild properly
        const p = new URLSearchParams();
        p.set("limit", String(LIMIT));
        p.set("offset", String(offset));
        p.set("order[relevance]", "desc");
        p.append("includes[]", "cover_art");
        p.append("contentRating[]", "safe");
        p.append("contentRating[]", "suggestive");
        p.append("contentRating[]", "erotica");
        p.set("hasAvailableChapters", "true");
        if (query) p.set("title", query);

        const data = await fetchJSON(`${API}/manga?${p}`);
        return (data.data || []).map(parseMangaItem);
    }

    async function popularManga(offset = 0) {
        const p = new URLSearchParams();
        p.set("limit", String(LIMIT));
        p.set("offset", String(offset));
        p.set("order[followedCount]", "desc");
        p.append("includes[]", "cover_art");
        p.append("contentRating[]", "safe");
        p.append("contentRating[]", "suggestive");
        p.append("contentRating[]", "erotica");
        p.set("hasAvailableChapters", "true");

        const data = await fetchJSON(`${API}/manga?${p}`);
        return (data.data || []).map(parseMangaItem);
    }

    function parseMangaItem(manga) {
        const id = manga.id;
        const attrs = manga.attributes || {};
        const title = titleFromAttrs(attrs);
        let cover = null;
        for (const rel of manga.relationships || []) {
            if (rel.type === "cover_art" && rel.attributes?.fileName) {
                cover = coverUrl(id, rel.attributes.fileName);
                break;
            }
        }
        return {
            title,
            url: `${ORIGIN}/title/${id}`,
            cover: cover || undefined,
            opensCatalog: true,
            subtitle: attrs.status || undefined,
        };
    }

    async function mangaFeed(mangaId, offset = 0) {
        const p = new URLSearchParams();
        p.set("limit", "100");
        p.set("offset", String(offset));
        p.append("translatedLanguage[]", "en");
        p.set("order[chapter]", "asc");
        p.set("order[volume]", "asc");
        p.append("includes[]", "scanlation_group");
        p.set("contentRating[]", "safe");
        // also allow suggestive/erotica so feed is complete
        p.append("contentRating[]", "suggestive");
        p.append("contentRating[]", "erotica");

        const data = await fetchJSON(`${API}/manga/${mangaId}/feed?${p}`);
        const chapters = [];
        for (const ch of data.data || []) {
            const a = ch.attributes || {};
            if (a.pages === 0 && !a.externalUrl) continue; // empty
            const vol = a.volume ? `Vol. ${a.volume} ` : "";
            const num = a.chapter != null ? `Ch. ${a.chapter}` : "Oneshot";
            const name = a.title ? ` – ${a.title}` : "";
            let group = "";
            for (const rel of ch.relationships || []) {
                if (rel.type === "scanlation_group" && rel.attributes?.name) {
                    group = rel.attributes.name;
                    break;
                }
            }
            chapters.push({
                title: `${vol}${num}${name}`.trim(),
                url: `${ORIGIN}/chapter/${ch.id}`,
                canRead: true,
                subtitle: group || undefined,
            });
        }
        return chapters;
    }

    async function chapterPages(chapterId) {
        const data = await fetchJSON(`${API}/at-home/server/${chapterId}`);
        const base = data.baseUrl;
        const hash = data.chapter?.hash;
        const files = data.chapter?.data || data.chapter?.dataSaver || [];
        if (!base || !hash || !files.length) return [];

        // Prefer high quality (data); fall back to data-saver
        const quality = data.chapter?.data?.length ? "data" : "data-saver";
        const list = quality === "data" ? data.chapter.data : data.chapter.dataSaver;
        return list.map((f) => `${base}/${quality}/${hash}/${f}`);
    }

    // --- DOM / location helpers for when the WebView is on mangadex.org ----

    function isTitlePage() {
        return !!uuidFromPath()?.id && uuidFromPath().type === "title";
    }

    function isChapterPage() {
        return !!uuidFromPath()?.id && uuidFromPath().type === "chapter";
    }

    // --- Plugin contract ---------------------------------------------------

    const source = {
        manifest: {
            id: "mangadex",
            name: "MangaDex",
            version: "1.0.0",
            description:
                "Manga & scanlation reader via official MangaDex API. English chapters by default.",
            author: "Comic Viewer community",
            homepage: ORIGIN,
            browseURL: ORIGIN + "/",
        },

        async parseCatalog() {
            const u = uuidFromPath();

            // Chapter page → single readable entry
            if (u?.type === "chapter") {
                return [
                    {
                        title: document.title?.replace(/\s*[-–—].*MangaDex.*$/i, "").trim() || "Chapter",
                        url: location.href,
                        canRead: true,
                    },
                ];
            }

            // Title (series) page → chapter feed
            if (u?.type === "title") {
                try {
                    return await mangaFeed(u.id);
                } catch (e) {
                    console.warn("MangaDex feed error", e);
                    return [];
                }
            }

            // Home / browse / search → popular list
            try {
                // If URL has a search query, use it
                let q = null;
                try {
                    q = new URL(location.href).searchParams.get("q") ||
                        new URL(location.href).searchParams.get("title");
                } catch (_) {}
                if (q) return await searchManga(q);
                return await popularManga(0);
            } catch (e) {
                console.warn("MangaDex list error", e);
                // DOM fallback
                const items = [];
                const seen = new Set();
                for (const a of document.querySelectorAll('a[href*="/title/"]')) {
                    const href = absolute(a.getAttribute("href"));
                    if (!href || seen.has(href)) continue;
                    const m = href.match(/\/title\/([0-9a-f-]{36})/i);
                    if (!m) continue;
                    seen.add(href);
                    const title = clean(a.textContent) || m[1];
                    if (title.length < 2) continue;
                    items.push({ title, url: href, opensCatalog: true });
                    if (items.length >= 40) break;
                }
                return items;
            }
        },

        async parsePages() {
            const u = uuidFromPath();
            if (u?.type !== "chapter") return [];
            try {
                return await chapterPages(u.id);
            } catch (e) {
                console.warn("MangaDex pages error", e);
                return [];
            }
        },

        canRead() {
            return isChapterPage();
        },

        opensCatalog() {
            return isTitlePage() || pathOf() === "/" || /\/titles|\/search|\/recent/i.test(pathOf());
        },
    };

    globalThis.ComicViewerSource = source;
})();
