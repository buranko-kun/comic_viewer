import Foundation

/// Opens local folders, archives, web comics and remote catalog issues for a ReaderSession.
///
/// This keeps source-discovery and extraction orchestration separate from the reader's state and
/// navigation logic. ReaderSession remains the single owner of the currently-open comic.
@MainActor
final class SourceOpener {
    private let reader: ReaderSession
    private var openingTask: Task<Void, Never>?

    private static let stateFileName = ".comicviewer.json"
    private static let legacyFileName = ".landscape-chapters.json"

    init(reader: ReaderSession) {
        self.reader = reader
    }

// MARK: Opening

/// `startIndex` opens directly at that page (used by the chapter grid), overriding resume —
/// it survives an archive's asynchronous extraction, unlike a follow-up `goTo`.
func open(urls: [URL], startIndex: Int? = nil) {
    openingTask?.cancel()
    openingTask = nil
    let urls = urls.map(\.standardizedFileURL)
    guard let first = urls.first else { return }
    let openGeneration = reader.prepareForOpen(name: first.lastPathComponent, remote: false)

    // Open a web comic (.webcomic.json) → stream its remote page URLs; nothing on disk but the
    // descriptor. No extraction, no local files.
    if urls.count == 1, LibraryModel.isWebComic(first) {
        openWebComic(first, startIndex: startIndex)
        return
    }

    // Open an archive through the shared archive-session manager.
    if urls.count == 1, ArchiveExtractor.isArchive(first) {
        Task { [weak self] in
            guard let self else { return }
            guard self.reader.openGeneration == openGeneration else { return }

            if let cached = await ArchiveSessionManager.shared.session(for: first) {
                guard self.reader.openGeneration == openGeneration else { return }
                await ArchiveSessionManager.shared.setCurrent(first)
                guard self.reader.openGeneration == openGeneration else { return }
                self.reopenArchive(first, cached: cached, startIndex: startIndex)
            } else {
                guard self.reader.openGeneration == openGeneration else { return }
                self.openArchive(first, startIndex: startIndex)
            }
        }
        return
    }
    Task { await ArchiveSessionManager.shared.setCurrent(nil) }

    // Open a folder → resume.
    if urls.count == 1, isDirectory(first) {
        openFolder(first, initialImage: nil, startIndex: startIndex)
        return
    }

    let supported = urls.filter(SupportedTypes.isSupported)
    guard !supported.isEmpty else { reader.finishOpening(); return }

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
private func reopenArchive(_ archive: URL, cached: ArchiveSessionManager.Session, startIndex: Int?) {
    reader.setStreamer(cached.streamer)
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
    let seq = reader.prepareForOpen(name: comic.title, remote: true)
    Task { await ArchiveSessionManager.shared.setCurrent(nil) }
    let key = CentralStore.key(for: comic.url)

    if let pages = comic.remotePages, !pages.isEmpty {
        beginComic(items: pages, folder: nil, comicKey: key, legacyStateURLs: [], initialImage: nil, start: nil)
        return
    }
    guard let template = comic.remotePageTemplate else {
        reader.setFailure(name: comic.title, url: comic.url); return
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
        guard !Task.isCancelled, let self, self.reader.openGeneration == seq else { return }
        if pages.isEmpty {
            self.reader.setFailure(name: comic.title, url: comic.url)
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
        reader.setFailure(name: file.lastPathComponent, url: file); return
    }
    reader.setRemoteMode(true)
    Task { await ArchiveSessionManager.shared.setCurrent(nil) }
    beginComic(items: pages, folder: nil, comicKey: CentralStore.key(for: file),
               legacyStateURLs: [], initialImage: nil, start: startIndex)
}

/// Open an archive by *streaming*: list its pages, extract only the priority set (first page,
/// resume point, chapters) so the reader shows immediately, then fill the rest in the
/// background. Falls back to a full up-front extract when the archive can't be streamed
/// (no `7zz`, no pages listed, or a solid/RAR archive whose priority entries didn't extract).
private func openArchive(_ archive: URL, startIndex: Int? = nil) {
    let seq = reader.openGeneration
    openingTask = Task.detached(priority: .userInitiated) { [weak self] in
        guard let self else { return }

        guard let plan = Self.planStreamedArchive(archive, startIndex: startIndex) else {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.openArchiveFully(archive, startIndex: startIndex)
            }
            return
        }

        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: plan.dir)
            return
        }

        let items = plan.pages.map(\.url)
        let streamer = ArchiveStreamer(archive: archive, dir: plan.dir, pages: plan.pages)
        let session = ArchiveSessionManager.Session(
            archive: archive,
            dir: plan.dir,
            items: items,
            streamer: streamer
        )

        await streamer.startBackgroundFill()
        await ArchiveSessionManager.shared.register(session, makeCurrent: true)
        guard !Task.isCancelled else { return }

        await MainActor.run {
            guard self.reader.openGeneration == seq else { return }
            self.reader.setStreamer(streamer)
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
    let seq = reader.openGeneration
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
                self.reader.setFailure(name: archive.lastPathComponent, url: archive)
                return
            }

            let images = AppModel.scanRecursive(dir)
            guard !images.isEmpty else {
                try? FileManager.default.removeItem(at: dir)
                self.reader.setFailure(name: archive.lastPathComponent, url: archive)
                return
            }

            let base = archive.deletingPathExtension().lastPathComponent
            let legacy = archive.deletingLastPathComponent()
                .appendingPathComponent(base + ".comicviewer.json")
            let session = ArchiveSessionManager.Session(
                archive: archive,
                dir: dir,
                items: images,
                streamer: nil
            )

            Task { @MainActor [weak self] in
                guard let self else { return }
                await ArchiveSessionManager.shared.register(session, makeCurrent: true)
                guard self.reader.openGeneration == seq else { return }
                self.reader.setStreamer(nil)
                self.beginComic(items: images, folder: dir,
                                comicKey: CentralStore.key(for: archive),
                                legacyStateURLs: [legacy], initialImage: nil, start: startIndex)
            }
        }
    }
}

/// Compatibility bridge for the application-level opener.
private func beginComic(
    items newItems: [URL],
    folder newFolder: URL?,
    comicKey newKey: String?,
    legacyStateURLs newLegacy: [URL] = [],
    initialImage: URL? = nil,
    start explicitStart: Int? = nil
) {
    reader.beginComic(
        items: newItems,
        folder: newFolder,
        comicKey: newKey,
        legacyStateURLs: newLegacy,
        initialImage: initialImage,
        start: explicitStart
    )
}

/// Load a folder as a comic. If `initialImage` is given, start there (unless it's the
/// first page and a resume point exists); otherwise resume at the last-read page.
private func openFolder(_ dir: URL, initialImage: URL?, startIndex: Int? = nil) {
    // Direct images; if a container folder has none, fall back to a recursive scan
    // (e.g. opening a folder whose pages live in a subfolder).
    var scanned = Self.scan(dir)
    if scanned.isEmpty { scanned = Self.scanRecursive(dir) }
    guard !scanned.isEmpty else { reader.finishOpening(); return }
    let legacy = [dir.appendingPathComponent(Self.stateFileName),
                  dir.appendingPathComponent(Self.legacyFileName)]
    beginComic(items: scanned, folder: dir,
               comicKey: CentralStore.key(for: dir),
               legacyStateURLs: legacy, initialImage: initialImage, start: startIndex)
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

    /// Cancel only the opener's in-flight work. Session cleanup remains coordinated by AppModel.
    func cancel() {
        openingTask?.cancel()
        openingTask = nil
    }
}
