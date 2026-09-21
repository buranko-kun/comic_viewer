import Foundation

/// Resolves a comic (folder or archive) to its ordered page images for the server. Folders read
/// directly. Archives are **streamed page-by-page**: the entry list is read once (`7zz l`, no
/// extraction) and each page is extracted on demand the first time it's requested — so opening a
/// 2 GB omnibus on the phone no longer unpacks the whole thing, only the pages you actually view.
/// Archives that can't be seeked into per-entry (solid/RAR that `7zz` can't decode singly) fall back
/// to a one-time full extraction. Thread-safe (server handlers run off the main actor).
final class PageIndex {
    static let shared = PageIndex()

    private let lock = NSLock()

    /// Per-archive streaming state: the ordered image entry paths, the temp dir pages extract into,
    /// and whether we've had to fall back to a full extraction.
    private final class ArchiveState {
        let entries: [String]        // ordered image entry paths inside the archive
        let dir: URL                 // temp dir; a page's file is dir + its entry path
        var fullyExtracted = false
        init(entries: [String], dir: URL) { self.entries = entries; self.dir = dir }
    }
    private var archives: [String: ArchiveState] = [:]   // archive path → state

    // MARK: - Page listing

    /// The number of pages in a comic — without extracting an archive (uses its entry list).
    func pageCount(forComicPath path: String, isArchive: Bool) -> Int {
        if isArchive { return archiveState(path)?.entries.count ?? 0 }
        return folderPages(path).count
    }

    /// The file URL for page `index`, materializing it if needed (extracting that one archive entry
    /// on demand). nil if out of range or the page can't be produced.
    func pageFile(forComicPath path: String, isArchive: Bool, index: Int) -> URL? {
        if !isArchive {
            let pages = folderPages(path)
            return pages.indices.contains(index) ? pages[index] : nil
        }
        guard let state = archiveState(path), state.entries.indices.contains(index) else { return nil }
        let entry = state.entries[index]
        let url = state.dir.appendingPathComponent(entry)
        if ArchiveExtractor.fileSize(url) > 0 { return url }

        let archive = URL(fileURLWithPath: path)
        if !state.fullyExtracted {
            ArchiveExtractor.extractEntries(archive, [entry], into: state.dir)
            if ArchiveExtractor.fileSize(url) > 0 { return url }
            // Per-entry extraction produced nothing (solid/RAR) — fall back to a full extract once.
            ArchiveExtractor.extractAllInto(archive, dir: state.dir)
            lock.lock(); state.fullyExtracted = true; lock.unlock()
        }
        return ArchiveExtractor.fileSize(url) > 0 ? url : nil
    }

    /// The cover image (page 0) file, materialized. Cheap for archives (extracts one entry).
    func coverFile(forComicPath path: String, isArchive: Bool) -> URL? {
        pageFile(forComicPath: path, isArchive: isArchive, index: 0)
    }

    /// Every page as a real file on disk — folders directly, archives fully extracted. Used when the
    /// whole set is needed at once (e.g. repacking a `.cbr`/folder into a CBZ for OPDS download).
    func allPageFiles(forComicPath path: String, isArchive: Bool) -> [URL] {
        if !isArchive { return folderPages(path) }
        guard let state = archiveState(path) else { return [] }
        if !state.fullyExtracted {
            ArchiveExtractor.extractAllInto(URL(fileURLWithPath: path), dir: state.dir)
            lock.lock(); state.fullyExtracted = true; lock.unlock()
        }
        return AppModel.scanRecursive(state.dir)
    }

    // MARK: - Backwards-compatible listing

    /// Ordered page URLs. Folders → real files. Archives → the (not-yet-extracted) per-entry file
    /// URLs; call `pageFile`/`coverFile` to materialize a specific one. Kept for callers that just
    /// need the ordered list or a count.
    func pages(forComicPath path: String, isArchive: Bool) -> [URL] {
        if !isArchive { return folderPages(path) }
        guard let state = archiveState(path) else { return [] }
        return state.entries.map { state.dir.appendingPathComponent($0) }
    }

    // MARK: - Internals

    private func folderPages(_ path: String) -> [URL] {
        let dir = URL(fileURLWithPath: path)
        let top = AppModel.scan(dir)
        return top.isEmpty ? AppModel.scanRecursive(dir) : top
    }

    /// The streaming state for an archive, building it once (list entries, allocate a temp dir).
    private func archiveState(_ path: String) -> ArchiveState? {
        lock.lock()
        if let s = archives[path] { lock.unlock(); return s }
        lock.unlock()

        let archive = URL(fileURLWithPath: path)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("comicviewer-pages-" + CentralStore.sha256(path), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var entries: [String]
        if let listing = ArchiveExtractor.list(archive) {
            entries = listing.entries
                .filter { SupportedTypes.extensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } else {
            // No 7zz available — fall back to a full extract and read files off disk.
            guard let ex = ArchiveExtractor.extract(archive) else { return nil }
            let files = AppModel.scanRecursive(ex)
            let state = ArchiveState(entries: files.map(\.lastPathComponent), dir: ex)
            state.fullyExtracted = true
            lock.lock(); archives[path] = state; lock.unlock()
            return state
        }
        guard !entries.isEmpty else { return nil }
        let state = ArchiveState(entries: entries, dir: dir)
        lock.lock(); archives[path] = state; lock.unlock()
        return state
    }

    /// Delete and forget all extracted temp dirs (on server stop / quit).
    func clear() {
        lock.lock()
        let dirs = archives.values.map(\.dir)
        archives.removeAll()
        lock.unlock()
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }
}
