import Foundation

/// Streams pages out of a comic archive on demand instead of extracting the whole thing up front.
///
/// Opening a comic extracts only a *priority* set (first page, resume point, chapters) so the
/// reader can show something immediately — then this fills in the rest in the background. Any page
/// the reader jumps to before the background pass reaches it is extracted on demand (`ensure`),
/// with concurrent requests for the same entry coalesced. Extraction always writes into the same
/// temp `dir`, tree preserved, so a page's file path is just `dir` + its archive entry path.
///
/// Only ZIP/CBZ-style archives with cheap random access benefit; `AppModel` falls back to a full
/// extract when the priority set can't be produced (e.g. solid/RAR archives `7zz` can't seek into).
actor ArchiveStreamer {
    let archive: URL
    let dir: URL
    private let entryForURL: [URL: String]      // page file URL → archive-internal entry path
    private var inFlight: [String: Task<Bool, Never>] = [:]
    private var fullTask: Task<Void, Never>?

    init(archive: URL, dir: URL, pages: [(url: URL, entry: String)]) {
        self.archive = archive
        self.dir = dir
        self.entryForURL = Dictionary(pages.map { ($0.url, $0.entry) }, uniquingKeysWith: { a, _ in a })
    }

    /// Make sure the file backing `url` exists, extracting its single entry if needed. Cheap when
    /// the page is already on disk (a `stat`), and coalesces overlapping requests for one entry.
    func ensure(_ url: URL) async -> Bool {
        if ArchiveExtractor.fileSize(url) > 0 { return true }
        guard let entry = entryForURL[url] else { return false }
        if let task = inFlight[entry] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { [archive, dir] in
            ArchiveExtractor.extractEntries(archive, [entry], into: dir)
            return ArchiveExtractor.fileSize(url) > 0
        }
        inFlight[entry] = task
        let ok = await task.value
        inFlight[entry] = nil
        return ok
    }

    /// Start filling the temp dir with the archive's remaining pages in the background (idempotent).
    func startBackgroundFill() {
        guard fullTask == nil else { return }
        fullTask = Task.detached(priority: .utility) { [archive, dir] in
            ArchiveExtractor.extractAllInto(archive, dir: dir)
        }
    }
}
