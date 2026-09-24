import Foundation

/// Routes a source to the appropriate opener and keeps generic local-source handling separate
/// from archive extraction and remote page discovery.
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

    /// `startIndex` opens directly at that page (used by the chapter grid), overriding resume.
    func open(urls: [URL], startIndex: Int? = nil) {
        openingTask?.cancel()
        openingTask = nil

        let urls = urls.map(\.standardizedFileURL)
        guard let first = urls.first else { return }

        if urls.count == 1, LibraryModel.isWebComic(first) {
            let generation = reader.prepareForOpen(
                name: first.lastPathComponent,
                remote: true
            )
            openWebComic(
                first,
                startIndex: startIndex,
                generation: generation
            )
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

    /// Open a library remote issue. A fixed page list is used when available; otherwise the
    /// issue's page template is probed and cached page count is reused on subsequent opens.
    func openRemote(_ comic: Comic) {
        openingTask?.cancel()
        openingTask = nil

        let generation = reader.prepareForOpen(
            name: comic.title,
            remote: true
        )
        Task { await ArchiveSessionManager.shared.setCurrent(nil) }

        let key = CentralStore.key(for: comic.url)

        if let pages = comic.remotePages, !pages.isEmpty {
            reader.beginComic(
                items: pages,
                folder: nil,
                comicKey: key,
                legacyStateURLs: [],
                initialImage: nil,
                start: nil
            )
            return
        }

        guard let template = comic.remotePageTemplate else {
            reader.setFailure(name: comic.title, url: comic.url)
            return
        }

        let pad = comic.remotePagePad

        func pageURL(_ n: Int) -> URL? {
            URL(string: template.replacingOccurrences(
                of: "{page}",
                with: String(format: "%0\(max(0, pad))d", n)
            ))
        }

        // Fast path: reuse the page count saved after the first successful read.
        if let state = CentralStore.loadState(forKey: key),
           let pageCount = state.pageCount,
           pageCount > 0 {
            let items = (1...pageCount).compactMap(pageURL)
            if !items.isEmpty {
                reader.beginComic(
                    items: items,
                    folder: nil,
                    comicKey: key,
                    legacyStateURLs: [],
                    initialImage: nil,
                    start: nil
                )
                return
            }
        }

        let hint = comic.remotePageHint
        openingTask = Task { [weak self] in
            let pages = await RemotePageProber.probePages(
                template: template,
                pad: pad,
                hint: hint
            )
            guard !Task.isCancelled,
                  let self,
                  self.reader.openGeneration == generation
            else {
                return
            }

            if pages.isEmpty {
                self.reader.setFailure(
                    name: comic.title,
                    url: comic.url
                )
            } else {
                self.reader.beginComic(
                    items: pages,
                    folder: nil,
                    comicKey: key,
                    legacyStateURLs: [],
                    initialImage: nil,
                    start: nil
                )
            }
        }
    }

    /// Open a web comic descriptor: parse its page URLs and read them from the web via
    /// ReaderPageSource's remote path. The descriptor is the only thing stored on disk.
    private func openWebComic(
        _ file: URL,
        startIndex: Int?,
        generation: Int
    ) {
        let pages = WebComic.load(file)?.pages ?? []
        guard !pages.isEmpty else {
            reader.setFailure(
                name: file.lastPathComponent,
                url: file
            )
            return
        }

        guard reader.openGeneration == generation else { return }
        Task { await ArchiveSessionManager.shared.setCurrent(nil) }

        reader.beginComic(
            items: pages,
            folder: nil,
            comicKey: CentralStore.key(for: file),
            legacyStateURLs: [],
            initialImage: nil,
            start: startIndex
        )
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

    /// Cancel opener-owned work. ArchiveOpener owns archive-specific cancellation separately.
    func cancel() {
        openingTask?.cancel()
        openingTask = nil
        archiveOpener.cancel()
    }
}
