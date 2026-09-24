import Foundation

/// Routes a source to the appropriate opener and keeps generic local-source handling separate
/// from archive extraction and remote opening.
@MainActor
final class SourceOpener {
    private let reader: ReaderSession
    private let archiveOpener: ArchiveOpener
    private let remoteOpener: RemoteOpener

    private static let stateFileName = ".comicviewer.json"
    private static let legacyFileName = ".landscape-chapters.json"

    init(reader: ReaderSession) {
        self.reader = reader
        self.archiveOpener = ArchiveOpener(reader: reader)
        self.remoteOpener = RemoteOpener(reader: reader)
    }

    // MARK: Opening

    /// `startIndex` opens directly at that page (used by the chapter grid), overriding resume.
    func open(urls: [URL], startIndex: Int? = nil) {
        archiveOpener.cancel()
        remoteOpener.cancel()

        let urls = urls.map(\.standardizedFileURL)
        guard let first = urls.first else { return }

        if urls.count == 1, LibraryModel.isWebComic(first) {
            remoteOpener.openWebComic(first, startIndex: startIndex)
            return
        }

        let generation = reader.prepareForOpen(
            name: first.lastPathComponent,
            remote: false
        )

        if urls.count == 1, ArchiveExtractor.isArchive(first) {
            guard reader.openGeneration == generation else { return }
            archiveOpener.open(first, startIndex: startIndex)
            return
        }

        Task { await ArchiveSessionManager.shared.setCurrent(nil) }

        if urls.count == 1, isDirectory(first) {
            openFolder(
                first,
                initialImage: nil,
                startIndex: startIndex
            )
            return
        }

        let supported = urls.filter(SupportedTypes.isSupported)
        guard !supported.isEmpty else {
            reader.finishOpening()
            return
        }

        if supported.count == 1 {
            openFolder(
                supported[0].deletingLastPathComponent(),
                initialImage: supported[0]
            )
        } else {
            // An explicit multi-file selection: use exactly those, with no folder scan / resume.
            reader.beginComic(
                items: FileScanner.sorted(supported),
                folder: supported.first?.deletingLastPathComponent(),
                comicKey: nil,
                legacyStateURLs: [],
                initialImage: nil,
                start: 0
            )
        }
    }

    /// Open a library remote issue.
    func openRemote(_ comic: Comic) {
        archiveOpener.cancel()
        remoteOpener.openRemote(comic)
    }

    // MARK: Local sources

    /// Load a folder as a comic. If `initialImage` is given, start there unless it is the first
    /// page and a resume point exists.
    private func openFolder(
        _ dir: URL,
        initialImage: URL?,
        startIndex: Int? = nil
    ) {
        var scanned = FileScanner.scan(dir)
        if scanned.isEmpty {
            scanned = FileScanner.scanRecursive(dir)
        }

        guard !scanned.isEmpty else {
            reader.finishOpening()
            return
        }

        let legacy = [
            dir.appendingPathComponent(Self.stateFileName),
            dir.appendingPathComponent(Self.legacyFileName)
        ]

        reader.beginComic(
            items: scanned,
            folder: dir,
            comicKey: CentralStore.key(for: dir),
            legacyStateURLs: legacy,
            initialImage: initialImage,
            start: startIndex
        )
    }

    // MARK: Helpers

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Cancel opener-owned work. Each specialized opener owns its own asynchronous work.
    func cancel() {
        archiveOpener.cancel()
        remoteOpener.cancel()
    }
}
