import Foundation

/// Streams pages out of a comic archive on demand instead of extracting the whole thing up front.
///
/// Opening a comic extracts only a *priority* set (first page, resume point, chapters) so the
/// reader can show something immediately. The remaining pages are filled in small background
/// batches, yielding between batches so an on-demand page request can take priority. Duplicate
/// requests for the same page coalesce, and all archive extraction is serialized through this actor
/// so background work never competes with an interactive extraction in another 7zz process.
///
/// Only ZIP/CBZ-style archives with cheap random access benefit; AppModel falls back to a full
/// extract when the priority set can't be produced (e.g. solid/RAR archives 7zz can't seek into).
actor ArchiveStreamer {
    let archive: URL
    let dir: URL
    private let entryForURL: [URL: String]
    private let backgroundEntries: [String]

    private var backgroundIndex = 0
    private var backgroundTask: Task<Void, Never>?
    private var interactiveTask: Task<Bool, Never>?
    private var interactiveEntry: String?

    private let backgroundBatchSize = 16

    init(archive: URL, dir: URL, pages: [(url: URL, entry: String)]) {
        self.archive = archive
        self.dir = dir
        self.entryForURL = Dictionary(
            pages.map { ($0.url, $0.entry) },
            uniquingKeysWith: { a, _ in a }
        )
        self.backgroundEntries = pages.map(\.entry)
    }

    /// Make sure the file backing a page URL exists.
    ///
    /// If background extraction is active, it is stopped and the current batch is allowed to
    /// finish before the interactive extraction starts. Requests for the same entry coalesce.
    /// Different interactive requests are serialized so there is never more than one 7zz process
    /// writing into this archive's temporary directory.
    func ensure(_ url: URL) async -> Bool {
        guard let entry = entryForURL[url] else { return false }

        while true {
            if ArchiveExtractor.fileSize(url) > 0 {
                return true
            }

            if let interactiveTask {
                if interactiveEntry == entry {
                    return await interactiveTask.value
                }

                await interactiveTask.value
                self.interactiveTask = nil
                self.interactiveEntry = nil
                continue
            }

            if let backgroundTask {
                backgroundTask.cancel()
                await backgroundTask.value
                self.backgroundTask = nil
                continue
            }

            let task = Task.detached(priority: .userInitiated) { [archive, dir] in
                ArchiveExtractor.extractEntries(archive, [entry], into: dir)
                return ArchiveExtractor.fileSize(url) > 0
            }

            interactiveEntry = entry
            interactiveTask = task
            let ok = await task.value
            interactiveTask = nil
            interactiveEntry = nil

            if backgroundIndex < backgroundEntries.count {
                startBackgroundFill()
            }

            ReaderPerformance.event(
                "archive_stream on_demand entry=\(entry) ok=\(ok)"
            )
            return ok
        }
    }

    /// Start filling the temp dir with the archive's remaining pages in small, restartable batches.
    /// Idempotent while a background worker is already active.
    func startBackgroundFill() {
        guard backgroundTask == nil, backgroundIndex < backgroundEntries.count else { return }

        backgroundTask = Task { [weak self] in
            await self?.runBackgroundFill()
        }
    }

    /// Wait until the current background batch sequence has completed.
    /// The library uses this when it needs a complete page set, such as chapter resolution.
    func finishBackgroundFill() async {
        guard let backgroundTask else { return }
        await backgroundTask.value
    }

    private func runBackgroundFill() async {
        while backgroundIndex < backgroundEntries.count {
            guard !Task.isCancelled else { return }

            let end = min(
                backgroundIndex + backgroundBatchSize,
                backgroundEntries.count
            )
            let batch = Array(backgroundEntries[backgroundIndex..<end])
            backgroundIndex = end

            let ok = await Task.detached(priority: .utility) { [archive, dir] in
                ArchiveExtractor.extractEntries(
                    archive,
                    batch,
                    into: dir
                )
            }.value

            ReaderPerformance.event(
                "archive_stream background_batch=\(batch.count) ok=\(ok)"
            )

            // Give interactive ensure calls a chance to stop us between 7zz invocations.
            await Task.yield()
        }

        backgroundTask = nil
    }

    /// Cancel all extraction work owned by this stream.
    ///
    /// Session eviction calls this before deleting the backing directory so no detached task can
    /// continue writing into a temp directory that no longer belongs to a live session.
    func cancel() async {
        let background = backgroundTask
        let interactive = interactiveTask

        backgroundTask?.cancel()
        interactiveTask?.cancel()
        backgroundTask = nil
        interactiveTask = nil
        interactiveEntry = nil

        // ArchiveExtractor uses synchronous 7zz calls and may not observe task cancellation while
        // inside a process. Wait for every task so the backing directory is safe to delete.
        if let background {
            await background.value
        }
        if let interactive {
            _ = await interactive.value
        }
    }
}
