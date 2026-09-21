import CoreGraphics
import ImageIO
import Foundation

/// Downsampled, EXIF-upright thumbnails for the cover grids and chapter grid. Three tiers:
///   1. an in-memory LRU (instant), shared app-wide via `.shared` so thumbnails survive
///      navigation and view rebuilds;
///   2. a persistent on-disk cache of tiny JPEGs (`…/thumbs/`), so relaunches don't re-decode
///      full-size pages/covers — reading a ~500px JPEG is milliseconds;
///   3. generation from the source image (the only expensive path), done off the actor so
///      many thumbnails decode concurrently instead of serializing.
/// Duplicate concurrent requests for the same URL are coalesced into one decode.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private var store: [URL: CGImage] = [:]
    private var order: [URL] = []                       // oldest → newest
    private var inFlight: [URL: Task<CGImage?, Never>] = [:]
    private let capacity = 800

    private static var dir: URL {
        CentralStore.baseDir.appendingPathComponent("thumbs", isDirectory: true)
    }

    /// Return a thumbnail: memory → disk → generate. Decoding runs off the actor, so calls
    /// for different URLs proceed in parallel; calls for the same URL share one decode.
    /// Remote (http) URLs — e.g. a ReadComicsOnline issue's chapter thumbnails — are downloaded and
    /// cached by `RemoteImageCache`, so callers (grids, the chapter grid) work for both transparently.
    func thumbnail(for url: URL, maxPixel: Int) async -> CGImage? {
        if !url.isFileURL { return await RemoteImageCache.shared.image(for: url, maxPixel: maxPixel) }
        if let hit = store[url] { touch(url); return hit }
        if let running = inFlight[url] { return await running.value }

        let task = Task.detached(priority: .utility) { Self.loadOrMake(url, maxPixel: maxPixel) }
        inFlight[url] = task
        let cg = await task.value
        inFlight[url] = nil
        if let cg { insert(url, cg) }
        return cg
    }

    /// Decode + cache any not-yet-cached URLs, several at a time, so a grid is ready fast.
    func preload(_ urls: [URL], maxPixel: Int) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            var it = urls.makeIterator()
            func pump() {
                while running < 6, let url = it.next() {
                    if store[url] != nil { continue }
                    running += 1
                    group.addTask { _ = await self.thumbnail(for: url, maxPixel: maxPixel) }
                }
            }
            pump()
            while await group.next() != nil {
                running -= 1
                pump()
            }
        }
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

    // MARK: - Disk tier (nonisolated: runs on the detached decode task)

    /// A valid on-disk thumbnail (present and newer than its source) is decoded and returned;
    /// otherwise the source is downsampled, persisted, and returned.
    private nonisolated static func loadOrMake(_ url: URL, maxPixel: Int) -> CGImage? {
        let fm = FileManager.default
        let file = dir.appendingPathComponent(CentralStore.sha256(url.path) + "-\(maxPixel).jpg")

        if let cached = mtime(file), let src = mtime(url), cached >= src,
           let cg = ImageLoader.decodeDisplay(file, maxPixel: maxPixel)?.cgImage {
            return cg
        }

        guard let cg = ImageLoader.decodeDisplay(url, maxPixel: maxPixel)?.cgImage else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        writeJPEG(cg, to: file)
        return cg
    }

    private nonisolated static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private nonisolated static func writeJPEG(_ cg: CGImage, to file: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            file as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
