import SwiftUI
import Foundation

/// A queued downloader for online catalog items. Each tapped comic becomes a `Job`; jobs run up to
/// `maxConcurrent` at a time and the rest wait as `.queued`. For each job it tries the item's
/// mirrors in order using a **size rule**: a real comic is well over 1 MB, while a file-locker
/// landing page is a few KB of HTML — so any response under ~1 MB is skipped and the next mirror is
/// tried. On success the library is rescanned (which reconciles the online entry into the downloaded
/// comic). If no mirror yields a real file, the item's page is offered in the browser. Jobs can be
/// cancelled or retried, and the whole set is surfaced in the Downloads panel.
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    /// `.idle` = not in the queue. `.queued` = waiting for a slot. `downloading(nil)` =
    /// started/indeterminate; `downloading(x)` = fraction 0…1.
    enum Status: Equatable { case idle, queued, downloading(Double?), done, needsBrowser, failed }

    /// One tracked download. `id` is the item's id (so at most one job per comic).
    struct Job: Identifiable, Equatable {
        let id: String
        let item: CollectionItem
        var status: Status
        let added: Date
    }

    static let minWinnerBytes: Int64 = 1_000_000   // >1 MB counts as a real file
    static let maxConcurrent = 2                    // simultaneous downloads; rest queue

    /// The queue, newest first. The single source of truth for both the cards and the panel.
    private(set) var jobs: [Job] = []
    /// In-flight download tasks, keyed by job id, so a job can be cancelled.
    private var tasks: [String: Task<Void, Never>] = [:]

    func status(forItem id: String) -> Status { jobs.first { $0.id == id }?.status ?? .idle }

    var isDownloading: Bool {
        jobs.contains { if case .downloading = $0.status { return true } else { return false } }
    }
    /// Downloading + queued — drives the toolbar badge.
    var activeCount: Int {
        jobs.filter { switch $0.status { case .downloading, .queued: return true; default: return false } }.count
    }
    var hasFinished: Bool {
        jobs.contains { switch $0.status { case .done, .failed, .needsBrowser: return true; default: return false } }
    }

    // MARK: - Queue control

    /// Enqueue an online item (or re-enqueue a finished/failed one). No-op if it's already queued
    /// or downloading. Newly enqueued jobs go to the front and the queue is pumped.
    func download(_ item: CollectionItem) {
        guard item.kind == .online else { return }
        let id = item.id
        if let existing = jobs.first(where: { $0.id == id }) {
            switch existing.status {
            case .queued, .downloading: return              // already going
            default: jobs.removeAll { $0.id == id }         // finished/failed → re-enqueue fresh
            }
        }
        jobs.insert(Job(id: id, item: item, status: .queued, added: Date()), at: 0)
        pump()
    }

    /// Retry a finished/failed job using its stored item.
    func retry(_ id: String) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        download(job.item)
    }

    /// Cancel a queued or in-flight job and drop it from the queue, then fill the freed slot.
    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        jobs.removeAll { $0.id == id }
        pump()
    }

    /// Remove all finished/failed/needs-browser jobs from the list (leaves active ones running).
    func clearFinished() {
        jobs.removeAll {
            switch $0.status { case .done, .failed, .needsBrowser: return true; default: return false }
        }
    }

    /// Start queued jobs until `maxConcurrent` are downloading.
    private func pump() {
        let active = jobs.filter { if case .downloading = $0.status { return true } else { return false } }.count
        var slots = Self.maxConcurrent - active
        guard slots > 0 else { return }
        for job in jobs where slots > 0 {
            if case .queued = job.status { start(job.id); slots -= 1 }
        }
    }

    private func setStatus(_ id: String, _ status: Status) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].status = status }
    }

    /// Run one job: try its mirrors in order until one downloads a real file. Mirrors may be inline
    /// (Collections items carry them) or resolved on demand from `MirrorStore` by the page link.
    private func start(_ id: String) {
        guard let item = jobs.first(where: { $0.id == id })?.item else { return }
        setStatus(id, .downloading(nil))
        tasks[id] = Task { @MainActor in
            defer { tasks[id] = nil; pump() }   // free the slot and advance the queue, always

            var mirrorStrings = item.mirrors
            if mirrorStrings.isEmpty { mirrorStrings = await MirrorStore.shared.mirrors(forLink: item.page) }
            let urls = mirrorStrings.compactMap { URL(string: $0) }
            guard !urls.isEmpty else { setStatus(id, .needsBrowser); return }

            let ext = urls.compactMap { $0.pathExtension.isEmpty ? nil : $0.pathExtension.lowercased() }
                .first(where: { ArchiveExtractor.extensions.contains($0) }) ?? "cbz"

            for url in urls {
                if Task.isCancelled { return }   // job cancelled → cancel() already removed it
                setStatus(id, .downloading(nil))
                do {
                    _ = try await Self.perform(from: url, title: item.title, ext: ext) { frac in
                        Task { @MainActor in
                            if case .downloading = self.status(forItem: id) {
                                self.setStatus(id, .downloading(frac))
                            }
                        }
                    }
                    setStatus(id, .done)
                    AppNoticeCenter.shared.show("Downloaded to Library: \(item.title)")
                    LibraryModel.shared.rescan()   // rescan → reconcile replaces the item
                    return
                } catch {
                    if Task.isCancelled { return }   // cancelled mid-download → bail quietly
                    continue                         // too small / failed → next mirror
                }
            }
            setStatus(id, .needsBrowser)             // nothing worked — offer the browser
        }
    }

    func openInBrowser(_ item: CollectionItem) {
        if let s = item.page ?? item.mirrors.first, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    private enum DLError: Error { case tooSmall, badResponse }

    /// Download `url` to the library downloads folder, reporting progress. Throws if the response
    /// is smaller than the winner threshold (a locker gate) so we never keep a non-comic file.
    @discardableResult
    private static func perform(from url: URL, title: String, ext: String,
                                onProgress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let fm = FileManager.default
        let dest = await destinationURL(title: title, ext: ext)

        if url.isFileURL {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: url, to: dest)
            return dest
        }

        let delegate = ProgressDelegate(minBytes: minWinnerBytes, onProgress: onProgress)
        let (tempURL, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DLError.badResponse
        }
        let size = ((try? fm.attributesOfItem(atPath: tempURL.path))?[.size] as? Int64) ?? 0
        guard size >= minWinnerBytes else { throw DLError.tooSmall }

        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tempURL, to: dest)

        // If the downloaded archive is a bundle of nested comics (no page images at the top level),
        // auto-extract it into a folder so those comics are browsable, then drop the wrapper.
        if ArchiveExtractor.isArchive(dest), !ArchiveExtractor.hasImageEntries(dest),
           let folder = ArchiveExtractor.extractInto(dest, preferred: dest.deletingPathExtension()) {
            try? fm.removeItem(at: dest)
            return folder
        }
        // Normalise a RAR-backed comic to ZIP (in place) so it streams page-by-page for fast opens.
        // Best-effort and lossless; on failure the original is kept and still opens via full extract.
        if ArchiveExtractor.isArchive(dest), ArchiveExtractor.hasImageEntries(dest) {
            ArchiveExtractor.normalizeToZip(dest)
        }
        return dest
    }

    /// A unique, filesystem-safe destination in the library's downloads folder.
    private static func destinationURL(title: String, ext: String) async -> URL {
        let folder = LibraryModel.shared.downloadFolder(forTitle: title)
        let base = sanitize(title)
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "comic" : cleaned
    }
}

/// Reports download progress and cancels early when the server declares a size below the winner
/// threshold (so tiny locker pages are abandoned without downloading them in full).
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    let minBytes: Int64
    let onProgress: @Sendable (Double?) -> Void
    init(minBytes: Int64, onProgress: @escaping @Sendable (Double?) -> Void) {
        self.minBytes = minBytes; self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite total: Int64) {
        if total > 0 {
            if total < minBytes { downloadTask.cancel(); return }   // declared too small → abandon
            onProgress(min(1, Double(totalBytesWritten) / Double(total)))
        } else {
            onProgress(nil)   // unknown length → indeterminate
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) { /* handled by async return */ }
}
