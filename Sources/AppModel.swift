import SwiftUI
import AppKit
import Observation
import ImageIO

/// App state: the ordered image set, the current index, and the decoded current image.
/// Opening a folder/archive resumes at the last-read page; opening a specific image goes
/// to it. Per-comic state (chapters + last page) persists in a `.comicviewer.json` sidecar.
@MainActor
@Observable
final class AppModel {
    /// Shared instance so the AppDelegate (Open-With / `open -a`) and the SwiftUI
    /// scene drive the same state.
    static let shared = AppModel()

    private(set) var items: [URL] = []
    private(set) var index = 0
    private(set) var current: DisplayImage?
    /// Bumped every time `current` is (re)assigned with a freshly decoded page — the reader watches
    /// this to re-fit against the *new* image (index changes before the image finishes decoding).
    private(set) var renderTick = 0
    /// The facing page (index + 1) when two-page spread is on; nil otherwise.
    private(set) var secondary: DisplayImage?
    /// Two-page spread: show the current page and the one after it side by side, paging by two.
    private(set) var spreadEnabled = false
    /// Set to the file name when a file cannot be decoded/opened (soft-fail placeholder).
    private(set) var failedName: String?
    /// The file behind `failedName`, so the error view can reveal it in Finder.
    private(set) var failedURL: URL?
    /// A one-shot message (e.g. "Resumed — 142 / 596") for the UI to flash.
    private(set) var transientMessage: String?

    /// True from the moment a comic starts opening until its first page is decoded (or it fails).
    /// Archive extraction runs off the main thread, so this drives a loading spinner instead of the
    /// empty "Open an image" prompt while there's nothing to show yet.
    private(set) var isOpening = false
    /// Name of the item being opened (archive / folder / image), for the loading label.
    private(set) var openingName: String?

    /// Manually-set chapter (bookmark) filenames for the current comic.
    private(set) var chapters: Set<String> = []
    /// User-given names for manual chapters (page key → name); overrides the "Chapter N" default.
    private(set) var chapterNames: [String: String] = [:]
    /// Named chapters imported from a `ComicInfo.xml` bookmark list (filename → name). These are
    /// derived (read-only) and merged with `chapters` for navigation/display.
    private var bookmarkNames: [String: String] = [:]

    private var folder: URL?          // the image folder (temp dir for an archive)
    private var comicKey: String?     // canonical path used to key central state (nil = no persistence)
    private var stateURL: URL?        // central state file for this comic (in Application Support)
    private var legacyStateURLs: [URL] = []  // old in-folder sidecars to migrate + retire
    private var lastPage: String?     // resume point (stable page key: relative path or remote URL)
    private var manualRotate: Bool?   // per-comic reading-rotation override; nil = content default
    private var openingTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var orientationProbeTask: Task<Void, Never>?
    private var pagesLandscape = true // whether the comic's pages are landscape-native (probed)
    private var tempDirs: [URL] = []  // archive extraction dirs, cleaned up on quit
    private var streamer: ArchiveStreamer?  // on-demand page extraction for a streamed archive
    private var remoteMode = false          // current comic streams its pages from the web
    private var openSeq = 0                  // bumped on every open; guards async remote probes

    /// An archive extracted (or streamed) earlier this session, so re-opening it — e.g. jumping to
    /// a chapter from the library grid — reuses the temp dir instead of extracting all over again.
    private struct OpenedArchive { let dir: URL; let items: [URL]; let streamer: ArchiveStreamer? }
    private var openedArchives: [String: OpenedArchive] = [:]  // archive key → opened state
    private var archiveOrder: [String] = []          // LRU, oldest → newest (keys into openedArchives)
    private var currentArchiveKey: String?           // the open comic's archive — never evicted
    private let maxCachedArchives = 4                 // bound session temp-dir use; evict the rest

    private let cache = ImageCache()
    private var loadToken = 0
    private var saveTask: Task<Void, Never>?

    private static let stateFileName = ".comicviewer.json"
    private static let legacyFileName = ".landscape-chapters.json"

    var counter: String { items.isEmpty ? "" : "\(index + 1) / \(items.count)" }
    var currentName: String? {
        items.indices.contains(index) ? items[index].lastPathComponent : nil
    }

    /// Whether this comic reads in "rotated landscape" mode: portrait pages are spun 90° to fill
    /// the screen and the HUD/overlays rotate to match. The **default is content-aware** — comics
    /// whose pages are already landscape (pre-rotated scans) default on; genuine portrait comics
    /// default off (shown upright). A per-comic override (toggled with R) wins and persists.
    /// Rotation for the current comic: an in-reader override (R) wins for this comic only; otherwise
    /// the global default (Horizontal/Vertical) from Settings. Overrides are ephemeral — they reset
    /// to the default when the next comic opens (`manualRotate` isn't persisted).
    var readingPortrait: Bool { manualRotate ?? ReaderSettings.shared.defaultView.rotated }

    /// Bumped every time a comic opens — the reader watches this to reset per-comic view overrides.
    var openGeneration: Int { openSeq }

    @discardableResult
    func toggleReadingRotation() -> String {
        orientationProbeTask?.cancel()
        orientationProbeTask = nil
        manualRotate = !readingPortrait   // ephemeral: this comic only, not persisted
        return readingPortrait ? "Vertical (pages rotated)" : "Horizontal (as-is)"
    }

    // MARK: Opening

    /// `startIndex` opens directly at that page (used by the chapter grid), overriding resume —
    /// it survives an archive's asynchronous extraction, unlike a follow-up `goTo`.
    func open(urls: [URL], startIndex: Int? = nil) {
        openingTask?.cancel()
        openingTask = nil
        loadTask?.cancel()
        loadTask = nil
        orientationProbeTask?.cancel()
        orientationProbeTask = nil
        let urls = urls.map(\.standardizedFileURL)
        guard let first = urls.first else { return }

        // Drop the previous comic's page immediately so it never flashes behind the new one
        // while the first page decodes (or an archive extracts).
        current = nil
        failedName = nil
        failedURL = nil
        isOpening = true
        openingName = first.lastPathComponent
        streamer = nil   // dropped now; a streamed archive re-creates it once its pages are listed
        remoteMode = false
        openSeq += 1

        // Open a web comic (.webcomic.json) → stream its remote page URLs; nothing on disk but the
        // descriptor. No extraction, no local files.
        if urls.count == 1, LibraryModel.isWebComic(first) {
            openWebComic(first, startIndex: startIndex)
            return
        }

        // Open an archive (.cbz/.cbr/…) → extract to a temp dir, then read like a folder.
        if urls.count == 1, ArchiveExtractor.isArchive(first) {
            let key = CentralStore.key(for: first)
            currentArchiveKey = key
            // Reuse this session's extraction if we still have it (instant re-open / chapter jump).
            if let cached = openedArchives[key],
               FileManager.default.fileExists(atPath: cached.dir.path) {
                touchArchive(key)
                reopenArchive(first, cached: cached, startIndex: startIndex)
            } else {
                openArchive(first, startIndex: startIndex)
            }
            return
        }
        currentArchiveKey = nil   // opening a folder / loose images — no archive is current

        // Open a folder → resume.
        if urls.count == 1, isDirectory(first) {
            openFolder(first, initialImage: nil, startIndex: startIndex)
            return
        }

        let supported = urls.filter(SupportedTypes.isSupported)
        guard !supported.isEmpty else { finishOpening(); return }

        if supported.count == 1 {
            openFolder(supported[0].deletingLastPathComponent(), initialImage: supported[0])
        } else {
            // An explicit multi-file selection: use exactly those, no folder scan / resume.
            beginComic(items: Self.sorted(supported),
                       folder: supported.first?.deletingLastPathComponent(),
                       comicKey: nil, legacyStateURLs: [], start: 0)
        }
    }

    /// Re-open an archive already extracted/streamed this session — no extraction, so it's instant.
    private func reopenArchive(_ archive: URL, cached: OpenedArchive, startIndex: Int?) {
        streamer = cached.streamer
        let base = archive.deletingPathExtension().lastPathComponent
        let legacy = archive.deletingLastPathComponent()
            .appendingPathComponent(base + ".comicviewer.json")
        beginComic(items: cached.items, folder: cached.dir,
                   comicKey: CentralStore.key(for: archive),
                   legacyStateURLs: [legacy], initialImage: nil, start: startIndex)
    }

    /// Open a library web comic (routed from `RootView` since a series issue has no real file URL):
    /// a single issue with a fixed page list, or a series issue whose page count is probed.
    func openRemote(_ comic: Comic) {
        openingTask?.cancel()
        openingTask = nil
        loadTask?.cancel()
        loadTask = nil
        orientationProbeTask?.cancel()
        orientationProbeTask = nil
        current = nil; failedName = nil; failedURL = nil
        isOpening = true; openingName = comic.title
        streamer = nil; currentArchiveKey = nil; remoteMode = true
        openSeq += 1
        let seq = openSeq
        let key = CentralStore.key(for: comic.url)

        if let pages = comic.remotePages, !pages.isEmpty {
            beginComic(items: pages, folder: nil, comicKey: key, legacyStateURLs: [], initialImage: nil, start: nil)
            return
        }
        guard let template = comic.remotePageTemplate else {
            failedName = comic.title; failedURL = comic.url; current = nil; finishOpening(); return
        }
        let pad = comic.remotePagePad
        func pageURL(_ n: Int) -> URL? {
            URL(string: template.replacingOccurrences(
                of: "{page}", with: String(format: "%0\(max(0, pad))d", n)))
        }
        // Fast path: if we already learned this issue's length (saved after the first read), build
        // the page list directly — no re-probing the CDN.
        if let st = CentralStore.loadState(forKey: key), let pc = st.pageCount, pc > 0 {
            let items = (1...pc).compactMap(pageURL)
            if !items.isEmpty {
                beginComic(items: items, folder: nil, comicKey: key, legacyStateURLs: [], initialImage: nil, start: nil)
                return
            }
        }
        // Probe the issue's length in the background, then open with the full page list.
        let hint = comic.remotePageHint
        openingTask = Task { [weak self] in
            let pages = await RemotePageProber.probePages(template: template, pad: pad, hint: hint)
            guard !Task.isCancelled, let self, self.openSeq == seq else { return }
            if pages.isEmpty {
                self.failedName = comic.title; self.failedURL = comic.url
                self.current = nil; self.finishOpening()
            } else {
                self.beginComic(items: pages, folder: nil, comicKey: key,
                                legacyStateURLs: [], initialImage: nil, start: nil)
            }
        }
    }

    /// Open a web comic descriptor: parse its page URLs and read them straight from the web via
    /// `RemotePageCache` (in-memory only). The descriptor is the only thing on disk.
    private func openWebComic(_ file: URL, startIndex: Int?) {
        let pages = WebComic.load(file)?.pages ?? []
        guard !pages.isEmpty else {
            failedName = file.lastPathComponent; failedURL = file; current = nil; finishOpening(); return
        }
        remoteMode = true
        beginComic(items: pages, folder: nil, comicKey: CentralStore.key(for: file),
                   legacyStateURLs: [], initialImage: nil, start: startIndex)
    }

    /// Open an archive by *streaming*: list its pages, extract only the priority set (first page,
    /// resume point, chapters) so the reader shows immediately, then fill the rest in the
    /// background. Falls back to a full up-front extract when the archive can't be streamed
    /// (no `7zz`, no pages listed, or a solid/RAR archive whose priority entries didn't extract).
    private func openArchive(_ archive: URL, startIndex: Int? = nil) {
        // `isOpening` (set in `open`) drives the reader's loading spinner during extraction.
        openingTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let plan = Self.planStreamedArchive(archive, startIndex: startIndex) else {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.openArchiveFully(archive, startIndex: startIndex)
                }
                return
            }
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: plan.dir)
                return
            }
            await MainActor.run {
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: plan.dir)
                    return
                }
                self.tempDirs.append(plan.dir)
                let items = plan.pages.map(\.url)
                let streamer = ArchiveStreamer(archive: archive, dir: plan.dir, pages: plan.pages)
                self.streamer = streamer
                self.cacheArchive(CentralStore.key(for: archive),
                                  OpenedArchive(dir: plan.dir, items: items, streamer: streamer))
                let base = archive.deletingPathExtension().lastPathComponent
                let legacy = archive.deletingLastPathComponent()
                    .appendingPathComponent(base + ".comicviewer.json")
                self.beginComic(items: items, folder: plan.dir,
                                comicKey: CentralStore.key(for: archive),
                                legacyStateURLs: [legacy], initialImage: nil, start: startIndex)
                Task { await streamer.startBackgroundFill() }
            }
        }
    }

    /// Off-main planning for a streamed open: list the archive, choose priority pages, and extract
    /// them. Returns the temp dir + ordered pages on success, or nil to fall back to a full extract.
    private nonisolated static func planStreamedArchive(
        _ archive: URL, startIndex: Int?
    ) -> (dir: URL, pages: [(url: URL, entry: String)])? {
        guard let listing = ArchiveExtractor.list(archive) else { return nil }
        // Only stream ZIP-family archives: `7zz` can seek to any entry cheaply. RAR/7z/solid
        // archives are slow or unsupported per-entry (some list fine but extract 0-byte stubs),
        // so hand them to the full-extract path — same behaviour as before streaming existed.
        guard listing.type.caseInsensitiveCompare("zip") == .orderedSame else { return nil }
        let entries = listing.entries
        let imageEntries = entries
            .filter { SupportedTypes.extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !imageEntries.isEmpty else { return nil }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicViewer-\(UUID().uuidString)", isDirectory: true)
        let pages = imageEntries.map { (url: dir.appendingPathComponent($0).standardizedFileURL, entry: $0) }
        // Priority: ComicInfo.xml (so named chapters resolve), first page, resume page + neighbour,
        // and every manual chapter. ComicInfo-derived chapters are added after it's parsed below.
        let state = CentralStore.loadState(forKey: CentralStore.key(for: archive))
        var priority: [String] = [pages[0].entry]
        if let comicInfo = entries.first(where: {
            ($0 as NSString).lastPathComponent.caseInsensitiveCompare(ComicInfo.fileName) == .orderedSame
        }) { priority.append(comicInfo) }

        // State now stores the archive-relative entry path. Fall back to a unique basename for
        // older state files created before relative-path persistence was introduced.
        func entry(forStoredKey key: String) -> String? {
            if imageEntries.contains(key) { return key }
            let matches = imageEntries.filter { ($0 as NSString).lastPathComponent == key }
            return matches.count == 1 ? matches[0] : nil
        }

        // The page the reader will land on (explicit index wins over the saved resume point).
        let startIdx = startIndex ?? state?.lastPage.flatMap { last in
            entry(forStoredKey: last).flatMap { entry in imageEntries.firstIndex(of: entry) }
        } ?? 0
        for i in [startIdx, startIdx + 1] where imageEntries.indices.contains(i) {
            priority.append(imageEntries[i])
        }
        for chapter in state?.chapters ?? [] {
            if let entry = entry(forStoredKey: chapter) { priority.append(entry) }
        }

        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        ArchiveExtractor.extractEntries(archive, priority, into: dir)

        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }

        // Named-chapter (ComicInfo bookmark) pages, now that ComicInfo.xml is on disk.
        if let info = ComicInfo.load(fromFolder: dir) {
            let bookmarkEntries = info.bookmarks
                .filter { imageEntries.indices.contains($0.imageIndex) }
                .map { imageEntries[$0.imageIndex] }
            ArchiveExtractor.extractEntries(archive, bookmarkEntries, into: dir)
        }

        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }

        // The reader immediately decodes the start page and probes page 0 for orientation; if
        // either didn't materialise with real bytes (a RAR whose method 7zz can list but not
        // decompress leaves 0-byte stubs), bail out to a full extract that can read it.
        guard ArchiveExtractor.fileSize(pages[0].url) > 0,
              ArchiveExtractor.fileSize(pages[startIdx].url) > 0 else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        return (dir, pages)
    }

    /// Extract an archive fully off the main thread, then open the temp dir as a comic. State
    /// (chapters + resume) is stored beside the archive so it survives the temp dir. The fallback
    /// path when an archive can't be streamed page-by-page.
    private func openArchiveFully(_ archive: URL, startIndex: Int? = nil) {
        openingTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let dir = ArchiveExtractor.extract(archive)
            guard !Task.isCancelled else {
                if let dir { try? FileManager.default.removeItem(at: dir) }
                return
            }
            await MainActor.run {
                guard !Task.isCancelled else {
                    if let dir { try? FileManager.default.removeItem(at: dir) }
                    return
                }
                guard let dir else {
                    self.failedName = archive.lastPathComponent
                    self.failedURL = archive
                    self.current = nil
                    self.finishOpening()
                    return
                }
                self.tempDirs.append(dir)
                let images = AppModel.scanRecursive(dir)
                guard !images.isEmpty else {
                    self.failedName = archive.lastPathComponent
                    self.failedURL = archive
                    self.current = nil
                    self.finishOpening()
                    return
                }
                // Key state by the archive path (stable across temp dirs); migrate an old
                // sidecar that used to live beside the archive.
                let base = archive.deletingPathExtension().lastPathComponent
                let legacy = archive.deletingLastPathComponent()
                    .appendingPathComponent(base + ".comicviewer.json")
                self.cacheArchive(CentralStore.key(for: archive),
                                  OpenedArchive(dir: dir, items: images, streamer: nil))
                self.beginComic(items: images, folder: dir,
                                comicKey: CentralStore.key(for: archive),
                                legacyStateURLs: [legacy], initialImage: nil, start: startIndex)
            }
        }
    }

    /// Remove temp extraction dirs (called on quit).
    func cleanupTempDirs() {
        openingTask?.cancel()
        openingTask = nil
        loadTask?.cancel()
        loadTask = nil
        orientationProbeTask?.cancel()
        orientationProbeTask = nil
        saveTask?.cancel()
        saveTask = nil
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs.removeAll()
        openedArchives.removeAll()
        archiveOrder.removeAll()
    }

    /// Remember an opened archive's extraction, mark it most-recently-used, and evict the oldest
    /// cached archives (deleting their temp dirs) so session disk use stays bounded. The currently
    /// open comic is never evicted.
    private func cacheArchive(_ key: String, _ opened: OpenedArchive) {
        openedArchives[key] = opened
        touchArchive(key)
        while archiveOrder.count > maxCachedArchives,
              let victim = archiveOrder.first(where: { $0 != currentArchiveKey }) {
            archiveOrder.removeAll { $0 == victim }
            if let old = openedArchives.removeValue(forKey: victim) {
                try? FileManager.default.removeItem(at: old.dir)
                tempDirs.removeAll { $0 == old.dir }
            }
        }
    }

    private func touchArchive(_ key: String) {
        archiveOrder.removeAll { $0 == key }
        archiveOrder.append(key)
    }

    /// Load a folder as a comic. If `initialImage` is given, start there (unless it's the
    /// first page and a resume point exists); otherwise resume at the last-read page.
    private func openFolder(_ dir: URL, initialImage: URL?, startIndex: Int? = nil) {
        // Direct images; if a container folder has none, fall back to a recursive scan
        // (e.g. opening a folder whose pages live in a subfolder).
        var scanned = Self.scan(dir)
        if scanned.isEmpty { scanned = Self.scanRecursive(dir) }
        guard !scanned.isEmpty else { finishOpening(); return }
        let legacy = [dir.appendingPathComponent(Self.stateFileName),
                      dir.appendingPathComponent(Self.legacyFileName)]
        beginComic(items: scanned, folder: dir,
                   comicKey: CentralStore.key(for: dir),
                   legacyStateURLs: legacy, initialImage: initialImage, start: startIndex)
    }

    /// Shared setup used by folder, archive and multi-file opens. `comicKey` is the canonical
    /// path used to key central state (nil disables persistence, e.g. ad-hoc multi-file opens);
    /// `legacyStateURLs` are old in-folder sidecars to migrate + retire on first load.
    func beginComic(items newItems: [URL], folder newFolder: URL?, comicKey newKey: String?,
                    legacyStateURLs newLegacy: [URL] = [],
                    initialImage: URL? = nil, start explicitStart: Int? = nil) {
        items = newItems
        folder = newFolder
        comicKey = newKey
        legacyStateURLs = newLegacy
        stateURL = newKey.map { CentralStore.stateURL(for: $0) }
        // Content-aware rotation default: are the pages landscape-native? (probe the first page)
        if let first = items.first, first.isFileURL, let info = ImageLoader.probe(first) {
            pagesLandscape = !info.isPortrait
        } else {
            pagesLandscape = true
        }
        loadState()

        var start = explicitStart ?? 0
        if let initialImage, let i = items.firstIndex(of: initialImage) {
            start = i
            // Opened the first page ⇒ treat as "open the comic" and resume if we can.
            if i == 0, let r = resumeIndex(), r != 0 {
                start = r
                transientMessage = "Resumed — \(r + 1) / \(items.count)"
            }
        } else if explicitStart == nil, let r = resumeIndex() {
            start = r
            if r != 0 { transientMessage = "Resumed — \(r + 1) / \(items.count)" }
        }
        setIndex(min(max(start, 0), items.count - 1))
    }

    /// Clear the opening/loading state once the first page is ready or the open failed.
    private func finishOpening() {
        isOpening = false
        openingName = nil
        openingTask = nil
    }

    private func resumeIndex() -> Int? {
        guard let lastPage else { return nil }
        return items.firstIndex { pageKey(for: $0) == lastPage }
    }

    // MARK: Navigation (wrapping)

    func next() { move(spreadEnabled ? 2 : 1) }
    func prev() { move(spreadEnabled ? -2 : -1) }
    func first() { jump(to: 0) }
    func last() { jump(to: items.count - 1) }

    /// Toggle two-page spread. Returns a HUD message.
    @discardableResult
    func toggleSpread() -> String {
        spreadEnabled.toggle()
        if !spreadEnabled {
            secondary = nil
        } else if index % 2 == 1 {
            // Keep the current reading position as the resume point even though the visible
            // spread starts on the preceding page. setIndex() is deliberately not used here
            // because it would replace the resume key with the pair's first page.
            let resumeKey = pageKey(for: items[index])
            index -= 1
            lastPage = resumeKey
            scheduleSaveState()
        }
        reload()
        return spreadEnabled ? "Two-page spread" : "Single page"
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let target = index + delta
        guard items.indices.contains(target) else { return }
        jump(to: target)
    }

    private func jump(to i: Int) {
        guard items.indices.contains(i) else { return }
        setIndex(i)
    }

    /// Set the index, normalizing spread mode to stable page pairs, remember it as the resume
    /// point (debounced save), and load.
    private func setIndex(_ requested: Int) {
        guard items.indices.contains(requested) else { return }

        let i = spreadEnabled ? requested - (requested % 2) : requested
        guard items.indices.contains(i) else { return }

        index = i
        lastPage = pageKey(for: items[i])
        scheduleSaveState()
        reload()
    }

    // MARK: Loading

    private func reload() {
        guard items.indices.contains(index) else {
            current = nil
            secondary = nil
            return
        }

        loadTask?.cancel()
        loadToken += 1
        let token = loadToken
        let url = items[index]
        let secondURL = (spreadEnabled && items.indices.contains(index + 1)) ? items[index + 1] : nil
        let maxPixel = Self.displayMaxPixel()
        let remote = remoteMode
        let streamer = streamer

        loadTask = Task { [weak self] in
            guard let self else { return }

            if remote {
                // Remote page loads are independent and the cache is responsible for concurrency,
                // so decode both pages of a spread in parallel. Local archive extraction remains
                // sequential to avoid concurrent per-entry extraction against one streamer.
                async let firstImage = loadPage(url, remote: true, streamer: streamer, maxPixel: maxPixel)
                async let secondImage = loadOptionalPage(secondURL, remote: true, streamer: streamer, maxPixel: maxPixel)
                let (img, img2) = await (firstImage, secondImage)

                guard !Task.isCancelled, token == loadToken else { return }
                current = img
                renderTick &+= 1
                secondary = img2
                failedName = (img == nil) ? url.lastPathComponent : nil
                failedURL = (img == nil) ? url : nil

                // Remote URLs are not probeable by ImageLoader. Probe the first page once so
                // portrait web comics get the same content-aware default as local comics. This is
                // intentionally tied to the open generation rather than the current page-load token,
                // so resuming at page 100 still probes page 1 without being invalidated by navigation.
                if manualRotate == nil, orientationProbeTask == nil, let firstURL = items.first {
                    startRemoteOrientationProbe(firstURL, openGeneration: openSeq)
                }

                finishOpening()
            } else {
                let img = await loadPage(url, remote: false, streamer: streamer, maxPixel: maxPixel)

                guard !Task.isCancelled, token == loadToken else { return }
                current = img
                renderTick &+= 1
                failedName = (img == nil) ? url.lastPathComponent : nil
                failedURL = (img == nil) ? url : nil
                finishOpening()

                if let secondURL {
                    let img2 = await loadPage(secondURL, remote: false, streamer: streamer, maxPixel: maxPixel)
                    guard !Task.isCancelled, token == loadToken else { return }
                    secondary = img2
                } else {
                    secondary = nil
                }
            }

            guard !Task.isCancelled, token == loadToken else { return }

            let ns = neighbors()
            if remote {
                await RemotePageCache.shared.prefetch(ns, maxPixel: maxPixel)
            } else {
                for n in ns {
                    guard !Task.isCancelled, token == loadToken else { return }
                    _ = await streamer?.ensure(n)
                }
                await cache.prefetch(ns, maxPixel: maxPixel)
            }
        }
    }

    private func startRemoteOrientationProbe(_ url: URL, openGeneration: Int) {
        orientationProbeTask?.cancel()
        orientationProbeTask = Task { [weak self] in
            guard let self else { return }
            guard let landscape = await Self.remotePageIsLandscape(url) else { return }
            guard !Task.isCancelled, self.openSeq == openGeneration, self.manualRotate == nil else { return }
            self.pagesLandscape = landscape
        }
    }

    private func loadOptionalPage(
        _ url: URL?, remote: Bool, streamer: ArchiveStreamer?, maxPixel: Int
    ) async -> DisplayImage? {
        guard let url else { return nil }
        return await loadPage(url, remote: remote, streamer: streamer, maxPixel: maxPixel)
    }

    /// Decode one page for the reader — from the web (`RemotePageCache`) for a web comic, or from
    /// the local disk cache (extracting the archive entry on demand first) otherwise.
    private func loadPage(_ url: URL, remote: Bool, streamer: ArchiveStreamer?, maxPixel: Int) async -> DisplayImage? {
        if remote { return await RemotePageCache.shared.image(for: url, maxPixel: maxPixel) }
        _ = await streamer?.ensure(url)
        return await cache.image(for: url, maxPixel: maxPixel)
    }

    private func neighbors() -> [URL] {
        guard !items.isEmpty else { return [] }

        if spreadEnabled {
            // A spread advances by two pages, so prefetch the next/previous spread rather than
            // spending the prefetch budget primarily on the already-visible facing page.
            var result: [URL] = []
            if index + 2 < items.count { result.append(items[index + 2]) }
            if index + 3 < items.count { result.append(items[index + 3]) }
            if index > 1 { result.append(items[index - 2]) }
            if index > 0 { result.append(items[index - 1]) }
            return result
        }

        var result: [URL] = []
        if index + 1 < items.count { result.append(items[index + 1]) }
        if index > 0 { result.append(items[index - 1]) }
        return result
    }

    // MARK: Page identity

    /// Stable identifier for persistence. Local pages use a relative path inside the comic folder;
    /// remote pages use their absolute URL. This avoids collisions such as `Chapter 1/page001.jpg`
    /// and `Chapter 2/page001.jpg`.
    private func pageKey(for url: URL) -> String {
        if url.isFileURL, let folder {
            let base = folder.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
        }
        return url.absoluteString
    }

    private func legacyPageKey(for basename: String, preferredIndex: Int? = nil) -> String? {
        let matches = items.enumerated().filter { $0.element.lastPathComponent == basename }
        if matches.count == 1, let match = matches.first {
            return pageKey(for: match.element)
        }
        if let preferredIndex, items.indices.contains(preferredIndex),
           items[preferredIndex].lastPathComponent == basename {
            return pageKey(for: items[preferredIndex])
        }
        return nil
    }

    // MARK: Chapters (bookmarks)

    var isCurrentChapter: Bool {
        guard index < items.count else { return false }
        return chapterFiles().contains(pageKey(for: items[index]))
    }

    /// Chapters in page order, for the Chapters menu. `page` is 1-based; `name` is the display
    /// label (bookmark name, else "Chapter N").
    var orderedChapters: [(page: Int, name: String)] {
        orderedChapterIndices().enumerated().map { ord, idx in
            (page: idx + 1, name: chapterLabel(at: idx, ordinal: ord + 1))
        }
    }

    /// Chapters with their page image URL + display name, for the thumbnail grid.
    var chapterEntries: [(ordinal: Int, page: Int, index: Int, url: URL, name: String)] {
        orderedChapterIndices().enumerated().map { ord, idx in
            (ordinal: ord + 1, page: idx + 1, index: idx, url: items[idx],
             name: chapterLabel(at: idx, ordinal: ord + 1))
        }
    }

    /// Jump to a specific item index (used by the chapter grid).
    func goTo(index: Int) { jump(to: index) }

    /// Jump to the first page of the chapter currently being read (book start if no chapters,
    /// or if you're already before the first bookmark).
    func firstOfChapter() {
        let idxs = orderedChapterIndices()
        jump(to: idxs.last { $0 <= index } ?? 0)
    }

    /// Fraction (0...1) read through the *current chapter* — the reader's bottom progress bar.
    /// With no chapters it falls back to progress through the whole comic.
    var readingProgress: Double {
        guard !items.isEmpty else { return 0 }
        let idxs = orderedChapterIndices()
        guard !idxs.isEmpty else { return Double(index + 1) / Double(items.count) }
        let start = idxs.last { $0 <= index } ?? 0
        let next = idxs.first { $0 > start } ?? items.count
        return Double(index - start + 1) / Double(max(1, next - start))
    }

    @discardableResult
    func toggleChapter() -> String {
        guard index < items.count else { return "No image" }
        let key = pageKey(for: items[index])
        if chapters.contains(key) {
            chapters.remove(key)
            saveState()
            return chapters.isEmpty ? "Chapter removed" : "Chapter removed  (\(chapters.count) left)"
        } else {
            chapters.insert(key)
            saveState()
            let ordered = orderedChapterIndices()
            let k = (ordered.firstIndex(of: index) ?? 0) + 1
            return "Chapter \(k) of \(ordered.count) set"
        }
    }

    @discardableResult func nextChapter() -> String { jumpChapter(forward: true) }
    @discardableResult func prevChapter() -> String { jumpChapter(forward: false) }

    func jumpToChapter(orderedIndex: Int) {
        let idxs = orderedChapterIndices()
        guard idxs.indices.contains(orderedIndex) else { return }
        jump(to: idxs[orderedIndex])
    }

    private func jumpChapter(forward: Bool) -> String {
        let idxs = orderedChapterIndices()
        guard !idxs.isEmpty else { return "No chapters" }
        let target = forward
            ? (idxs.first { $0 > index } ?? idxs.first!)
            : (idxs.last { $0 < index } ?? idxs.last!)
        jump(to: target)
        let k = (idxs.firstIndex(of: target) ?? 0) + 1
        return "Chapter \(k) of \(idxs.count)"
    }

    /// Read ComicInfo bookmarks from the comic's folder (or an archive's temp dir) and map them
    /// to page filenames present in `items`.
    private func loadBookmarkChapters() {
        bookmarkNames = [:]
        guard let folder, let info = ComicInfo.load(fromFolder: folder) else { return }
        for b in info.bookmarks where items.indices.contains(b.imageIndex) {
            bookmarkNames[pageKey(for: items[b.imageIndex])] = b.name
        }
    }

    /// All chapter page keys present in the comic: manual ∪ bookmarks.
    private func chapterFiles() -> Set<String> {
        let present = Set(items.map { pageKey(for: $0) })
        return chapters.union(bookmarkNames.keys).intersection(present)
    }

    private func orderedChapterIndices() -> [Int] {
        let files = chapterFiles()
        return items.indices.filter { files.contains(pageKey(for: items[$0])) }
    }

    /// Display name for the chapter at page index `i`: user name, else bookmark name, else "Chapter N".
    private func chapterLabel(at i: Int, ordinal: Int) -> String {
        let key = pageKey(for: items[i])
        return chapterNames[key] ?? bookmarkNames[key] ?? "Chapter \(ordinal)"
    }

    /// Rename the chapter at page index `i` (empty/blank clears the custom name → reverts to the
    /// bookmark name or "Chapter N"). No-op if that page isn't a chapter.
    func renameChapter(atIndex i: Int, to name: String) {
        guard items.indices.contains(i) else { return }
        let key = pageKey(for: items[i])
        guard chapterFiles().contains(key) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { chapterNames[key] = nil } else { chapterNames[key] = trimmed }
        saveState()
    }

    /// Remove the chapter marker (and any custom name) at page index `i`.
    func deleteChapter(atIndex i: Int) {
        guard items.indices.contains(i) else { return }
        let key = pageKey(for: items[i])
        chapters.remove(key)
        chapterNames[key] = nil
        saveState()
    }

    // MARK: Per-comic state persistence

    private func loadState() {
        chapters = []
        chapterNames = [:]
        lastPage = nil
        manualRotate = nil
        loadBookmarkChapters()
        guard let stateURL else { return }

        // Prefer the central file; otherwise migrate the first legacy in-folder sidecar found.
        var data = try? Data(contentsOf: stateURL)
        var migrated = false
        if data == nil {
            for legacy in legacyStateURLs {
                if let d = try? Data(contentsOf: legacy) { data = d; migrated = true; break }
            }
        }
        guard let data, let state = try? JSONDecoder().decode(ComicState.self, from: data) else { return }

        let present = Set(items.map { pageKey(for: $0) })
        chapters = Set(state.chapters.compactMap { key in
            if present.contains(key) { return key }
            return legacyPageKey(for: key)
        })
        // Custom names, remapped through the same present/legacy key resolution as chapters.
        chapterNames = [:]
        for (key, name) in state.chapterNames {
            if present.contains(key) { chapterNames[key] = name }
            else if let mapped = legacyPageKey(for: key) { chapterNames[mapped] = name }
        }

        if let saved = state.lastPage {
            lastPage = present.contains(saved) ? saved : legacyPageKey(for: saved, preferredIndex: state.lastIndex)
        } else {
            lastPage = nil
        }
        // `manualRotate` is intentionally NOT restored — the view (Horizontal/Vertical) always starts
        // from the global default; the R override is per-comic and ephemeral.
        if migrated {
            saveState()   // write central file, then retire every old in-folder sidecar
            for legacy in legacyStateURLs { try? FileManager.default.removeItem(at: legacy) }
        }
    }

    private func scheduleSaveState() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            self?.saveState()
        }
    }

    private func saveState() {
        guard let stateURL else { return }
        let ordered = orderedChapterIndices().map { pageKey(for: items[$0]) }
        // Only persist names for keys that are actually chapters (manual, not bookmark-derived).
        let names = chapterNames.filter { chapters.contains($0.key) }
        // `manualRotate` is an ephemeral per-comic view override — never persisted.
        let state = ComicState(version: 3, chapters: ordered, chapterNames: names, lastPage: lastPage,
                               lastIndex: lastPage == nil ? nil : index,
                               pageCount: lastPage == nil ? nil : items.count,
                               manualRotate: nil, path: comicKey)
        if state.chapters.isEmpty && state.lastPage == nil {
            try? FileManager.default.removeItem(at: stateURL)
            return
        }
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    // MARK: Helpers

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    nonisolated static func scan(_ folder: URL) -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return sorted(urls.filter(SupportedTypes.isSupported).map(\.standardizedFileURL))
    }

    nonisolated static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// All supported images anywhere under `dir` (archives may extract into a subfolder),
    /// ordered by full path so nested folders group naturally.
    nonisolated static func scanRecursive(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        if let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil,
                                 options: [.skipsHiddenFiles]) {
            for case let u as URL in e where SupportedTypes.isSupported(u) {
                out.append(u.standardizedFileURL)
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Probe a remote image's dimensions without fully decoding it. Used only for the initial
    /// content-aware rotation decision for web comics, because ImageLoader operates on local URLs.
    private nonisolated static func remotePageIsLandscape(_ url: URL) async -> Bool? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .returnCacheDataElseLoad

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            return nil
        }

        return width.doubleValue >= height.doubleValue
    }

    static func displayMaxPixel() -> Int {
        let longest = NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
            .max() ?? 2880
        return min(8192, Int(longest.rounded(.up)))
    }
}
