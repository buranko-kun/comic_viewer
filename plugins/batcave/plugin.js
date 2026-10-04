// Comic Viewer source plugin for BatCave (batcave.biz).
// Install from Preferences -> Sources -> Source plugins.
//
// The site is behind Cloudflare. Open this plugin's homepage from
// Preferences -> Sources and complete the challenge once so the plugin
// WebView shares the cleared session cookies.
//
// Catalog / chapters are scraped from the live DOM + window.__DATA__.
// Page images come from the site's reader API (same as community readers).

(() => {
    const ORIGIN = "https://batcave.biz";

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

    function isCloudflareChallenge() {
        const t = clean(document.title || "");
        const body = clean(document.body?.innerText || "").slice(0, 400);
        return (
            /just a moment|attention required|verify you are human|performing security verification|sorry, you have been blocked/i.test(
                t + " " + body
            )
        );
    }

    function challengeCatalog() {
        return {
            name: "BatCave",
            comics: [],
            catalogs: [
                {
                    name: "Open batcave.biz (solve Cloudflare)",
                    url: ORIGIN + "/"
                },
                {
                    name: "Comics list",
                    url: ORIGIN + "/comix/"
                }
            ]
        };
    }

    function isSeriesPage() {
        // /1234-title.html series pages
        return /^\/\d+-[^/]+\.html$/i.test(pathOf());
    }

    function isReaderPage() {
        return /^\/reader\//i.test(pathOf());
    }

    function isListPage() {
        const p = pathOf();
        return (
            p === "/" ||
            p === "/comix/" ||
            p === "/comix" ||
            /^\/comix\/page\/\d+/i.test(p) ||
            /^\/page\/\d+/i.test(p) ||
            /^\/search\//i.test(p) ||
            /^\/ComicList\//i.test(p)
        );
    }

    function seriesIdFromPath(pathname = pathOf()) {
        const m = pathname.match(/^\/(\d+)-/i);
        return m ? m[1] : null;
    }

    function pageTitle() {
        const h1 = document.querySelector("header.page__header h1, h1");
        const t = clean(h1?.textContent || document.title || "");
        return t
            .replace(/\s*[|–—-]\s*BatCave.*$/i, "")
            .replace(/\s*Comics Online Free.*$/i, "")
            .trim() || "BatCave";
    }

    function parseListCards() {
        const comics = [];
        const seen = new Set();

        // Popular / filtered list
        for (const el of document.querySelectorAll("#dle-content > .readed, .readed")) {
            const a = el.querySelector(".readed__title > a, a.readed__title, .readed__title a");
            if (!a) continue;
            const href = absolute(a.getAttribute("href"));
            if (!href || seen.has(href)) continue;
            seen.add(href);
            const img =
                el.querySelector(".readed__img img[data-src], .readed__img img[src], img[data-src], img[src]");
            comics.push({
                id: href,
                title: clean(a.ownText || a.textContent) || "Untitled",
                cover: absolute(
                    img?.getAttribute("data-src") || img?.getAttribute("src")
                ),
                link: href,
                opensCatalog: true,
                canRead: false,
                hasMirrors: false,
                mirrors: []
            });
        }

        // Latest grid on home
        for (const el of document.querySelectorAll("#content-load > .latest.grid-item, .latest.grid-item")) {
            const a = el.querySelector(".latest__title > a, a.latest__title");
            if (!a) continue;
            const href = absolute(a.getAttribute("href"));
            if (!href || seen.has(href)) continue;
            const title = clean(a.ownText || a.textContent);
            if (!title) continue;
            seen.add(href);
            const img = el.querySelector(".latest__img img[src], .latest__img img[data-src], img");
            comics.push({
                id: href,
                title,
                cover: absolute(img?.getAttribute("src") || img?.getAttribute("data-src")),
                link: href,
                opensCatalog: true,
                canRead: false,
                hasMirrors: false,
                mirrors: []
            });
        }

        // Generic poster cards fallback
        if (comics.length === 0) {
            for (const a of document.querySelectorAll('a[href*=".html"]')) {
                const href = absolute(a.getAttribute("href"));
                if (!href || !/\/\d+-[^/]+\.html$/i.test(href) || seen.has(href)) continue;
                const title = clean(a.textContent);
                if (!title || title.length < 2) continue;
                seen.add(href);
                const img =
                    a.querySelector("img") ||
                    a.parentElement?.querySelector("img");
                comics.push({
                    id: href,
                    title,
                    cover: absolute(
                        img?.getAttribute("data-src") || img?.getAttribute("src")
                    ),
                    link: href,
                    opensCatalog: true,
                    canRead: false,
                    hasMirrors: false,
                    mirrors: []
                });
                if (comics.length >= 80) break;
            }
        }

        return comics;
    }

    function nextPageCatalogs() {
        const catalogs = [];
        const next =
            document.querySelector("div.pagination__pages a:last-of-type") ||
            document.querySelector("li.pagination a[href]:last-of-type") ||
            document.querySelector(".pagination a.next, a[rel='next']");
        if (next?.getAttribute("href")) {
            catalogs.push({
                name: "Next page",
                url: absolute(next.getAttribute("href"))
            });
        }
        catalogs.push(
            { name: "Comics list", url: ORIGIN + "/comix/" },
            { name: "Home / latest", url: ORIGIN + "/" }
        );
        return catalogs;
    }

    function extractDataScript() {
        for (const script of document.querySelectorAll("script")) {
            const text = script.textContent || "";
            if (!text.includes("window.__DATA__")) continue;
            const json = text
                .split("window.__DATA__ =")[1]
                ?.split(";")[0]
                ?.trim();
            if (!json) continue;
            try {
                return JSON.parse(json);
            } catch (_) {
                // try last occurrence
                try {
                    const start = text.lastIndexOf("window.__DATA__ =");
                    const chunk = text
                        .slice(start)
                        .split("=")[1]
                        .split(";")[0]
                        .trim();
                    return JSON.parse(chunk);
                } catch (__) {
                    return null;
                }
            }
        }
        return null;
    }

    function parseSeriesCatalog() {
        const data = extractDataScript();
        const title = pageTitle();
        const cover = absolute(
            document.querySelector("div.page__poster img")?.getAttribute("src")
        );
        const seriesId = data?.news_id || seriesIdFromPath();
        const xhash = data?.xhash || "";
        const chapters = Array.isArray(data?.chapters) ? data.chapters : [];

        const comics = chapters.map((chap) => {
            const chapId = chap.id;
            const link = `${ORIGIN}/reader/${seriesId}/${chapId}${xhash}`;
            return {
                id: `reader-${seriesId}-${chapId}`,
                title: clean(chap.title) || `Chapter ${chap.posi ?? chapId}`,
                series: title,
                cover,
                link,
                canRead: true,
                opensCatalog: false,
                hasMirrors: false,
                mirrors: [],
                metadata: {
                    newsId: String(seriesId),
                    chapterId: String(chapId),
                    number: chap.posi,
                    date: chap.date || null
                }
            };
        });

        // Prefer reading order: lowest number first when posi is present
        comics.sort((a, b) => {
            const an = Number(a.metadata?.number);
            const bn = Number(b.metadata?.number);
            if (Number.isFinite(an) && Number.isFinite(bn)) return an - bn;
            return a.title.localeCompare(b.title, undefined, {
                numeric: true,
                sensitivity: "base"
            });
        });

        // If __DATA__ missing, fall back to chapter anchors in the list
        if (comics.length === 0) {
            const seen = new Set();
            for (const a of document.querySelectorAll('a[href*="/reader/"]')) {
                const href = absolute(a.getAttribute("href"));
                if (!href || seen.has(href)) continue;
                seen.add(href);
                comics.push({
                    id: href,
                    title: clean(a.textContent) || "Chapter",
                    series: title,
                    cover,
                    link: href,
                    canRead: true,
                    opensCatalog: false,
                    hasMirrors: false,
                    mirrors: []
                });
            }
        }

        return {
            name: title,
            comics,
            catalogs: [
                { name: "Comics list", url: ORIGIN + "/comix/" },
                { name: "Home", url: ORIGIN + "/" }
            ]
        };
    }

    function parseListCatalog() {
        const comics = parseListCards();
        const name =
            pathOf().startsWith("/search/")
                ? "Search"
                : pathOf().includes("comix")
                  ? "Comics list"
                  : pageTitle() || "BatCave";

        return {
            name,
            comics,
            catalogs: nextPageCatalogs()
        };
    }

    async function fetchChapterImages(newsId, chapterId) {
        const response = await fetch(
            `${ORIGIN}/engine/ajax/controller.php?mod=api&action=reader/getChapterData`,
            {
                method: "POST",
                credentials: "include",
                headers: {
                    "Content-Type": "application/json",
                    Accept: "application/json, text/plain, */*",
                    "X-Requested-With": "XMLHttpRequest",
                    Referer: location.href
                },
                body: JSON.stringify({
                    news_id: String(newsId),
                    chapter_id: String(chapterId)
                })
            }
        );
        if (!response.ok) {
            throw new Error(`BatCave reader API HTTP ${response.status}`);
        }
        const json = await response.json();
        const images = json?.data?.images || json?.images || [];
        return images
            .map((img) => {
                const s = String(img || "").trim();
                if (!s) return null;
                return s.startsWith("http") ? s : absolute(s, ORIGIN + "/");
            })
            .filter(Boolean);
    }

    function readerIdsFromLocation() {
        // /reader/{newsId}/{chapterId}{optionalHash}
        const parts = pathOf().split("/").filter(Boolean);
        // ["reader", newsId, chapterPart]
        if (parts[0] !== "reader" || !parts[1] || !parts[2]) return null;
        const newsId = parts[1];
        const chapterMatch = String(parts[2]).match(/^\d+/);
        const chapterId = chapterMatch ? chapterMatch[0] : parts[2];
        return { newsId, chapterId };
    }

    function pageImagesFromDom() {
        const seen = new Set();
        const pages = [];
        for (const img of document.querySelectorAll(
            ".reader img, #reader img, .page-image img, .comic-page img, img[data-src], img[src]"
        )) {
            const raw =
                img.getAttribute("data-src") ||
                img.getAttribute("data-lazy-src") ||
                img.getAttribute("src");
            const href = absolute(raw);
            if (!href || seen.has(href)) continue;
            if (/logo|icon|avatar|emoji|spinner|ads?/i.test(href)) continue;
            if (!/\.(jpe?g|png|webp|gif)(\?|$)/i.test(href) && !/\/uploads\//i.test(href)) {
                continue;
            }
            seen.add(href);
            pages.push(href);
        }
        return pages;
    }

    globalThis.ComicViewerSource = {
        manifest: {
            id: "batcave",
            name: "BatCave",
            version: "1.0.0",
            homepage: ORIGIN,
            description:
                "Read comics online from batcave.biz (DC, Marvel, Image, and more). Requires clearing Cloudflare once in the source browser.",
            tags: ["comic", "english", "marvel", "dc"],
            capabilities: ["browse", "search", "read"]
        },

        browseURL: ORIGIN + "/comix/",

        searchURL(query) {
            const q = encodeURIComponent(query || "").replace(/%20/g, "+");
            return `${ORIGIN}/search/${q}/`;
        },

        async parseCatalog() {
            if (isCloudflareChallenge()) {
                return challengeCatalog();
            }

            if (isSeriesPage()) {
                return parseSeriesCatalog();
            }

            if (isReaderPage()) {
                // Treat reader URL as a single readable entry
                const ids = readerIdsFromLocation();
                return {
                    name: pageTitle(),
                    comics: [
                        {
                            id: location.pathname,
                            title: pageTitle(),
                            link: location.href,
                            canRead: true,
                            opensCatalog: false,
                            hasMirrors: false,
                            mirrors: [],
                            metadata: ids || {}
                        }
                    ],
                    catalogs: [{ name: "Comics list", url: ORIGIN + "/comix/" }]
                };
            }

            return parseListCatalog();
        },

        async parsePages() {
            if (isCloudflareChallenge()) {
                return { pages: [] };
            }

            // Prefer API when we know news/chapter ids
            let newsId = null;
            let chapterId = null;

            const fromPath = readerIdsFromLocation();
            if (fromPath) {
                newsId = fromPath.newsId;
                chapterId = fromPath.chapterId;
            }

            // Catalog metadata may have been embedded by the host when opening the link
            // Fallback: parse from any data attributes on the page
            if (!newsId || !chapterId) {
                const data = extractDataScript();
                if (data?.news_id && data?.chapters?.length === 1) {
                    newsId = String(data.news_id);
                    chapterId = String(data.chapters[0].id);
                }
            }

            if (newsId && chapterId) {
                try {
                    const pages = await fetchChapterImages(newsId, chapterId);
                    if (pages.length) return { pages };
                } catch (err) {
                    console.warn("BatCave API pages failed, trying DOM:", err);
                }
            }

            const domPages = pageImagesFromDom();
            return { pages: domPages };
        }
    };
})();
