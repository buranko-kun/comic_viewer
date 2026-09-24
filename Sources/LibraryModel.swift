import SwiftUI

/// The library: the configured root folders and the comics discovered inside them.
/// A **comic** is any folder that directly contains ≥1 image (its direct images are the
/// pages), or any archive file (.cbz/.cbr/…). Comics are grouped into **series** by the
/// first path component under their library root.
@MainActor
@Observable
final class LibraryModel {
    static let shared = LibraryModel()

    private(set) var folders: [URL] = []
    private(set) var comics: [Comic] = []
    private(set) var isScanning = false
    private var hidden: Set<String> = []   // standardized paths removed from the library (kept on disk)

    init() {
        folders = CentralStore.loadLibraryFolders()
        hidden = CentralStore.loadHiddenPaths()
    }

    /// What to show at a library location, mirroring the folder tree: `nil` is home (the
    /// configured roots' contents), otherwise the contents of `dir`. A comic sitting directly
    /// in the location is an issue card; a comic living deeper contributes to a sub-folder
    /// **group** card you drill into. This makes nesting (e.g. `Deadpool/<series>/<issues>`)
    /// navigate level-by-level instead of collapsing into one flat list.
    func entries(at dir: URL?) -> (groups: [LibraryGroup], comics: [Comic]) {
        // Drilling into a folder skips over any "pass-through" levels — a sub-folder that holds
        // exactly one series and nothing else — so e.g. Batman → (its only series) → issues lands
        // straight on the issues. The intermediate series level only appears when there are 2+.
        let bases = dir.map { [resolveSingleChain($0.standardizedFileURL)] }
            ?? folders.map(\.standardizedFileURL)
        return listing(bases: bases)
    }

    /// Descend while a folder contains exactly one sub-series and no issues of its own.
    private func resolveSingleChain(_ dir: URL) -> URL {
        var current = dir
        while true {
            let e = listing(bases: [current])
            guard e.comics.isEmpty, e.groups.count == 1 else { return current }
            current = e.groups[0].url
        }
    }

    /// List the immediate groups + comics directly under `bases` (no chain-skipping).
    private func listing(bases: [URL]) -> (groups: [LibraryGroup], comics: [Comic]) {
        var groupComics: [URL: [Comic]] = [:]
        var direct: [Comic] = []
        for c in comics {
            for base in bases {
                guard let rel = Self.relativeComponents(c.url, under: base) else { continue }
                if rel.count == 1 {
                    direct.append(c)
                } else {
                    groupComics[base.appendingPathComponent(rel[0]), default: []].append(c)
                }
                break
            }
        }
        var groups: [LibraryGroup] = []
        for (url, cs) in groupComics {
            // A sub-folder that wraps a *single* comic (through any depth of one-child folders,
            // e.g. the redundant "…(001-006)/…(2005)/" levels some extractors create) adds no
            // real branching — surface that comic directly and skip the folder level.
            if cs.count == 1 {
                direct.append(cs[0])
                continue
            }
            let sorted = cs.sorted(by: Self.byTitle)
            let folderCover = sorted.first { $0.coverURL != nil }?.coverURL
            let archiveCover = folderCover == nil ? sorted.first(where: \.isArchive)?.url : nil
            // A web series groups under its descriptor file; show its real title, not the filename.
            let title = cs.allSatisfy(\.isRemote) ? cs.first?.series : nil
            groups.append(LibraryGroup(url: url, coverURL: folderCover, coverArchive: archiveCover,
                                       count: cs.count, title: title))
        }
        groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (groups, direct.sorted(by: Self.byTitle))
    }

    /// `url`'s path components relative to `base`, or nil if it isn't under `base`.
    private static func relativeComponents(_ url: URL, under base: URL) -> [String]? {
        let u = url.standardizedFileURL.pathComponents
        let b = base.pathComponents
        guard u.count > b.count, Array(u.prefix(b.count)) == b else { return nil }
        return Array(u.dropFirst(b.count))
    }

    /// Where a downloaded comic titled `title` is saved: the first library root, auto-filed into a
    /// series/character subfolder when the title maps to one (Batman/, X-Men/, Spawn/, …), else the
    /// root itself. With no library configured yet, a `Comics` root is created under Application
    /// Support and registered. Created on demand.
    func downloadFolder(forTitle title: String) -> URL {
        let fm = FileManager.default
        let root: URL
        if let first = folders.first {
            root = first
        } else {
            root = CentralStore.baseDir.appendingPathComponent("Comics", isDirectory: true)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            addFolder(root)   // register + scan so downloads become a browsable library
        }
        if let series = SeriesMapper.folder(for: title) {
            let folder = root.appendingPathComponent(series, isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        return root
    }

    // MARK: Folder management

    func addFolder(_ url: URL) {
        let u = url.standardizedFileURL
        guard !folders.contains(u) else { return }
        folders.append(u)
        CentralStore.saveLibraryFolders(folders)
        scan()
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url.standardizedFileURL }
        CentralStore.saveLibraryFolders(folders)
        scan()
    }

    func rescan() { scan() }

    /// Clear a comic's saved reading state (resume position, chapters, rotation) so it reads as a
    /// brand-new, never-opened comic. The file itself is untouched.
    func resetState(_ comic: Comic) {
        try? FileManager.default.removeItem(at: CentralStore.stateURL(for: CentralStore.key(for: comic.url)))
        scan()   // refresh progress badges
    }

    /// Remove a comic from the library. `fromDisk == false` hides it (kept on disk, filtered from
    /// future scans); `fromDisk == true` moves the file to the Trash. Either way its saved state is
    /// dropped. Returns false only if a requested Trash move failed (library left unchanged).
    @discardableResult
    func delete(_ comic: Comic, fromDisk: Bool) -> Bool {
        if fromDisk {
            do { try FileManager.default.trashItem(at: comic.url, resultingItemURL: nil) }
            catch { return false }
        } else {
            hidden.insert(comic.url.standardizedFileURL.path)
            CentralStore.saveHiddenPaths(hidden)
        }
        try? FileManager.default.removeItem(at: CentralStore.stateURL(for: CentralStore.key(for: comic.url)))
        scan()
        return true
    }

    // MARK: - Streamable-ZIP conversion (one-time library maintenance)

    /// Progress of a running `normalizeLibraryToZip` pass: pages done / total, plus how many were
    /// actually converted. `nil` when idle. Drives the Settings → Library progress UI.
    private(set) var normalizeProgress: (done: Int, total: Int, converted: Int)?

    /// Rewrite every RAR-backed comic in the library as a stored ZIP so it streams page-by-page.
    /// Lossless and in place (see `ArchiveExtractor.normalizeToZip`); already-ZIP comics are skipped
    /// cheaply. Runs sequentially off-main to avoid hammering the disk with parallel extractions.
    func normalizeLibraryToZip() {
        guard normalizeProgress == nil else { return }
        let archives = comics.filter(\.isArchive).map(\.url)
        guard !archives.isEmpty else { return }
        normalizeProgress = (0, archives.count, 0)
        Task.detached(priority: .utility) {
            var converted = 0
            for (i, url) in archives.enumerated() {
                let wasZip = ArchiveExtractor.list(url)?.type.caseInsensitiveCompare("zip") == .orderedSame
                let ok = ArchiveExtractor.normalizeToZip(url)
                if ok, !wasZip { converted += 1 }
                let done = i + 1
                let tally = converted
                await MainActor.run { self.normalizeProgress = (done, archives.count, tally) }
            }
            await MainActor.run {
                self.normalizeProgress = nil
                self.rescan()
            }
        }
    }

    /// Comics actually being read (past the first couple of pages, not finished), most-recently
    /// first — the home "Continue Reading" shelf. Just-opened comics (page 0/1) are excluded, as
    /// are archives with no saved position. Recency comes from the state file's modification time.
    var continueReading: [Comic] {
        let started = comics.filter { c in
            guard let p = c.progress, p.count > 0 else { return false }   // need a real position
            return p.page >= 3 && p.page < p.count                        // read some, not finished
        }
        // Streamed ReadComicsOnline issues aren't scanned into `comics`; fold in the ones being read.
        let remote = ReadComicsHistory.shared.continueComics()
        return (started + remote)
            .map { ($0, CentralStore.lastReadDate(forKey: CentralStore.key(for: $0.url)) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(15)
            .map(\.0)
    }

    /// Comics with saved reading activity, newest first. Unlike Continue Reading, finished
    /// comics remain here so the shelf acts as a lightweight reading history.
    var recentlyRead: [Comic] {
        comics
            .compactMap { comic -> (Comic, Date)? in
                guard comic.progress != nil,
                      let date = CentralStore.lastReadDate(forKey: CentralStore.key(for: comic.url))
                else { return nil }
                return (comic, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(20)
            .map(\.0)
    }

    // MARK: Scanning

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let roots = folders
        Task {
            let all = await Task.detached { Self.scanRoots(roots) }.value
            let found = self.hidden.isEmpty ? all
                : all.filter { !self.hidden.contains($0.url.standardizedFileURL.path) }
            self.comics = found
            self.isScanning = false
            CollectionStore.shared.reconcile(libraryComics: found)   // replace downloaded online items
            // Warm every cover thumbnail in the background so grids are instant when the user
            // navigates — folder covers decode straight off; archives get their cover extracted
            // (cached to disk) first. Idempotent, so repeat scans just hit the caches.
            Task.detached(priority: .utility) { await Self.prewarmCovers(found) }
        }
    }

    /// Resolve and cache each comic's cover thumbnail ahead of time, a few at a time.
    nonisolated private static func prewarmCovers(_ comics: [Comic]) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            var it = comics.makeIterator()
            func pump() {
                while running < 4, let comic = it.next() {
                    running += 1
                    group.addTask {
                        var src = comic.coverURL
                        if src == nil, comic.isArchive { src = await ArchiveCover.make(for: comic.url) }
                        if let src { _ = await ThumbnailCache.shared.thumbnail(for: src, maxPixel: 500) }
                    }
                }
            }
            pump()
            while await group.next() != nil { running -= 1; pump() }
        }
    }

    private static func byTitle(_ a: Comic, _ b: Comic) -> Bool {
        a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    /// Walk each root, emitting a Comic for every folder that directly holds images and for
    /// every archive file. `nonisolated` so it can run off the main actor.
    nonisolated static func scanRoots(_ roots: [URL]) -> [Comic] {
        var out: [Comic] = []
        var seen = Set<String>()
        for root in roots {
            for comic in scanRoot(root) where seen.insert(comic.url.path).inserted {
                out.append(comic)
            }
        }
        return out
    }

    private nonisolated static func scanRoot(_ root: URL) -> [Comic] {
        let fm = FileManager.default
        let rootDepth = root.standardizedFileURL.pathComponents.count
        var comics: [Comic] = []

        func series(for url: URL) -> String {
            let comps = url.standardizedFileURL.pathComponents
            return comps.count > rootDepth ? comps[rootDepth] : root.lastPathComponent
        }

        func walk(_ dir: URL) {
            let children = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            var subdirs: [URL] = []
            var images: [URL] = []
            for child in children {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    subdirs.append(child)
                } else if SupportedTypes.isSupported(child) {
                    images.append(child.standardizedFileURL)
                } else if ArchiveExtractor.isArchive(child) {
                    comics.append(makeArchiveComic(child, series: series(for: child)))
                } else if isWebComic(child) {
                    comics.append(makeRemoteComic(child, series: series(for: child)))
                } else if isWebSeries(child) {
                    comics.append(contentsOf: makeSeriesComics(child))
                }
            }
            if !images.isEmpty {
                comics.append(makeFolderComic(dir, images: images, series: series(for: dir)))
            }
            for sub in subdirs { walk(sub) }
        }

        walk(root.standardizedFileURL)
        return comics
    }

    /// A `.webcomic.json` descriptor: `{ "title": "...", "pages": ["https://…", …] }`. Its pages
    /// are remote image URLs streamed on demand — nothing but this tiny file lives on disk.
    nonisolated static func isWebComic(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(".webcomic.json")
    }

    /// A `.webseries.json` descriptor → one comic per issue, pages auto-probed at read time.
    nonisolated static func isWebSeries(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(".webseries.json")
    }

    /// Display name for a library folder/level: a web series' title from its descriptor, else the
    /// cleaned folder name. Used by the toolbars so a series never shows its raw `.webseries.json`.
    nonisolated static func displayName(for url: URL) -> String {
        if isWebSeries(url), let t = WebComic.seriesTitle(url) { return t }
        return TitleCleaner.clean(url.lastPathComponent)
    }

    private nonisolated static func makeSeriesComics(_ file: URL) -> [Comic] {
        guard let loaded = WebComic.loadSeries(file) else { return [] }
        return loaded.issues.map { issue in
            // Synthetic per-issue URL (unique id + state key); never opened as a real file.
            let url = file.appendingPathComponent(String(issue.number))
            var progress: ComicProgress?
            if let st = CentralStore.loadState(forKey: CentralStore.key(for: url)),
               let li = st.lastIndex, let ct = st.pageCount, ct > 0 {
                progress = ComicProgress(page: li + 1, count: ct)
            }
            // Fixed page count (`pagesPerIssue`) → generate the full list up front, no probing.
            if let count = issue.fixedCount, count > 0 {
                let pages = (1...count).compactMap { n in
                    URL(string: issue.pageTemplate.replacingOccurrences(
                        of: "{page}", with: String(format: "%0\(max(0, issue.pagePad))d", n)))
                }
                return Comic(url: url, series: loaded.series, isArchive: false, coverURL: issue.cover,
                             pageCount: pages.count, progress: progress, chapterCount: 0,
                             metaTitle: issue.title, tooltip: "Streamed from the web",
                             remotePages: pages)
            }
            return Comic(url: url, series: loaded.series, isArchive: false, coverURL: issue.cover,
                         pageCount: 0, progress: progress, chapterCount: 0,
                         metaTitle: issue.title, tooltip: "Streamed from the web",
                         remotePageTemplate: issue.pageTemplate, remotePagePad: issue.pagePad,
                         remotePageHint: issue.pageHint)
        }
    }

    private nonisolated static func makeRemoteComic(_ file: URL, series: String) -> Comic {
        let loaded = WebComic.load(file)
        let pages = loaded?.pages ?? []
        let title = loaded?.title ?? file.lastPathComponent
            .replacingOccurrences(of: ".webcomic.json", with: "", options: .caseInsensitive)
        var progress: ComicProgress?
        if let st = CentralStore.loadState(forKey: CentralStore.key(for: file)),
           let li = st.lastIndex, let ct = st.pageCount, ct > 0 {
            progress = ComicProgress(page: li + 1, count: ct)
        }
        return Comic(url: file, series: series, isArchive: false, coverURL: pages.first,
                     pageCount: pages.count, progress: progress, chapterCount: 0,
                     metaTitle: title, tooltip: "Streamed from the web", remotePages: pages)
    }

    private nonisolated static func makeFolderComic(_ dir: URL, images: [URL], series: String) -> Comic {
        let sorted = FileScanner.sorted(images)
        // Match chapter/resume keys by the relative path (mirrors `AppModel.pageKey`) so pages nested
        // in a subfolder resolve; keep the bare filename too for legacy states saved by filename.
        let present = Set(sorted.flatMap { [chapterKey($0, folder: dir), $0.lastPathComponent] })
        let info = ComicInfo.load(fromFolder: dir)

        var progress: ComicProgress?
        var manual: Set<String> = []
        if let st = CentralStore.loadState(forKey: CentralStore.key(for: dir)) {
            if let lp = st.lastPage,
               let idx = sorted.firstIndex(where: { chapterKey($0, folder: dir) == lp || $0.lastPathComponent == lp }) {
                progress = ComicProgress(page: idx + 1, count: sorted.count)
            }
            manual = Set(st.chapters).intersection(present)
        }
        // Chapter count = manual chapters ∪ ComicInfo bookmarks that resolve to a page.
        let bookmarkFiles = bookmarkFilenames(info, images: sorted)
        let chapterCount = manual.union(bookmarkFiles.keys).count

        return Comic(url: dir, series: series, isArchive: false, coverURL: sorted.first,
                     pageCount: sorted.count, progress: progress, chapterCount: chapterCount,
                     metaTitle: info?.displayTitle, tooltip: info?.tooltip)
    }

    private nonisolated static func makeArchiveComic(_ file: URL, series: String) -> Comic {
        // Archives aren't extracted at scan time; the saved index/count (written while reading)
        // gives real progress. Older states without it fall back to "opened" (page 0).
        var progress: ComicProgress?
        var chapterCount = 0
        if let st = CentralStore.loadState(forKey: CentralStore.key(for: file)) {
            if st.lastPage != nil {
                if let idx = st.lastIndex, let count = st.pageCount, count > 0 {
                    progress = ComicProgress(page: idx + 1, count: count)
                } else {
                    progress = ComicProgress(page: 0, count: 0)
                }
            }
            // Manual chapters are saved centrally (by filename), so we can surface a count without
            // extracting. Bookmarks embedded in the archive's ComicInfo.xml still need opening.
            chapterCount = st.chapters.count
        }
        return Comic(url: file, series: series, isArchive: true, coverURL: nil,
                     pageCount: 0, progress: progress, chapterCount: chapterCount,
                     metaTitle: nil, tooltip: nil)
    }

    /// Map ComicInfo bookmarks to `filename → name` for pages that exist in `images`.
    private nonisolated static func bookmarkFilenames(_ info: ComicInfo?, images: [URL]) -> [String: String] {
        guard let info else { return [:] }
        var out: [String: String] = [:]
        for b in info.bookmarks where images.indices.contains(b.imageIndex) {
            out[images[b.imageIndex].lastPathComponent] = b.name
        }
        return out
    }

    /// Resolve a comic's chapters (manual saved + ComicInfo bookmarks) to page images, in order.
    /// Folders are read directly; archives are extracted once (off the main actor, cached), so the
    /// chapter thumbnail grid works for CBZ/CBR too.
    func resolveChapters(of comic: Comic) async -> [ChapterRef] {
        if !comic.isArchive {
            return Self.buildChapters(images: FileScanner.scan(comic.url), folder: comic.url,
                                      comicKey: CentralStore.key(for: comic.url))
        }
        guard let dir = await extractedDir(for: comic.url) else { return [] }
        return Self.buildChapters(images: FileScanner.scanRecursive(dir), folder: dir,
                                  comicKey: CentralStore.key(for: comic.url))
    }

    /// The chapter refs for a folder comic (synchronous; archives return [] — use `resolveChapters`).
    func chapters(of comic: Comic) -> [ChapterRef] {
        guard !comic.isArchive else { return [] }
        return Self.buildChapters(images: FileScanner.scan(comic.url), folder: comic.url,
                                  comicKey: CentralStore.key(for: comic.url))
    }

    /// A page's chapter key: its path **relative to `folder`** (mirrors `AppModel.pageKey`), so a
    /// page nested in a subfolder inside the archive/folder keys as `<sub>/<file>.jpg`, not just the
    /// filename. Manual chapters are saved with this key, so matching must use it too.
    nonisolated static func chapterKey(_ url: URL, folder: URL) -> String {
        let base = folder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    /// Build ChapterRefs from a page list: pages that are manual chapters or ComicInfo bookmarks.
    /// Manual chapters carry their stored `key` (for rename/delete) and a user name (from
    /// `chapterNames`), falling back to the bookmark name / "Chapter N".
    private nonisolated static func buildChapters(images: [URL], folder: URL, comicKey: String) -> [ChapterRef] {
        guard !images.isEmpty else { return [] }
        let state = CentralStore.loadState(forKey: comicKey)
        let manual = Set(state?.chapters ?? [])
        let names = state?.chapterNames ?? [:]
        let bookmarks = bookmarkFilenames(ComicInfo.load(fromFolder: folder), images: images)
        guard !manual.isEmpty || !bookmarks.isEmpty else { return [] }

        var ordinal = 0
        return images.enumerated().compactMap { idx, url in
            let file = url.lastPathComponent
            // Match manual chapters by the relative key (new scheme) or the bare filename (legacy
            // states) — pages nested in a subfolder key as `<sub>/<file>`, not `<file>`.
            let key = chapterKey(url, folder: folder)
            let isManual = manual.contains(key) || manual.contains(file)
            guard isManual || bookmarks[file] != nil else { return nil }
            ordinal += 1
            // Prefer a user name (keyed by relative key or legacy filename), then the bookmark name.
            let name = names[key] ?? names[file] ?? bookmarks[file]
            // The key we persist under: the relative key if that's what's stored, else the filename.
            let storedKey = manual.contains(key) ? key : (manual.contains(file) ? file : key)
            return ChapterRef(ordinal: ordinal, page: idx + 1, index: idx, url: url,
                              name: name, key: storedKey, isManual: isManual)
        }
    }

    /// Rename a manual chapter in a comic's saved state (empty clears the custom name). No effect on
    /// ComicInfo bookmarks (they have no state entry). Returns true if the state changed.
    @discardableResult
    nonisolated static func renameChapter(comicKey: String, key: String, to name: String) -> Bool {
        guard var st = CentralStore.loadState(forKey: comicKey), st.chapters.contains(key) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { st.chapterNames[key] = nil } else { st.chapterNames[key] = trimmed }
        writeState(st, comicKey: comicKey)
        return true
    }

    /// Remove a manual chapter marker (and its name) from a comic's saved state.
    @discardableResult
    nonisolated static func deleteChapter(comicKey: String, key: String) -> Bool {
        guard var st = CentralStore.loadState(forKey: comicKey) else { return false }
        st.chapters.removeAll { $0 == key }
        st.chapterNames[key] = nil
        writeState(st, comicKey: comicKey)
        return true
    }

    private nonisolated static func writeState(_ state: ComicState, comicKey: String) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: CentralStore.stateURL(for: comicKey), options: .atomic)
        }
    }

    // MARK: - Archive sessions

    /// Resolve an archive through the shared session manager. If the reader already opened the
    /// archive in streamed mode, the manager waits for its background fill and reuses that directory
    /// instead of extracting a second copy.
    private func extractedDir(for archive: URL) async -> URL? {
        await ArchiveSessionManager.shared.extractFully(for: archive)?.dir
    }
}
