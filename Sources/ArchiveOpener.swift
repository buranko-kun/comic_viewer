import Foundation

/// Handles archive-specific opening, including cached sessions, streamed ZIP opens and
/// full-extraction fallbacks.
///
/// Keeping this orchestration separate from SourceOpener makes the generic source router
/// responsible only for deciding what kind of source it received.
@MainActor
final class ArchiveOpener {
    private let reader: ReaderSession
    private var openingTask: Task<Void, Never>?

    init(reader: ReaderSession) {
        self.reader = reader
    }

    func open(_ archive: URL, startIndex: Int? = nil) {
        openingTask?.cancel()
        openingTask = Task { [weak self] in
            guard let self else { return }
            let generation = self.reader.openGeneration
            guard self.reader.openGeneration == generation else { return }

            if let cached = await ArchiveSessionManager.shared.session(for: archive) {
                guard !Task.isCancelled, self.reader.openGeneration == generation else { return }
                await ArchiveSessionManager.shared.setCurrent(archive)
                guard !Task.isCancelled, self.reader.openGeneration == generation else { return }
                self.reopen(archive, cached: cached, startIndex: startIndex)
            } else {
                guard !Task.isCancelled, self.reader.openGeneration == generation else { return }
                self.openUncached(archive, startIndex: startIndex)
            }
        }
    }

    func cancel() {
        openingTask?.cancel()
        openingTask = nil
    }

    /// Re-open an archive already extracted/streamed this session. No extraction is needed.
    private func reopen(
        _ archive: URL,
        cached: ArchiveSessionManager.Session,
        startIndex: Int?
    ) {
        reader.setStreamer(cached.streamer)
        let base = archive.deletingPathExtension().lastPathComponent
        let legacy = archive.deletingLastPathComponent()
            .appendingPathComponent(base + ".comicviewer.json")
        reader.beginComic(
            items: cached.items,
            folder: cached.dir,
            comicKey: CentralStore.key(for: archive),
            legacyStateURLs: [legacy],
            initialImage: nil,
            start: startIndex
        )
    }

    private func openUncached(_ archive: URL, startIndex: Int?) {
        let generation = reader.openGeneration
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
            let streamer = ArchiveStreamer(
                archive: archive,
                dir: plan.dir,
                pages: plan.pages
            )
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
                guard self.reader.openGeneration == generation else { return }
                self.reader.setStreamer(streamer)
                let base = archive.deletingPathExtension().lastPathComponent
                let legacy = archive.deletingLastPathComponent()
                    .appendingPathComponent(base + ".comicviewer.json")
                self.reader.beginComic(
                    items: items,
                    folder: plan.dir,
                    comicKey: CentralStore.key(for: archive),
                    legacyStateURLs: [legacy],
                    initialImage: nil,
                    start: startIndex
                )
            }
        }
    }

    /// Off-main planning for a streamed open: list the archive, choose priority pages, and
    /// extract them. Returns the temp dir + ordered pages on success, or nil to fall back to
    /// a full extract.
    private nonisolated static func planStreamedArchive(
        _ archive: URL,
        startIndex: Int?
    ) -> (dir: URL, pages: [(url: URL, entry: String)])? {
        guard let listing = ArchiveExtractor.list(archive) else { return nil }

        // Only stream ZIP-family archives: 7zz can seek to any entry cheaply. RAR/7z/solid
        // archives use the full-extract path.
        guard listing.type.caseInsensitiveCompare("zip") == .orderedSame else { return nil }

        let entries = listing.entries
        let imageEntries = entries
            .filter {
                SupportedTypes.extensions.contains(
                    ($0 as NSString).pathExtension.lowercased()
                )
            }
            .sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }

        guard !imageEntries.isEmpty else { return nil }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicViewer-\(UUID().uuidString)", isDirectory: true)
        let pages = imageEntries.map {
            (url: dir.appendingPathComponent($0).standardizedFileURL, entry: $0)
        }

        // Priority: first page, resume page + neighbour, manual chapters, and ComicInfo.xml.
        let state = CentralStore.loadState(forKey: CentralStore.key(for: archive))
        var priority: [String] = [pages[0].entry]

        if let comicInfo = entries.first(where: {
            ($0 as NSString).lastPathComponent
                .caseInsensitiveCompare(ComicInfo.fileName) == .orderedSame
        }) {
            priority.append(comicInfo)
        }

        func entry(forStoredKey key: String) -> String? {
            if imageEntries.contains(key) { return key }
            let matches = imageEntries.filter {
                ($0 as NSString).lastPathComponent == key
            }
            return matches.count == 1 ? matches[0] : nil
        }

        let startIdx = startIndex ?? state?.lastPage.flatMap { last in
            entry(forStoredKey: last).flatMap {
                imageEntries.firstIndex(of: $0)
            }
        } ?? 0

        for i in [startIdx, startIdx + 1] where imageEntries.indices.contains(i) {
            priority.append(imageEntries[i])
        }

        for chapter in state?.chapters ?? [] {
            if let entry = entry(forStoredKey: chapter) {
                priority.append(entry)
            }
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

        guard ArchiveExtractor.fileSize(pages[0].url) > 0,
              ArchiveExtractor.fileSize(pages[startIdx].url) > 0 else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }

        return (dir, pages)
    }

    /// Full-extraction fallback for archives that cannot be safely streamed page-by-page.
    private func openArchiveFully(_ archive: URL, startIndex: Int?) {
        let generation = reader.openGeneration
        openingTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let dir = ArchiveExtractor.extract(archive)

            guard !Task.isCancelled else {
                if let dir {
                    try? FileManager.default.removeItem(at: dir)
                }
                return
            }

            await MainActor.run {
                guard !Task.isCancelled else {
                    if let dir {
                        try? FileManager.default.removeItem(at: dir)
                    }
                    return
                }

                guard let dir else {
                    self.reader.setFailure(
                        name: archive.lastPathComponent,
                        url: archive
                    )
                    return
                }

                let images = FileScanner.scanRecursive(dir)
                guard !images.isEmpty else {
                    try? FileManager.default.removeItem(at: dir)
                    self.reader.setFailure(
                        name: archive.lastPathComponent,
                        url: archive
                    )
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
                    await ArchiveSessionManager.shared.register(
                        session,
                        makeCurrent: true
                    )
                    guard self.reader.openGeneration == generation else { return }
                    self.reader.setStreamer(nil)
                    self.reader.beginComic(
                        items: images,
                        folder: dir,
                        comicKey: CentralStore.key(for: archive),
                        legacyStateURLs: [legacy],
                        initialImage: nil,
                        start: startIndex
                    )
                }
            }
        }
    }
}
