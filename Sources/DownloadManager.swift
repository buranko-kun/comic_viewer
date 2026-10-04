import SwiftUI
import Foundation

/// Bounded FIFO downloads with mirror fallback, format validation, and per-job recovery details.
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
        var errorMessage: String? = nil
    }

    static let maxConcurrent = 2                    // simultaneous downloads; rest queue

    /// The queue, newest first. The single source of truth for both the cards and the panel.
    private(set) var jobs: [Job] = []
    /// In-flight download tasks, keyed by job id, so a job can be cancelled.
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]

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
        generations[id] = nil
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
        for job in jobs.sorted(by: { $0.added < $1.added }) where slots > 0 {
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
        let destinationFolder = destinationFolder(for: item.title)
        let generation = UUID()
        generations[id] = generation
        tasks[id] = Task { @MainActor in
            defer { if generations[id] == generation { tasks[id] = nil; pump() } }   // free the slot and advance the queue, always

            var mirrorStrings = item.mirrors
            if mirrorStrings.isEmpty { mirrorStrings = await MirrorStore.shared.mirrors(forLink: item.page) }
            guard !Task.isCancelled else { return }
            let urls = mirrorStrings.compactMap { URL(string: $0) }.filter { ["http", "https", "file"].contains($0.scheme ?? "") }
            guard !urls.isEmpty else { setStatus(id, .needsBrowser); return }

            var lastFailure = "No downloadable archive was found."
            var needsBrowser = false
            for url in urls {
                if Task.isCancelled { return }   // job cancelled → cancel() already removed it
                setStatus(id, .downloading(nil))
                do {
                    let downloadedURL = try await Self.perform(from: url, title: item.title,
                                                 destinationFolder: destinationFolder, referrer: item.page.flatMap(URL.init(string:))) { frac in
                        Task { @MainActor in
                            if self.generations[id] == generation, case .downloading = self.status(forItem: id) {
                                self.setStatus(id, .downloading(frac))
                            }
                        }
                    }
                    guard !Task.isCancelled, generations[id] == generation else { return }
                    if ArchiveExtractor.isArchive(downloadedURL), ArchiveExtractor.hasImageEntries(downloadedURL) {
                        Task.detached(priority: .utility) {
                            _ = await ArchiveCover.preserveThumbnail(for: downloadedURL)
                        }
                    }
                    setStatus(id, .done)
                    let destinationMessage = DownloadDestinationStore.shared.isCustom
                        ? "Downloaded: \(item.title)"
                        : "Downloaded to Library: \(item.title)"
                    AppNoticeCenter.shared.show(destinationMessage)
                    LibraryModel.shared.rescan()   // rescan → reconcile replaces the item
                    return
                } catch {
                    if Task.isCancelled { return }   // cancelled mid-download → bail quietly
                    lastFailure = error.localizedDescription
                    if let error = error as? DownloadValidationError { needsBrowser = needsBrowser || error.needsBrowser }
                    continue
                }
            }
            if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].errorMessage = lastFailure }
            setStatus(id, needsBrowser ? .needsBrowser : .failed)
        }
    }

    func openInBrowser(_ item: CollectionItem) {
        if let s = item.page ?? item.mirrors.first, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }


    /// Validate file signatures, including small archives, before moving anything into the library.
    @discardableResult
    static func perform(from url: URL, title: String,
                                destinationFolder: URL, referrer: URL?,
                                onProgress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let fm = FileManager.default

        let tempURL: URL
        if url.isFileURL { tempURL = url }
        else {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            if let referrer, ["http", "https"].contains(referrer.scheme ?? "") {
                // Do not leak signed source queries to a mirror or downgrade HTTPS referrers.
                if !(referrer.scheme == "https" && url.scheme == "http") {
                    var safe = URLComponents(url: referrer, resolvingAgainstBaseURL: false)
                    safe?.query = nil; safe?.fragment = nil; safe?.user = nil; safe?.password = nil
                    if referrer.host != url.host { safe?.path = "/" }
                    request.setValue(safe?.url?.absoluteString, forHTTPHeaderField: "Referer")
                }
            }
            tempURL = try await transfer(request, onProgress: onProgress)
        }
        defer { if !url.isFileURL { try? fm.removeItem(at: tempURL) } }
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 512) ?? Data()
        let detected = try DownloadValidationError.archiveExtension(prefix)
        let dest = destinationURL(title: title, ext: detected, folder: destinationFolder)
        if url.isFileURL { try fm.copyItem(at: tempURL, to: dest) }
        else { try fm.moveItem(at: tempURL, to: dest) }

        return await Task.detached(priority: .utility) {
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
        }.value
    }

    private static func transfer(_ request: URLRequest,
                                 onProgress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        for attempt in 0..<3 {
            do {
                let (url, response) = try await URLSession.shared.download(for: request, delegate: ProgressDelegate(onProgress: onProgress))
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    try? FileManager.default.removeItem(at: url)
                    throw DownloadValidationError.http(http.statusCode)
                }
                return url
            } catch {
                try Task.checkCancellation()
                let retryable: Bool
                if let error = error as? DownloadValidationError { retryable = error.retryable }
                else if let error = error as? URLError { retryable = [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) }
                else { retryable = false }
                guard retryable, attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw DownloadValidationError.invalidFile
    }

    /// A unique, filesystem-safe destination inside the selected folder.
    private static func destinationURL(title: String, ext: String, folder: URL) -> URL {
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

    /// Resolve the destination once before starting a download so all filesystem work stays
    /// on the main actor and the async transfer can use a fixed path.
    private func destinationFolder(for title: String) -> URL {
        if let custom = DownloadDestinationStore.shared.customFolder {
            try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        return LibraryModel.shared.downloadFolder(forTitle: title)
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "comic" : cleaned
    }
}

/// Reports progress without rejecting valid small comics.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    let onProgress: @Sendable (Double?) -> Void
    init(onProgress: @escaping @Sendable (Double?) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite total: Int64) {
        if total > 0 {
            onProgress(min(1, Double(totalBytesWritten) / Double(total)))
        } else {
            onProgress(nil)   // unknown length → indeterminate
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) { /* handled by async return */ }
}

enum DownloadValidationError: LocalizedError {
    case http(Int), webpage, invalidFile
    var needsBrowser: Bool {
        switch self { case .webpage, .http(401), .http(403): return true; default: return false }
    }
    var retryable: Bool {
        if case .http(let status) = self { return (500...599).contains(status) }
        return false
    }
    var errorDescription: String? {
        switch self {
        case .http(401): return "The download requires login. Open the source in your browser."
        case .http(403): return "The host blocked this download. Open the source in your browser."
        case .http(429): return "The download host is rate limiting requests. Wait before retrying."
        case .http(let code): return "The download host returned HTTP \(code)."
        case .webpage: return "The mirror returned a webpage instead of a comic archive. Open it in your browser."
        case .invalidFile: return "The response is not a supported ZIP, RAR, 7z, or PDF file. Try another mirror."
        }
    }
    static func archiveExtension(_ prefix: Data) throws -> String {
        let bytes = Array(prefix)
        if bytes.count >= 22, bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]) || bytes.starts(with: [0x50, 0x4b, 0x05, 0x06]) { return "cbz" }
        if bytes.count >= 14, bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07]) { return "cbr" }
        if bytes.count >= 32, bytes.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) { return "7z" }
        if bytes.count >= 8, bytes.starts(with: Array("%PDF-".utf8)) { return "pdf" }
        let text = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") || text.contains("<head") { throw Self.webpage }
        throw Self.invalidFile
    }
}
