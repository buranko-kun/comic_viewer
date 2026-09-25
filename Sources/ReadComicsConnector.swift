import Foundation
import SwiftUI
import CoreGraphics

/// One chapter/issue of a series on ReadComicsOnline. The identifier is the URL path **segment**,
/// which is usually a number ("34") but can be non-numeric ("TPB", "Annual-1", "Special") for
/// collected editions / one-shots — so it's a string, not an Int.
struct ComicChapter: Identifiable, Hashable {
    let segment: String   // path segment used in the chapter URL *and* the CDN folder ("34" / "TPB")
    let url: URL          // the chapter page (used later to fetch the exact page list)
    var id: String { segment }
    /// Numeric value when the segment is a plain number (for ordering / the common CDN path); nil
    /// for lettered segments like "TPB".
    var number: Int? { Int(segment) }
    /// What to show on the card: "#34" for numeric, the segment itself ("TPB") otherwise.
    var label: String { number.map { "#\($0)" } ?? segment }
}

/// A series scraped from a ReadComicsOnline comic page.
struct ComicSeries {
    let title: String
    let coverURL: URL?
    let slug: String
    let chapters: [ComicChapter]   // ascending by number
}

/// One card in the site's `/comic-list` directory — enough to show it in a browse grid and to
/// fetch its chapters on demand (via its `/comic/<slug>` page). Cheap to scrape in bulk.
struct CatalogEntry: Identifiable, Hashable {
    let slug: String
    let title: String
    let coverURL: URL?
    var id: String { slug }
    var pageURL: URL? { URL(string: "\(ReadComicsParser.origin)/comic/\(slug)") }
}

/// The whole ReadComicsOnline directory, mirrored locally as a lightweight index of series
/// (`slug`, `title`, `cover`) — no images stored. Persisted to `readcomics-catalog.json` in the
/// app's support dir so the browse grid loads instantly after the one-time scrape. Each series'
/// chapters/pages are resolved lazily on open (the CDN images are open; only the HTML needs the
/// Cloudflare gate). Codable directly from `CatalogEntry` via a compact on-disk shape.
@MainActor @Observable
final class ReadComicsCatalogStore {
    static let shared = ReadComicsCatalogStore()

    private(set) var entries: [CatalogEntry] = []
    /// When the catalog was last fully mirrored (nil = unknown / pre-freshness file).
    private(set) var mirroredAt: Date?
    /// Summary of the last re-mirror's diff, e.g. "12 new · 3 removed" (nil until a re-mirror runs).
    var lastChangeSummary: String?
    /// Scrape progress: (pages done, total pages, series so far). nil when idle.
    var progress: (done: Int, total: Int, series: Int)?
    var lastError: String?

    /// Consider the catalog stale after two weeks — new series accrue on the site over time.
    private static let staleAfter: TimeInterval = 14 * 24 * 3600

    private struct Row: Codable { let slug: String; let title: String; let cover: String? }
    /// On-disk shape: a wrapper carrying the mirror date. Falls back to the legacy bare `[Row]`.
    private struct Doc: Codable { var mirroredAt: Date?; var rows: [Row] }

    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ComicViewer/readcomics-catalog.json")
    }

    init() { load() }

    var isMirrored: Bool { !entries.isEmpty }

    /// True when the mirror is old enough to be worth refreshing (or its date is unknown).
    var isStale: Bool {
        guard isMirrored else { return false }
        guard let mirroredAt else { return true }
        return Date().timeIntervalSince(mirroredAt) > Self.staleAfter
    }

    /// Human-readable "updated 3 days ago" (nil if never/unknown).
    var updatedText: String? {
        guard let mirroredAt else { return nil }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return "updated " + f.localizedString(for: mirroredAt, relativeTo: Date())
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let rows: [Row]
        if let doc = try? JSONDecoder().decode(Doc.self, from: data) {
            rows = doc.rows; mirroredAt = doc.mirroredAt
        } else if let legacy = try? JSONDecoder().decode([Row].self, from: data) {
            rows = legacy; mirroredAt = nil          // old file: date unknown → shows as stale
        } else { return }
        entries = rows.map { CatalogEntry(slug: $0.slug,
                                          title: ReadComicsParser.decodeEntities($0.title),
                                          coverURL: $0.cover.flatMap { URL(string: $0) }) }
    }

    private func save() {
        let rows = entries.map { Row(slug: $0.slug, title: $0.title,
                                     cover: $0.coverURL?.absoluteString) }
        if let data = try? JSONEncoder().encode(Doc(mirroredAt: mirroredAt, rows: rows)) {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Walk every `/comic-list?page=N` through the cleared gate, accumulating all series. Reports
    /// progress as it goes and persists at the end. Deduped by slug, sorted by title. Diffs against
    /// the previous set so a re-mirror reports what changed. Cancellable; partial results are saved.
    func mirror(using session: CloudflareSession) async {
        lastError = nil; lastChangeSummary = nil
        let previousSlugs = Set(entries.map(\.slug))
        var bySlug: [String: CatalogEntry] = [:]
        // Page 1 also tells us the total page count.
        let first = await session.fetchCatalogPage(1)
        guard first.pageCount > 0 else {
            lastError = "Couldn't reach the catalog — solve the Cloudflare check first."
            progress = nil
            return
        }
        let total = first.pageCount
        first.entries.forEach { bySlug[$0.slug] = $0 }
        progress = (1, total, bySlug.count)

        for page in 2...total {
            if Task.isCancelled { break }
            let (pageEntries, _) = await session.fetchCatalogPage(page)
            pageEntries.forEach { bySlug[$0.slug] = $0 }
            progress = (page, total, bySlug.count)
            // Persist periodically so a long scrape survives interruption.
            if page % 20 == 0 {
                entries = bySlug.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                save()
            }
        }
        entries = bySlug.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        // Only stamp the date + diff on a complete walk (a cancelled one is partial).
        if !Task.isCancelled {
            mirroredAt = Date()
            if !previousSlugs.isEmpty {
                let now = Set(bySlug.keys)
                let added = now.subtracting(previousSlugs).count
                let removed = previousSlugs.subtracting(now).count
                lastChangeSummary = added == 0 && removed == 0
                    ? "No new series"
                    : [added > 0 ? "\(added) new" : nil, removed > 0 ? "\(removed) removed" : nil]
                        .compactMap { $0 }.joined(separator: " · ")
            }
        }
        save()
        progress = nil
    }
}

/// Remembers the *real* first-page URL for issues whose guessed `chapters/<n>/01.jpg` cover was
/// wrong (some issues were uploaded with a different filename). Once resolved through the gate, the
/// mapping is persisted so the cover loads directly from cache forever after — no re-guessing, no
/// re-fetch on every scroll. Keyed by `slug#chapter`. Persisted to `readcomics-issue-covers.json`.
@MainActor @Observable
final class ReadComicsIssueCovers {
    static let shared = ReadComicsIssueCovers()
    private var map: [String: String] = [:]
    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ComicViewer/readcomics-issue-covers.json")
    }
    init() {
        if let data = try? Data(contentsOf: fileURL),
           let m = try? JSONDecoder().decode([String: String].self, from: data) { map = m }
    }
    private func key(_ slug: String, _ chapter: String) -> String { "\(slug)#\(chapter)" }

    func realCover(slug: String, chapter: String) -> URL? {
        map[key(slug, chapter)].flatMap { URL(string: $0) }
    }
    func remember(slug: String, chapter: String, url: URL) {
        map[key(slug, chapter)] = url.absoluteString
        if let data = try? JSONEncoder().encode(map) {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Remembers the ReadComicsOnline issues you've opened, with the data needed to (a) show them on
/// the Home "Continue Reading" shelf and (b) reopen them **without** a Cloudflare fetch (the page
/// URLs are stored inline). Progress comes from each issue's saved `ComicState` (keyed by its URL),
/// so an issue only surfaces once you've actually read a few pages — matching local comics.
/// Persisted to `readcomics-history.json`.
@MainActor @Observable
final class ReadComicsHistory {
    static let shared = ReadComicsHistory()

    struct ReadIssue: Codable {
        let key: String        // the issue's URL string (Comic.url) — its ComicState key
        let series: String
        var label: String?     // display, e.g. "#34" or "TPB"
        var number: Int?       // legacy numeric field (older history files); superseded by `label`
        let cover: String?
        let pages: [String]
        /// What to show after the series title. Prefers `label`; falls back to the legacy number.
        var display: String { label ?? number.map { "#\($0)" } ?? "" }
    }

    private(set) var issues: [ReadIssue] = []
    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ComicViewer/readcomics-history.json")
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let rows = try? JSONDecoder().decode([ReadIssue].self, from: data) else { return }
        issues = rows
    }
    private func save() {
        if let data = try? JSONEncoder().encode(issues) {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Record (or refresh) an opened issue, most-recent kept at the front, capped at 60.
    func record(url: URL, series: String, label: String, cover: URL?, pages: [URL]) {
        let iss = ReadIssue(key: url.absoluteString, series: series, label: label, number: nil,
                            cover: cover?.absoluteString, pages: pages.map(\.absoluteString))
        issues.removeAll { $0.key == iss.key }
        issues.insert(iss, at: 0)
        if issues.count > 60 { issues.removeLast(issues.count - 60) }
        save()
    }

    /// In-progress issues rebuilt as `Comic`s for the Home shelf: read a few pages, not finished.
    /// Reuses each issue's saved `ComicState` for the live resume position.
    func continueComics() -> [Comic] {
        issues.compactMap { iss -> Comic? in
            guard let url = URL(string: iss.key),
                  let st = CentralStore.loadState(forKey: CentralStore.key(for: url)),
                  let count = st.pageCount, count > 0, let idx = st.lastIndex else { return nil }
            let page = idx + 1
            guard page >= 3, page < count else { return nil }
            let pages = iss.pages.compactMap { URL(string: $0) }
            let cover = iss.cover.flatMap { URL(string: $0) } ?? pages.first
            return Comic(url: url, series: iss.series, isArchive: false, coverURL: cover,
                         pageCount: count, progress: ComicProgress(page: page, count: count),
                         chapterCount: 0, metaTitle: "\(iss.series) \(iss.display)",
                         tooltip: nil, remotePages: pages)
        }
    }
}

/// Parses ReadComicsOnline (Manga Reader CMS, Tailwind redesign) HTML into structured data.
/// Built and verified against a real post-Cloudflare page capture. HTML fetching happens through the
/// cleared `CloudflareSession` WebView; this type is pure parsing (no network, easy to test).
enum ReadComicsParser {
    static let origin = "https://readcomicsonline.ru"

    /// Parse a comic page → title, cover, and the full chapter list.
    static func parseSeries(_ html: String, pageURL: URL) -> ComicSeries {
        let rawTitle = firstGroup(html, #"<meta property="og:title" content="([^"]+)""#)
            ?? firstGroup(html, #"<title>([^<]+)</title>"#) ?? "Untitled"
        let title = collapse(rawTitle).replacingOccurrences(
            of: #"\s*[—-]\s*Read Comics Online\s*$"#, with: "", options: .regularExpression)
        let cover = firstGroup(html, #"<meta property="og:image" content="([^"]+)""#)
            .flatMap { URL(string: $0) }

        let slug = pageURL.lastPathComponent
        let escaped = NSRegularExpression.escapedPattern(for: slug)
        // Anchors linking to a chapter of THIS series. The segment is usually a number but can be
        // lettered ("TPB", "Annual-1"), so we capture any non-slash segment. Normal series label
        // rows "#N" (preferred); the "Read First/Last" buttons link to the same chapters without a
        // "#", so if the "#" pass finds nothing we fall back to every chapter link (both dedupe by
        // segment, so this is safe and also rescues collected editions whose one row lacks a "#").
        let pattern = "<a\\b[^>]*href=\"[^\"]*?/comic/\(escaped)/([^\"/?#]+)/?(?:[?#][^\"]*)?\"[^>]*>(.*?)</a>"
        var hashLabeled: [String: ComicChapter] = [:]
        var anyChapter: [String: ComicChapter] = [:]
        forEachMatch(html, pattern) { g in
            guard g.count >= 3 else { return }
            let seg = g[1]
            guard let url = URL(string: "\(origin)/comic/\(slug)/\(seg)") else { return }
            let ch = ComicChapter(segment: seg, url: url)
            if anyChapter[seg] == nil { anyChapter[seg] = ch }
            if stripTags(g[2]).contains("#"), hashLabeled[seg] == nil { hashLabeled[seg] = ch }
        }
        let chosen = hashLabeled.isEmpty ? anyChapter : hashLabeled
        // Numeric chapters ascending; lettered ones (TPB, etc.) after, alphabetically.
        let sorted = chosen.values.sorted { a, b in
            switch (a.number, b.number) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return a.segment.localizedStandardCompare(b.segment) == .orderedAscending
            }
        }
        return ComicSeries(title: title, coverURL: cover, slug: slug, chapters: sorted)
    }

    /// Parse a chapter page → the exact, ordered page-image URLs (from the `#page-list` `<img>`s).
    /// This is the site's authoritative page list, so no CDN probing or count-guessing is needed.
    static func parseChapterPages(_ html: String) -> [URL] {
        let pattern = #"https://cdn\.readcomicsonline\.ru/uploads/manga/[^"'\s\\]+?/chapters/[^"'\s\\]+?/[^"'\s\\]+?\.(?:jpg|jpeg|png|webp|gif)"#
        var seen = Set<String>()
        var urls: [URL] = []
        forEachMatch(html, pattern) { g in
            guard seen.insert(g[0]).inserted, let u = URL(string: g[0]) else { return }
            urls.append(u)
        }
        return urls.sorted { $0.absoluteString.localizedStandardCompare($1.absoluteString) == .orderedAscending }
    }

    /// Parse a `/comic-list?page=N` directory page → the series cards on it plus the highest
    /// pagination page number (so callers know how many pages to walk). Verified against a real
    /// post-Cloudflare capture: 60 cards/page, pagination to 159.
    static func parseCatalog(_ html: String) -> (entries: [CatalogEntry], pageCount: Int) {
        // Each card: a cover <img> (.../uploads/manga/<slug>/cover/…) followed by the title anchor
        // carrying the distinctive `line-clamp-2` class. Pairing them by proximity ties cover→series.
        let pattern = #"<img[^>]+src="([^"]+/uploads/manga/[^"]+)"[^>]*alt="[^"]*"[^>]*>.*?<a href="https://readcomicsonline\.ru/comic/([a-z0-9\-]+)"\s+class="line-clamp-2[^"]*">([^<]+)</a>"#
        var seen = Set<String>()
        var entries: [CatalogEntry] = []
        forEachMatch(html, pattern) { g in
            guard g.count >= 4, seen.insert(g[2]).inserted else { return }
            entries.append(CatalogEntry(slug: g[2], title: collapse(g[3]),
                                        coverURL: URL(string: g[1])))
        }
        // Highest `comic-list?page=N` in the pagination control.
        var maxPage = 1
        forEachMatch(html, #"comic-list\?page=(\d+)"#) { g in
            if g.count >= 2, let n = Int(g[1]) { maxPage = max(maxPage, n) }
        }
        return (entries, maxPage)
    }

    // MARK: - regex helpers

    private static func stripTags(_ s: String) -> String {
        collapse(s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
    }
    private static func collapse(_ s: String) -> String {
        decodeEntities(s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
    /// Decode the handful of HTML entities that show up in scraped titles (`&#039;`, `&amp;`, …).
    /// Numeric (`&#39;` / `&#x27;`) and the common named ones — enough for comic titles.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let named = ["&amp;": "&", "&quot;": "\"", "&#039;": "'", "&#39;": "'",
                     "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ",
                     "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        // Remaining numeric entities: decimal &#NNN; and hex &#xHH;.
        func decodeNumeric(_ pattern: String, radix: Int, dropPrefix: Int) {
            while let r = out.range(of: pattern, options: .regularExpression) {
                let digits = out[r].dropFirst(dropPrefix).dropLast()
                if let code = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(code) {
                    out.replaceSubrange(r, with: String(scalar))
                } else { break }
            }
        }
        decodeNumeric(#"&#x([0-9A-Fa-f]+);"#, radix: 16, dropPrefix: 3)  // &#x
        decodeNumeric(#"&#(\d+);"#, radix: 10, dropPrefix: 2)            // &#
        return out
    }
    private static func firstGroup(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
    private static func forEachMatch(_ s: String, _ pattern: String, _ body: ([String]) -> Void) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return }
        let ns = s as NSString
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            body((0..<m.numberOfRanges).map {
                m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0))
            })
        }
    }
}

// MARK: - Browse UI (mirrored ReadComicsOnline directory)

/// The mirrored ReadComicsOnline directory: a searchable A→Z grid of ~9.5k streamed series, styled
/// to match the Library / Online browser (black bars, white text, 2:3 covers, hover lift). Tapping a
/// series resolves its chapters through the cleared Cloudflare gate and lets you read any issue
/// straight from the open CDN — nothing is downloaded to disk. A two-finger swipe-right goes back.
struct ReadComicsBrowseView: View {
    @Environment(AppRouter.self) private var router
    @State private var catalog = ReadComicsCatalogStore.shared
    @State private var showGate = false
    /// Set when "New Collection…" is picked from a series' menu, to present the naming sheet.
    @State private var pendingNewCollection: CollectionItem?

    /// The drilled-in series lives on the router so it survives a round-trip to the reader.
    private var selected: CatalogEntry? {
        get { router.readComicsSeries }
        nonmutating set { router.readComicsSeries = newValue }
    }

    // Search: the field updates instantly; filtering waits for a pause (debounce), then ranks.
    @State private var searchText = ""
    @State private var activeQuery = ""
    @State private var results: [CatalogEntry] = []
    @State private var searchDebounce: Task<Void, Never>?
    @State private var searching = false

    // Two-finger swipe-right → back, matching the Online browser.
    @State private var keyMonitor = KeyMonitor()
    @State private var swipeBack = SwipeBackDetector()

    // A–Z index (memoized off the catalog), shared with the Online browser via `AZLetter.index`.
    // Windowing state matches GetComics so the jump behavior (re-window, snap to top) is identical.
    @State private var letters: [AZLetter] = []
    @State private var windowStart = 0
    @State private var windowCount = ReadComicsBrowseView.pageSize
    static let pageSize = 400

    // Random "surprise me" landing (session-scoped). Active with no search → a random 200 of the
    // catalog; the rail's shuffle icon reshuffles, tapping a letter drops back to A–Z browsing.
    @State private var shelf = RandomShelf.readComics
    private var shuffling: Bool { activeQuery.isEmpty && shelf.active }

    private var shown: [CatalogEntry] {
        if !activeQuery.isEmpty { return results }
        return shuffling ? shelf.sample(catalog.entries) : catalog.entries
    }

    /// First entry under each initial letter of the (already A→Z sorted) catalog — same builder and
    /// "#" placement as the Online browser.
    private func computeLetters() {
        letters = AZLetter.index(catalog.entries, id: \.id, title: \.title)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                toolbar
                Divider().overlay(.white.opacity(0.12))
                if let selected {
                    ReadComicsSeriesView(entry: selected, onBack: { self.selected = nil },
                                         onNeedGate: { showGate = true })
                } else {
                    grid
                }
            }
        }
        .tint(.white)
        .sheet(isPresented: $showGate) { CloudflareGateSheet(onClose: { showGate = false }) }
        .sheet(item: $pendingNewCollection) { NewCollectionSheet(item: $0) }
        .onAppear {
            swipeBack.onBack = { goBack() }
            keyMonitor.start(key: handleKey, scroll: swipeBack.handle)
            if letters.isEmpty { computeLetters() }
        }
        .onDisappear { keyMonitor.stop(); searchDebounce?.cancel() }
        .onChange(of: searchText) { _, v in scheduleSearch(v) }
        .onChange(of: catalog.entries.count) { _, _ in computeLetters() }
    }

    // MARK: navigation

    private func goBack() {
        if selected != nil { selected = nil } else { router.showLibrary() }
    }
    private func handleKey(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 { goBack(); return true }   // Escape
        return false
    }

    // MARK: search (debounce + relevance ranking, like the Online browser)

    private func scheduleSearch(_ text: String) {
        searchDebounce?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { activeQuery = ""; results = []; searching = false; return }
        searching = true
        searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            let ranked = await Self.rank(catalog.entries, query: q)
            if Task.isCancelled { return }
            results = ranked; activeQuery = q; searching = false
        }
    }

    /// Filter titles matching `query` (separator-insensitive — "avengers armageddon" finds
    /// "Avengers: Armageddon"), then order so the strongest hits lead. Uses the shared `SearchRank`.
    private static func rank(_ entries: [CatalogEntry], query: String) async -> [CatalogEntry] {
        await Task.detached(priority: .userInitiated) {
            let nq = SearchRank.normalize(query)
            guard !nq.isEmpty else { return [] }
            return entries
                .compactMap { e -> (e: CatalogEntry, score: Int)? in
                    let nt = SearchRank.normalize(e.title)
                    guard nt.contains(nq) else { return nil }
                    return (e, SearchRank.score(normalizedTitle: nt, normalizedQuery: nq))
                }
                .sorted { a, b in
                    if a.score != b.score { return a.score > b.score }
                    if a.e.title.count != b.e.title.count { return a.e.title.count < b.e.title.count }
                    return a.e.title.localizedStandardCompare(b.e.title) == .orderedAscending
                }
                .map(\.e)
        }.value
    }

    // MARK: chrome

    private var toolbar: some View {
        HStack(spacing: 14) {
            // Same left side as the Online browser: a Back chevron only when drilled into a series;
            // at the directory level just the source picker, inset to line up with the covers.
            if selected != nil {
                Button { goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .pointingHandCursor()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let selected {
                    Text(selected.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                } else {
                    OnlineServerMenu()
                }
                if selected == nil {
                    if searching {
                        Text("Searching…").font(.caption2).foregroundStyle(.white.opacity(0.5))
                    } else if catalog.isMirrored {
                        HStack(spacing: 6) {
                            Text(shuffling ? "Random \(shown.count) of \(catalog.entries.count)"
                                           : "\(shown.count) series")
                            if activeQuery.isEmpty, !shuffling, let u = catalog.updatedText {
                                Text("· \(u)")
                            }
                            // Nudge to refresh when stale — tap the Connect button to do it.
                            if activeQuery.isEmpty, catalog.isStale {
                                Image(systemName: "clock.badge.exclamationmark")
                                    .foregroundStyle(.orange)
                                    .help("Catalog may be out of date — open Connect to refresh.")
                            }
                        }
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            Spacer()
            if selected == nil && catalog.isMirrored {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search…", text: $searchText)
                        .textFieldStyle(.plain).frame(width: 220)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.white.opacity(0.08), in: Capsule())
            }
            Button { router.showLibrary() } label: {
                Label("Home", systemImage: "house")
            }
            .labelStyle(.iconOnly).help("Home").pointingHandCursor()
            Button { router.showLocal() } label: {
                Label("Local", systemImage: "internaldrive")
            }
            .labelStyle(.iconOnly).help("Local library").pointingHandCursor()
            Button { router.showOnline() } label: {
                Label("Online", systemImage: "globe")
            }
            .labelStyle(.iconOnly).help("Online").pointingHandCursor()
            Button { showGate = true } label: { Label("Connect", systemImage: "shield.lefthalf.filled") }
                .help("Open the Cloudflare gate (solve the check / re-mirror)").pointingHandCursor()
        }
        .buttonStyle(.borderless).tint(.white)
        .padding(.horizontal, 30).padding(.vertical, 10)
        .background(Color.black)
    }

    @ViewBuilder private var grid: some View {
        if !catalog.isMirrored {
            VStack(spacing: 12) {
                Image(systemName: "square.grid.3x3").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("The directory hasn't been mirrored yet.").foregroundStyle(.white)
                Text("Tap Connect, solve the Cloudflare check, then “Mirror full catalog.”")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Same windowed engine + rail behavior as the Online browser. The rail shows only over
            // the alphabetical full list (search results are relevance-ranked, so `letters` is empty).
            WindowedCoverGrid(
                items: shown,
                letters: activeQuery.isEmpty ? letters : [],
                windowStart: $windowStart,
                windowCount: $windowCount,
                resetKey: activeQuery,
                pageSize: Self.pageSize,
                onActiveIndex: { idx in
                    let base = max(0, idx - 8), end = min(shown.count, idx + 60)
                    guard base < end else { return }
                    let urls = Array(shown[base..<end].compactMap(\.coverURL))
                    Task { await RemoteImageCache.shared.setPrefetchTarget(urls, maxPixel: 320) }
                },
                shuffleActive: shuffling,
                onShuffle: activeQuery.isEmpty
                    ? { shelf.reshuffle(); windowStart = 0; windowCount = Self.pageSize } : nil,
                onBeforeLetterJump: { shelf.active = false },
                header: {
                    if shown.isEmpty && !searching {
                        Text("No matches.").foregroundStyle(.white.opacity(0.5)).padding(.top, 60)
                    }
                },
                leading: { EmptyView() },
                cell: { entry in
                    ReadComicsCoverCell(title: entry.title, cover: entry.coverURL) { selected = entry }
                        .contextMenu {
                            AddToCollectionMenu(item: CollectionItem(readComics: entry),
                                                pendingNew: $pendingNewCollection)
                        }
                }
            )
        }
    }
}

/// A directory / issue cell built on the shared `CoverTile` + `CoverImage` so it's pixel-identical
/// to every other grid: 2:3 cover, faint panel, hairline border, two-line title, hover lift. The
/// optional `placeholder` (an issue number) shows only when a cover truly can't load — never a
/// different series' cover. Issue covers are heavy full pages, so extra retries smooth over bursts.
private struct ReadComicsCoverCell: View {
    let title: String
    let cover: URL?
    var placeholder: String? = nil
    var badge: String? = nil
    /// Last resort when the guessed cover URL is wrong (e.g. an issue not using `01.jpg`): resolve
    /// the issue's real first-page URL through the gate. Only issue cells provide this.
    var resolveRealCover: (() async -> URL?)? = nil
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverTile {
                CoverImage(url: cover, maxPixel: 320, retries: 5, resolveFallback: resolveRealCover) {
                    if let placeholder {
                        Text(placeholder).font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
                    } else {
                        Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.white.opacity(0.35))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Text(badge).font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: Capsule()).padding(6)
                    }
                }
            }
            .contentShape(Rectangle())
            .pointingHandCursor()
            .onTapGesture { onTap() }
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.white)
                .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .brightness(hovering ? 0.08 : 0).animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// A series' issue list, shown as a cover grid matching the directory. On appear it resolves the
/// chapters through the cleared gate; each issue's cover is the CMS's first page
/// (`…/chapters/<n>/01.jpg`), falling back to the series cover. Tapping an issue fetches that
/// chapter's exact page URLs and opens the reader (streamed from the CDN).
private struct ReadComicsSeriesView: View {
    let entry: CatalogEntry
    let onBack: () -> Void
    let onNeedGate: () -> Void

    @State private var chapters: [ComicChapter] = []
    @State private var loading = true
    @State private var failed = false
    @State private var diagnostic = ""
    @State private var opening: String?
    /// The real CDN manga-folder for this series (usually == slug, but taken from the series cover
    /// URL so the rare slug≠folder case still resolves issue covers correctly).
    @State private var cdnFolder: String = ""

    /// The issue thumbnail URL: a previously-resolved real cover if we have one (issues whose guess
    /// was wrong), otherwise the CMS convention `chapters/<segment>/01.jpg` (segment = "34" / "TPB").
    private func issueCover(_ segment: String) -> URL? {
        if let real = ReadComicsIssueCovers.shared.realCover(slug: entry.slug, chapter: segment) {
            return real
        }
        let folder = cdnFolder.isEmpty ? entry.slug : cdnFolder
        return URL(string: "https://cdn.readcomicsonline.ru/uploads/manga/\(folder)/chapters/\(segment)/01.jpg")
    }

    var body: some View {
        Group {
            if loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading chapters…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed || chapters.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Couldn't reach this series.").foregroundStyle(.white)
                    Text("The Cloudflare check may need solving. Tap Connect, verify access, then retry.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !diagnostic.isEmpty {
                        Text(diagnostic).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).textSelection(.enabled)
                    }
                    HStack {
                        Button("Connect") { onNeedGate() }
                        Button("Retry") { Task { await resolve() } }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                GeometryReader { geo in
                    let cols = GridStyle.columns(geo.size.width)
                    ScrollView {
                        LazyVGrid(columns: cols, alignment: .center, spacing: GridStyle.rowSpacing) {
                            ForEach(chapters) { ch in
                                ReadComicsCoverCell(title: ch.label,
                                                    cover: issueCover(ch.segment),
                                                    placeholder: ch.label,
                                                    badge: opening == ch.segment ? "…" : nil,
                                                    resolveRealCover: {
                                                        // Guess wrong (different filename) — get the
                                                        // chapter's real page 1 and remember it so it
                                                        // loads from cache next time.
                                                        let real = await CloudflareSession.shared
                                                            .fetchChapterPages(ch.url).first
                                                        if let real {
                                                            ReadComicsIssueCovers.shared.remember(
                                                                slug: entry.slug, chapter: ch.segment, url: real)
                                                        }
                                                        return real
                                                    }) {
                                    open(ch)
                                }
                            }
                        }
                        .padding(.horizontal, GridStyle.hPadding).padding(.vertical, 24)
                    }
                }
            }
        }
        .task(id: entry.id) { await resolve() }
    }

    private func resolve() async {
        loading = true; failed = false; diagnostic = ""
        guard let url = entry.pageURL else { loading = false; failed = true; return }
        let (series, bytes) = await CloudflareSession.shared.fetchSeriesDiagnosed(url)
        guard let series else {
            diagnostic = "Page fetch returned nothing (Cloudflare block or bad URL).\n\(url.absoluteString)"
            loading = false; failed = true; return
        }
        guard !series.chapters.isEmpty else {
            diagnostic = "Loaded \(bytes) bytes but found 0 chapters (parser).\n\(url.absoluteString)"
            loading = false; failed = true; return
        }
        // The series cover URL embeds the real CDN manga-folder: /uploads/manga/<folder>/cover/…
        if let cov = series.coverURL?.absoluteString,
           let m = cov.range(of: #"/uploads/manga/([^/]+)/"#, options: .regularExpression) {
            cdnFolder = String(cov[m]).replacingOccurrences(of: "/uploads/manga/", with: "")
                .replacingOccurrences(of: "/", with: "")
        }
        chapters = series.chapters   // already ordered by the parser (numeric first, then lettered)
        loading = false
    }

    private func open(_ ch: ComicChapter) {
        opening = ch.segment
        Task {
            let pages = await CloudflareSession.shared.fetchChapterPages(ch.url)
            opening = nil
            guard !pages.isEmpty else { return }
            let comic = Comic(url: ch.url, series: entry.title, isArchive: false,
                              coverURL: pages.first, pageCount: pages.count, progress: nil,
                              chapterCount: 0, metaTitle: "\(entry.title) \(ch.label)",
                              tooltip: nil, remotePages: pages)
            ReadComicsHistory.shared.record(url: ch.url, series: entry.title, label: ch.label,
                                            cover: pages.first, pages: pages)
            AppModel.shared.openRemote(comic)
            AppRouter.shared.readerOrigin = .readComics(entry)   // Escape → back to this series
            AppRouter.shared.route = .reader
        }
    }
}
