// Comic Viewer source plugin for CompartiComics (comparticomics.lat).
// Install from Preferences -> Sources -> Source plugins (local file or raw URL).
//
// CompartiComics is a Spanish-language comic archive library (CBR/CBZ/RAR downloads).
// This plugin browses categories and groups via the site JSON API and exposes each
// volume as a downloadable archive link. It does not stream individual page images.
//
// Guest downloads are rate-limited by the site (file count + GB/day). Open the source
// browser from Preferences -> Sources if a donation popup or session cookie is needed.

(() => {
    const ORIGIN = "https://comparticomics.lat";
    const COVER_CDN = "https://pub-66468df6e7e04d23a0daed8394f7fb9c.r2.dev";
    const PAGE_SIZE = 40;

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

    function coverUrl(coverMsgId) {
        if (coverMsgId == null || coverMsgId === "") return null;
        return `${COVER_CDN}/${coverMsgId}.jpg`;
    }

    function formatFromMime(mime, filename) {
        const m = (mime || "").toLowerCase();
        const f = (filename || "").toLowerCase();
        if (m.includes("cbr") || f.endsWith(".cbr")) return "CBR";
        if (m.includes("cbz") || f.endsWith(".cbz")) return "CBZ";
        if (m.includes("pdf") || f.endsWith(".pdf")) return "PDF";
        if (m.includes("rar") || f.endsWith(".rar")) return "RAR";
        if (m.includes("zip") || f.endsWith(".zip")) return "ZIP";
        if (m.includes("7z") || f.endsWith(".7z")) return "7Z";
        return null;
    }

    function humanSize(bytes) {
        const n = Number(bytes);
        if (!Number.isFinite(n) || n <= 0) return null;
        if (n >= 1024 * 1024 * 1024) return `${(n / (1024 * 1024 * 1024)).toFixed(1)} GB`;
        if (n >= 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
        if (n >= 1024) return `${(n / 1024).toFixed(0)} KB`;
        return `${n} B`;
    }

    function volumeTitle(vol, groupTitle) {
        const title = clean(vol.title || vol.filename || groupTitle || "Untitled");
        return title;
    }

    function volumeEntry(vol, group) {
        const id = String(vol.id);
        const title = volumeTitle(vol, group && groupTitleFallback(group));
        const cover = coverUrl(vol.cover_msg_id || (group && group.cover_msg_id));
        const size = humanSize(vol.file_size) || (vol.file_size_mb ? `${vol.file_size_mb} MB` : null);
        const format = formatFromMime(vol.mime_type, vol.filename);
        const authors = clean(vol.canonical_authors || vol.author || "");
        const category = clean(vol.category || (group && group.category) || "");

        return {
            id: `vol-${id}`,
            title,
            description: [authors, category, size].filter(Boolean).join(" · ") || null,
            cover,
            series: groupTitleFallback(group) || category || null,
            format,
            size,
            link: `${ORIGIN}/api/download/${id}`,
            mirrors: [`${ORIGIN}/api/download/${id}`],
            hasMirrors: false,
            canRead: false,
            opensCatalog: false,
            metadata: {
                volumeId: id,
                messageId: vol.message_id,
                author: authors || null,
                category: category || null,
                downloads: vol.downloads,
                filename: vol.filename || null,
                mimeType: vol.mime_type || null
            }
        };
    }

    function groupTitleFallback(group) {
        if (!group) return null;
        if (group.volumes && group.volumes.length) {
            const first = group.volumes[0];
            const key = clean(first.group_key || "");
            if (key) return key.replace(/\s*-\s*/g, " — ");
            return clean(first.title || first.filename);
        }
        return null;
    }

    function groupCatalogEntry(group) {
        const coverMsgId = group.cover_msg_id;
        const vols = Array.isArray(group.volumes) ? group.volumes : [];
        const title = groupTitleFallback(group) || clean(group.category) || `Group ${coverMsgId}`;
        const category = clean(group.category || "");
        const cover = coverUrl(coverMsgId);

        // Single-volume groups: expose the download directly.
        if (vols.length === 1) {
            const entry = volumeEntry(vols[0], group);
            entry.id = `grp-${coverMsgId}`;
            entry.title = title;
            entry.series = category || entry.series;
            return entry;
        }

        // Multi-volume: open nested catalog at the group API page.
        const totalSize = vols.reduce((sum, v) => sum + (Number(v.file_size) || 0), 0);
        return {
            id: `grp-${coverMsgId}`,
            title,
            description: [
                category,
                `${vols.length} archivos`,
                humanSize(totalSize)
            ].filter(Boolean).join(" · ") || null,
            cover,
            series: category || null,
            link: `${ORIGIN}/api/group/${coverMsgId}`,
            opensCatalog: true,
            canRead: false,
            hasMirrors: false,
            mirrors: [],
            metadata: {
                coverMsgId,
                volumeCount: vols.length,
                category: category || null
            }
        };
    }

    function categoryCatalogEntry(cat) {
        const name = clean(cat.category || cat.name || "");
        if (!name) return null;
        return {
            id: `cat-${name}`,
            title: name,
            description: cat.count != null ? `${cat.count} títulos` : null,
            link: `${ORIGIN}/biblioteca?cat=${encodeURIComponent(name)}&page=1`,
            opensCatalog: true,
            canRead: false,
            cover: null,
            mirrors: [],
            hasMirrors: false
        };
    }

    function parseQueryFromLocation() {
        let params;
        try {
            params = new URL(location.href).searchParams;
        } catch (_) {
            params = new URLSearchParams();
        }
        return {
            category: params.get("cat") || params.get("category") || "",
            page: Math.max(1, Number(params.get("page")) || 1),
            query: params.get("q") || "",
            group: params.get("grupo") || params.get("group") || ""
        };
    }

    function isApiGroupUrl() {
        try {
            const path = new URL(location.href).pathname;
            return /^\/api\/group\/\d+\/?$/.test(path);
        } catch (_) {
            return false;
        }
    }

    function groupIdFromLocation() {
        try {
            const path = new URL(location.href).pathname;
            const m = path.match(/^\/api\/group\/(\d+)\/?$/);
            return m ? m[1] : null;
        } catch (_) {
            return null;
        }
    }

    async function fetchJSON(url) {
        const response = await fetch(url, { credentials: "include" });
        if (!response.ok) {
            throw new Error(`CompartiComics request failed: HTTP ${response.status} for ${url}`);
        }
        return response.json();
    }

    async function fetchCategories() {
        const data = await fetchJSON(`${ORIGIN}/api/categories`);
        if (!Array.isArray(data)) return [];
        return data
            .map(categoryCatalogEntry)
            .filter(Boolean)
            .sort((a, b) => a.title.localeCompare(b.title, "es", { sensitivity: "base" }));
    }

    async function fetchGroupsPage({ category = "", query = "", page = 1, pageSize = PAGE_SIZE } = {}) {
        const params = new URLSearchParams();
        params.set("page", String(page));
        params.set("page_size", String(pageSize));
        if (category) params.set("category", category);
        if (query) params.set("q", query);

        const data = await fetchJSON(`${ORIGIN}/api/groups?${params.toString()}`);
        const results = Array.isArray(data.results) ? data.results : [];
        const comics = results.map(groupCatalogEntry).filter(Boolean);
        return {
            comics,
            total: Number(data.total) || comics.length,
            page: Number(data.page) || page,
            pages: Number(data.pages) || 1
        };
    }

    async function fetchGroup(coverMsgId) {
        return fetchJSON(`${ORIGIN}/api/group/${coverMsgId}`);
    }

    function paginationCatalogs(baseName, { category, query, page, pages }) {
        const catalogs = [];
        if (pages > 1 && page < pages) {
            const params = new URLSearchParams();
            if (category) params.set("cat", category);
            if (query) params.set("q", query);
            params.set("page", String(page + 1));
            catalogs.push({
                name: `Página ${page + 1} de ${pages}`,
                url: `${ORIGIN}/biblioteca?${params.toString()}`
            });
        }
        if (page > 1) {
            const params = new URLSearchParams();
            if (category) params.set("cat", category);
            if (query) params.set("q", query);
            params.set("page", String(page - 1));
            catalogs.push({
                name: `← Página ${page - 1}`,
                url: `${ORIGIN}/biblioteca?${params.toString()}`
            });
        }
        // Jump links for deep catalogs (every 5 pages).
        for (let p = 1; p <= pages && p <= 20; p += 5) {
            if (p === page) continue;
            const params = new URLSearchParams();
            if (category) params.set("cat", category);
            if (query) params.set("q", query);
            params.set("page", String(p));
            catalogs.push({
                name: `Ir a página ${p}`,
                url: `${ORIGIN}/biblioteca?${params.toString()}`
            });
        }
        return catalogs;
    }

    async function parseRootCatalog() {
        const categories = await fetchCategories();
        // Also surface a "latest" page of groups for quick browsing.
        let latest = [];
        try {
            const page = await fetchGroupsPage({ page: 1, pageSize: 24 });
            latest = page.comics;
        } catch (_) {}

        return {
            name: "CompartiComics",
            comics: latest,
            catalogs: [
                { name: "Categorías", url: `${ORIGIN}/biblioteca?view=categories` },
                ...categories.slice(0, 80).map(c => ({
                    name: c.title + (c.description ? ` (${c.description})` : ""),
                    url: c.link
                }))
            ]
        };
    }

    async function parseCategoriesList() {
        const categories = await fetchCategories();
        return {
            name: "Categorías",
            comics: categories,
            catalogs: [{ name: "Inicio", url: `${ORIGIN}/biblioteca` }]
        };
    }

    async function parseGroupsCatalog(opts) {
        const { category, query, page } = opts;
        const data = await fetchGroupsPage({ category, query, page, pageSize: PAGE_SIZE });
        const label = query
            ? `Búsqueda: ${query}`
            : category
              ? category
              : "Biblioteca";
        const name =
            data.pages > 1
                ? `${label} — página ${data.page}/${data.pages}`
                : label;

        return {
            name,
            comics: data.comics,
            catalogs: paginationCatalogs(label, {
                category,
                query,
                page: data.page,
                pages: data.pages
            })
        };
    }

    async function parseGroupDetail(coverMsgId) {
        const group = await fetchGroup(coverMsgId);
        const vols = Array.isArray(group.volumes) ? group.volumes : [];
        const title = groupTitleFallback(group) || clean(group.category) || `Grupo ${coverMsgId}`;
        const comics = vols.map(v => volumeEntry(v, group));

        // Sort by title numerically when possible.
        comics.sort((a, b) =>
            a.title.localeCompare(b.title, "es", { numeric: true, sensitivity: "base" })
        );

        const catalogs = [];
        if (group.category) {
            catalogs.push({
                name: group.category,
                url: `${ORIGIN}/biblioteca?cat=${encodeURIComponent(group.category)}&page=1`
            });
        }
        catalogs.push({ name: "Inicio", url: `${ORIGIN}/biblioteca` });

        return {
            name: title,
            comics,
            catalogs
        };
    }

    /**
     * When the WebView is on a biblioteca HTML page, prefer the live DOM for the
     * current grid so covers/titles match what the user sees. Fall back to API.
     */
    function parseDomGrid() {
        const cards = [];
        const seen = new Set();

        for (const btn of document.querySelectorAll(".btn-download[data-id], .vol-btn[data-id]")) {
            const id = btn.getAttribute("data-id");
            if (!id || seen.has(id)) continue;
            seen.add(id);

            const title =
                clean(btn.getAttribute("data-title")) ||
                clean(btn.closest("[data-title]")?.getAttribute("data-title")) ||
                `Archivo ${id}`;

            const card = btn.closest(".card, [class*='card'], article, li") || btn.parentElement;
            let cover = null;
            if (card) {
                const img = card.querySelector("img[src], img[data-src]");
                if (img) {
                    cover = absolute(img.getAttribute("src") || img.getAttribute("data-src"));
                }
            }

            cards.push({
                id: `vol-${id}`,
                title,
                cover,
                link: `${ORIGIN}/api/download/${id}`,
                mirrors: [`${ORIGIN}/api/download/${id}`],
                hasMirrors: false,
                canRead: false,
                opensCatalog: false,
                format: "CBR"
            });
        }

        return cards;
    }

    globalThis.ComicViewerSource = {
        manifest: {
            id: "comparticomics",
            name: "CompartiComics",
            version: "1.0.0",
            homepage: ORIGIN,
            description:
                "Biblioteca digital de cómics en español (comparticomics.lat). Explora categorías y descarga CBR/CBZ/RAR.",
            tags: ["comic", "spanish", "español", "download", "cbr", "argentina"],
            capabilities: ["browse", "search"]
        },

        browseURL: `${ORIGIN}/biblioteca`,

        searchURL(query) {
            return `${ORIGIN}/biblioteca?q=${encodeURIComponent(query || "")}&page=1`;
        },

        async parseCatalog() {
            // Group detail API page (multi-volume drill-down).
            if (isApiGroupUrl()) {
                const gid = groupIdFromLocation();
                if (gid) return parseGroupDetail(gid);
            }

            const { category, page, query, group } = parseQueryFromLocation();

            // Explicit group from query param (modal deep-link style).
            if (group) {
                return parseGroupDetail(group);
            }

            // Categories index.
            try {
                const path = new URL(location.href).pathname;
                const view = new URL(location.href).searchParams.get("view");
                if (view === "categories") {
                    return parseCategoriesList();
                }
                // Root biblioteca with no filters → categories + latest.
                if (
                    (path === "/biblioteca" || path === "/biblioteca/") &&
                    !category &&
                    !query
                ) {
                    return parseRootCatalog();
                }
            } catch (_) {}

            // Category or search listing via API (paginated).
            if (category || query || page > 1) {
                try {
                    return await parseGroupsCatalog({ category, query, page });
                } catch (err) {
                    // Fall through to DOM scrape.
                    console.warn("CompartiComics API catalog failed, trying DOM:", err);
                }
            }

            // DOM fallback on the live grid.
            const domComics = parseDomGrid();
            if (domComics.length) {
                return {
                    name: category || query || "CompartiComics",
                    comics: domComics,
                    catalogs: []
                };
            }

            // Last resort: root via API.
            return parseRootCatalog();
        }

        // No parsePages(): this source serves archive downloads, not page images.
        // canRead is left false so Comic Viewer treats entries as downloadable links.
    };
})();
