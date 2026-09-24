import Foundation

/// Opens local folders, archives, web comics and remote catalog issues for a ReaderSession.
///
/// This keeps source-discovery and extraction orchestration separate from the reader's state and
/// navigation logic. ReaderSession remains the single owner of the currently-open comic.
@MainActor
final class SourceOpener {
    private let reader: ReaderSession
    private let archiveOpener: ArchiveOpener
    private var openingTask: Task<Void, Never>?

    private static let stateFileName = ".comicviewer.json"
    private static let legacyFileName = ".landscape-chapters.json"

    init(reader: ReaderSession) {
        self.reader = reader
        self.archiveOpener = ArchiveOpener(reader: reader)
    }

    // MARK: Opening

/// `startIndex` opens directly at that page (used by the chapter grid), overriding resume —
/// it survives an archive's asynchronous extraction, unlike a follow-up `goTo`.
func open(urls: [URL], startIndex: Int? = nil) {
    openingTask?.cancel()
    openingTask = nil
    let urls = urls.map(\.standardizedFileURL)
    guard let first = urls.first else { return }
    reader.prepareForOpen(name: first.lastPathComponent, remote: false)

    // Open a web comic (.webcomic.json) → stream its remote page URLs; nothing on disk but the
    // descriptor. No extraction, no local files.
    if urls.count == 1, LibraryModel.isWebComic(first) {
        openWebComic(first, startIndex: startIndex)
        return
    }

    // Open an archive through the shared archive-session manager.
    if urls.count == 1, ArchiveExtractor.isArchive(first) {
        archiveOpener.open(first, startIndex: startIndex)
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
        beginComic(items: FileScanner.sorted(supported),
                   folder: supported.first?.deletingLastPathComponent(),
                   comicKey: nil, legacyStateURLs: [], start: 0)
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
    var scanned = FileScanner.scan(dir)
    if scanned.isEmpty { scanned = FileScanner.scanRecursive(dir) }
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

    /// Cancel only the opener's in-flight work. Session cleanup remains coordinated by AppModel.
    func cancel() {
        openingTask?.cancel()
        openingTask = nil
        archiveOpener.cancel()
    }
}
