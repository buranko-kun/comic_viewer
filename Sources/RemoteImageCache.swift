import CoreGraphics
import ImageIO
import Foundation

/// Downsampled, memory + disk cached thumbnails for **remote** covers (the Online section).
/// `ThumbnailCache` is for local files; this one fetches over the network, downsamples with
/// ImageIO, keeps an in-memory LRU, and persists tiny JPEGs to `…/onlinecovers/` so scrolling
/// the 18k-comic grid doesn't re-download or re-decode. Duplicate in-flight requests coalesce.
actor RemoteImageCache {
    static let shared = RemoteImageCache()

    private var store: [URL: CGImage] = [:]
    private var order: [URL] = []                        // oldest → newest
    private var inFlight: [URL: Task<(CGImage?, Bool), Never>] = [:]
    // Bounds resident memory (~0.4 MB per 320px cover → ~130 MB). Large enough to hold the
    // look-ahead prefetch buffer plus a couple of screens back, so neither forward scrolling nor
    // small scroll-backs show an empty thumbnail. Off-screen cells free their own copies.
    private let capacity = 320

    private static var dir: URL {
        CentralStore.baseDir.appendingPathComponent("onlinecovers", isDirectory: true)
    }

    /// Return a cover: memory → disk → network. Same-URL requests share one fetch.
    func image(for url: URL, maxPixel: Int) async -> CGImage? {
        await result(for: url, maxPixel: maxPixel).image
    }

    /// Like `image(for:)` but also reports whether the miss was a **definitive 404/410** — so a
    /// caller with a fallback (e.g. a guessed cover URL) can skip pointless retries and resolve the
    /// real URL immediately, instead of treating a "not found" like a transient hiccup.
    func result(for url: URL, maxPixel: Int) async -> (image: CGImage?, notFound: Bool) {
        if let hit = store[url] { touch(url); return (hit, false) }
        if let running = inFlight[url] { return await running.value }

        let task = Task<(CGImage?, Bool), Never> { await Self.loadOrFetch(url, maxPixel: maxPixel) }
        inFlight[url] = task
        let res = await task.value
        inFlight[url] = nil
        if let cg = res.0 { insert(url, cg) }
        return (res.0, res.1)
    }

    // MARK: - Look-ahead prefetch

    private var prefetchQueue: [URL] = []
    private var pumping = false

    /// Set the covers we want warmed next (e.g. the rows just ahead of the viewport). Replaces
    /// any previous target so stale ranges are dropped, and runs the fetch on the actor's own
    /// task — decoupled from the caller, so scrolling can update the target without cancelling
    /// in-flight downloads. The result: a few rows stay decoded ahead of where you're looking.
    func setPrefetchTarget(_ urls: [URL], maxPixel: Int) {
        prefetchQueue = urls.filter { store[$0] == nil && inFlight[$0] == nil }
        guard !pumping, !prefetchQueue.isEmpty else { return }
        pumping = true
        Task { await pump(maxPixel: maxPixel) }
    }

    private func pump(maxPixel: Int) async {
        while true {
            var batch: [URL] = []
            while batch.count < 6, !prefetchQueue.isEmpty {
                let u = prefetchQueue.removeFirst()
                if store[u] == nil { batch.append(u) }
            }
            if batch.isEmpty { break }
            await withTaskGroup(of: Void.self) { group in
                for u in batch { group.addTask { _ = await self.image(for: u, maxPixel: maxPixel) } }
            }
        }
        pumping = false
    }

    // MARK: - Memory LRU

    private func insert(_ url: URL, _ cg: CGImage) {
        store[url] = cg
        touch(url)
        while order.count > capacity { store[order.removeFirst()] = nil }
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
    }

    // MARK: - Disk + network

    /// A cached downsampled JPEG (remote covers don't change, so presence is enough) is reused;
    /// otherwise the image is fetched, downsampled, persisted, and returned.
    /// Returns `(image, notFound)`: `notFound` is true only for a definitive 404/410, so callers
    /// can distinguish "this URL will never work" from a transient failure worth retrying.
    private static func loadOrFetch(_ url: URL, maxPixel: Int) async -> (CGImage?, Bool) {
        let file = dir.appendingPathComponent(CentralStore.sha256(url.absoluteString) + "-\(maxPixel).jpg")
        if let cg = downsample(fileURL: file, maxPixel: maxPixel) { return (cg, false) }   // disk hit

        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return (nil, false) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let notFound = http.statusCode == 404 || http.statusCode == 410
            return (nil, notFound)
        }
        guard let cg = downsample(data: data, maxPixel: maxPixel) else { return (nil, false) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeJPEG(cg, to: file)
        return (cg, false)
    }

    /// Downsample from in-memory image data (network path).
    private static func downsample(data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: src, maxPixel: maxPixel)
    }

    /// Downsample from an already-cached file (disk path); nil if missing/unreadable.
    private static func downsample(fileURL: URL, maxPixel: Int) -> CGImage? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return thumbnail(from: src, maxPixel: maxPixel)
    }

    private static func thumbnail(from src: CGImageSource, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static func writeJPEG(_ cg: CGImage, to file: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            file as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
