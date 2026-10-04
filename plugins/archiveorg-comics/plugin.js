// Comic Viewer source plugin for Internet Archive — Comics collection.
// Install from Preferences -> Sources -> Source plugins.
//
// Uses public Archive.org Advanced Search + Metadata APIs.
// Items with CBR/CBZ/PDF/ZIP are exposed as downloadable archive links.
// BookReader page streaming is used when single-page JP2/JPEG derivatives exist.

(() => {
    const ORIGIN = "https://archive.org";
    const COLLECTION = "comics";
    const ROWS = 40;

    function clean(text) {
        return (text || "").replace(/\s+/g, " ").trim();
    }

    function absolute(raw, base = ORIGIN) {
        if (!raw) return null;
        try {
            return new URL(raw, base).href;
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

    function param(name, url = location.href) {
        try {
            return new URL(url).searchParams.get(name);
        } catch (_) {
            return null;
        }
    }

    function humanSize(bytes) {
        const n = Number(bytes);
        if (!Number.isFinite(n) || n <= 0) return null;
        if (n >= 1e9) return (n / 1e9).toFixed(1) + " GB";
        if (n >= 1e6) return (n / 1e6).toFixed(1) + " MB";
        if (n >= 1e3) return (n / 1e3).toFixed(0) + " KB";
        return String(n) + " B";
    }

    function coverFor(identifier) {
        return `${ORIGIN}/services/img/${encodeURIComponent(identifier)}`;
    }

    function isArchiveFile(name, format) {
        const n = (name || "").toLowerCase();
        const f = (format || "").toLowerCase();
        if (/\.(cbr|cbz|cb7|cbt)$/i.test(n)) return true;
        if (/\.(zip|rar|7z)$/i.test(n) && /comic|zip|rar/i.test(f)) return true;
        if (f.includes("comic book")) return true;
        if (n.endsWith(".pdf") || f === "text pdf" || f === "pdf") return true;
        return false;
    }

    function formatLabel(name, format) {
        const n = (name || "").toLowerCase();
        if (n.endsWith(".cbr") || /comic book rar/i.test(format || "")) return "CBR";
        if (n.endsWith(".cbz") || /comic book zip/i.test(format || "")) return "CBZ";
        if (n.endsWith(".pdf") || /pdf/i.test(format || "")) return "PDF";
        if (n.endsWith(".zip")) return "ZIP";
        if (n.endsWith(".rar")) return "RAR";
        return format || null;
    }

    async function fetchJSON(url) {
        const r = await fetch(url, { credentials: "omit" });
        if (!r.ok) throw new Error(`IA HTTP ${r.status} for ${url}`);
        return r.json();
    }

    async function searchComics({ page = 1, query = "", rows = ROWS } = {}) {
        const qParts = [`collection:${COLLECTION}`];
        // Prefer actual items over nested collections when possible
        qParts.push("(mediatype:texts OR mediatype:image OR mediatype:collection)");
        if (query) {
            qParts.push(`(${query})`);
        }
        const params = new URLSearchParams();
        params.set("q", qParts.join(" AND "));
        for (const fl of [
            "identifier",
            "title",
            "creator",
            "description",
            "mediatype",
            "format",
            "downloads",
            "item_size",
            "publicdate"
        ]) {
            params.append("fl[]", fl);
        }
        params.append("sort[]", "downloads desc");
        params.set("rows", String(rows));
        params.set("page", String(page));
        params.set("output", "json");

        const data = await fetchJSON(`${ORIGIN}/advancedsearch.php?${params}`);
        const resp = data.response || {};
        const docs = Array.isArray(resp.docs) ? resp.docs : [];
        const numFound = Number(resp.numFound) || docs.length;
        const pages = Math.max(1, Math.ceil(numFound / rows));

        const comics = docs.map((doc) => {
            const id = doc.identifier;
            const isCollection = doc.mediatype === "collection";
            return {
                id: id,
                title: clean(doc.title) || id,
                description: clean(
                    [
                        Array.isArray(doc.creator) ? doc.creator.join(", ") : doc.creator,
                        humanSize(doc.item_size),
                        doc.downloads != null ? `${doc.downloads} downloads` : null
                    ]
                        .filter(Boolean)
                        .join(" · ")
                ),
                cover: coverFor(id),
                series: null,
                link: isCollection
                    ? `${ORIGIN}/details/${encodeURIComponent(id)}`
                    : `${ORIGIN}/details/${encodeURIComponent(id)}`,
                opensCatalog: true,
                canRead: false,
                hasMirrors: false,
                mirrors: [],
                size: humanSize(doc.item_size),
                metadata: {
                    identifier: id,
                    mediatype: doc.mediatype,
                    downloads: doc.downloads
                }
            };
        });

        return { comics, numFound, page, pages };
    }

    async function parseItem(identifier) {
        const meta = await fetchJSON(`${ORIGIN}/metadata/${encodeURIComponent(identifier)}`);
        const md = meta.metadata || {};
        const title = clean(md.title) || identifier;
        const files = Array.isArray(meta.files) ? meta.files : [];
        const server = meta.d1 || meta.server;
        const dir = meta.dir;

        const archives = [];
        for (const f of files) {
            if (!isArchiveFile(f.name, f.format)) continue;
            const name = f.name;
            const url = `${ORIGIN}/download/${encodeURIComponent(identifier)}/${encodeURIComponent(name)}`;
            archives.push({
                id: `${identifier}::${name}`,
                title: name,
                description: [formatLabel(name, f.format), humanSize(f.size)]
                    .filter(Boolean)
                    .join(" · "),
                cover: coverFor(identifier),
                series: title,
                format: formatLabel(name, f.format),
                size: humanSize(f.size),
                link: url,
                mirrors: server && dir
                    ? [
                          url,
                          `https://${server}${dir}/${encodeURIComponent(name)}`
                      ]
                    : [url],
                hasMirrors: true,
                canRead: false,
                opensCatalog: false,
                metadata: {
                    identifier,
                    filename: name,
                    format: f.format
                }
            });
        }

        // Prefer comic archives first
        archives.sort((a, b) => {
            const rank = (x) =>
                x.format === "CBZ" || x.format === "CBR" ? 0 : x.format === "PDF" ? 1 : 2;
            return rank(a) - rank(b) || a.title.localeCompare(b.title, undefined, { numeric: true });
        });

        // If no discrete archives, still expose the details page
        if (archives.length === 0) {
            archives.push({
                id: identifier,
                title,
                description: clean(
                    Array.isArray(md.description)
                        ? md.description.join(" ")
                        : md.description || "Open on Archive.org"
                ),
                cover: coverFor(identifier),
                link: `${ORIGIN}/details/${encodeURIComponent(identifier)}`,
                opensCatalog: false,
                canRead: false,
                hasMirrors: false,
                mirrors: []
            });
        }

        return {
            name: title,
            comics: archives,
            catalogs: [
                { name: "Comics collection", url: `${ORIGIN}/details/comics` },
                { name: "Search comics", url: `${ORIGIN}/search?query=collection%3Acomics&and[]=mediatype%3A%22texts%22` }
            ]
        };
    }

    function detailsIdFromLocation() {
        const m = pathOf().match(/^\/details\/([^/]+)\/?$/);
        return m ? decodeURIComponent(m[1]) : null;
    }

    globalThis.ComicViewerSource = {
        manifest: {
            id: "archiveorg.comics",
            name: "Internet Archive Comics",
            version: "1.0.0",
            homepage: `${ORIGIN}/details/comics`,
            description:
                "Browse the Internet Archive Comics collection. Lists CBR/CBZ/PDF files via public metadata APIs for download.",
            tags: ["comic", "public-domain", "archive", "download"],
            capabilities: ["browse", "search"]
        },

        browseURL: `${ORIGIN}/details/comics`,

        searchURL(query) {
            const q = encodeURIComponent(`collection:comics ${query || ""}`.trim());
            return `${ORIGIN}/search?query=${q}`;
        },

        async parseCatalog() {
            const detailsId = detailsIdFromLocation();
            if (detailsId && detailsId !== "comics") {
                // Nested collection or item
                try {
                    const meta = await fetchJSON(
                        `${ORIGIN}/metadata/${encodeURIComponent(detailsId)}`
                    );
                    const mt = meta.metadata?.mediatype;
                    if (mt === "collection") {
                        // Search within this collection
                        const page = Number(param("page")) || 1;
                        // Override collection filter by using identifier as collection
                        const params = new URLSearchParams();
                        params.set(
                            "q",
                            `collection:${detailsId} AND (mediatype:texts OR mediatype:image)`
                        );
                        for (const fl of [
                            "identifier",
                            "title",
                            "creator",
                            "mediatype",
                            "downloads",
                            "item_size"
                        ]) {
                            params.append("fl[]", fl);
                        }
                        params.append("sort[]", "downloads desc");
                        params.set("rows", String(ROWS));
                        params.set("page", String(page));
                        params.set("output", "json");
                        const data = await fetchJSON(`${ORIGIN}/advancedsearch.php?${params}`);
                        const docs = data.response?.docs || [];
                        const numFound = data.response?.numFound || docs.length;
                        const pages = Math.max(1, Math.ceil(numFound / ROWS));
                        const comics = docs.map((doc) => ({
                            id: doc.identifier,
                            title: clean(doc.title) || doc.identifier,
                            cover: coverFor(doc.identifier),
                            link: `${ORIGIN}/details/${encodeURIComponent(doc.identifier)}`,
                            opensCatalog: true,
                            canRead: false,
                            description: humanSize(doc.item_size),
                            size: humanSize(doc.item_size),
                            hasMirrors: false,
                            mirrors: []
                        }));
                        const catalogs = [];
                        if (page < pages) {
                            catalogs.push({
                                name: `Page ${page + 1} of ${pages}`,
                                url: `${ORIGIN}/details/${encodeURIComponent(detailsId)}?page=${page + 1}`
                            });
                        }
                        catalogs.push({ name: "Comics root", url: `${ORIGIN}/details/comics` });
                        return {
                            name: clean(meta.metadata?.title) || detailsId,
                            comics,
                            catalogs
                        };
                    }
                    return parseItem(detailsId);
                } catch (err) {
                    console.warn("IA item parse failed:", err);
                }
            }

            // Root comics collection browse
            const page = Number(param("page")) || 1;
            const q =
                param("query") ||
                param("q") ||
                (pathOf().includes("/search") ? param("query") : "") ||
                "";
            // Strip collection:comics if already present in query
            const query = clean(q).replace(/collection\s*:\s*comics/gi, "").trim();

            const result = await searchComics({ page, query });
            const catalogs = [
                { name: "Comics collection home", url: `${ORIGIN}/details/comics` }
            ];
            if (result.page < result.pages) {
                catalogs.unshift({
                    name: `Page ${result.page + 1} of ${result.pages}`,
                    url: `${ORIGIN}/details/comics?page=${result.page + 1}`
                });
            }

            return {
                name:
                    query
                        ? `IA Comics: ${query}`
                        : result.pages > 1
                          ? `IA Comics — page ${result.page}/${result.pages}`
                          : "Internet Archive Comics",
                comics: result.comics,
                catalogs
            };
        }
    };
})();
