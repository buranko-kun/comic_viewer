import Foundation

/// Handles remote reading sources: library issues and .webcomic.json descriptors.
///
/// Keeping remote discovery here leaves SourceOpener responsible only for routing a source to the
/// correct opener. RemotePageProber remains a standalone networking utility.
@MainActor
final class RemoteOpener {
    private let reader: ReaderSession
    private var openingTask: Task<Void, Never>?

    init(reader: ReaderSession) {
        self.reader = reader
    }

    /// Open a library remote issue. A fixed page list is used when available; otherwise the
    /// issue's page template is probed and the cached page count is reused on subsequent opens.
    func openRemote(_ comic: Comic, startIndex: Int? = nil) {
        cancel()

        let generation = reader.prepareForOpen(
            name: comic.title,
            remote: true
        )
        Task { await ArchiveSessionManager.shared.setCurrent(nil) }

        let key = CentralStore.key(for: comic.url)

        if let pages = comic.remotePages, !pages.isEmpty {
            ReaderPerformance.event("remote_open mode=fixed_pages pages=\(pages.count)")
            reader.beginComic(
                items: pages,
                folder: nil,
                comicKey: key,
                legacyStateURLs: [],
                initialImage: nil,
                start: startIndex
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
                ReaderPerformance.event("remote_open mode=cached_count pages=\(items.count)")
                reader.beginComic(
                    items: items,
                    folder: nil,
                    comicKey: key,
                    legacyStateURLs: [],
                    initialImage: nil,
                    start: startIndex
                )
                return
            }
        }

        let hint = comic.remotePageHint
        openingTask = Task { [weak self] in
            let startedAt = ReaderPerformance.now()
            let pages = await RemotePageProber.probePages(
                template: template,
                pad: pad,
                hint: hint
            )
            ReaderPerformance.metric(
                "remote_page_probe",
                milliseconds: ReaderPerformance.milliseconds(since: startedAt)
            )
            guard !Task.isCancelled,
                  let self,
                  self.reader.openGeneration == generation
            else {
                return
            }

            if pages.isEmpty {
                ReaderPerformance.event("remote_open probe_failed")
                self.reader.setFailure(
                    name: comic.title,
                    url: comic.url
                )
            } else {
                ReaderPerformance.event("remote_open mode=probed pages=\(pages.count)")
                self.reader.beginComic(
                    items: pages,
                    folder: nil,
                    comicKey: key,
                    legacyStateURLs: [],
                    initialImage: nil,
                    start: startIndex
                )
            }
        }
    }

    /// Open a .webcomic.json descriptor. Its page URLs are read from the web; the descriptor is
    /// the only source file stored on disk.
    func openWebComic(_ file: URL, startIndex: Int? = nil) {
        cancel()

        let generation = reader.prepareForOpen(
            name: file.lastPathComponent,
            remote: true
        )

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

    func cancel() {
        openingTask?.cancel()
        openingTask = nil
    }
}
