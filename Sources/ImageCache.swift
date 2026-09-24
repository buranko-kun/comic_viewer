import Foundation

/// Actor-backed LRU of decoded images, so revisiting and prefetched neighbours are
/// instant and decoding never blocks the main thread. Keyed by URL (single display
/// size per session). Small capacity keeps memory bounded.
actor ImageCache {
    static let defaultMaxBytes = 256 * 1024 * 1024

    private var store: [URL: DisplayImage] = [:]
    private var order: [URL] = []          // oldest → newest
    private var costs: [URL: Int] = [:]
    private var totalBytes = 0
    private var inFlight: [URL: Task<DisplayImage?, Never>] = [:]
    private let maxBytes: Int
    private let maxConcurrentPrefetch = 3

    init(maxBytes: Int = 256 * 1024 * 1024) {
        self.maxBytes = max(1, maxBytes)
    }

    /// Return a cached image, or decode + cache it.
    ///
    /// A detached task performs the actual ImageIO decode so independent pages can decode in
    /// parallel without serializing on this actor. Requests for the same URL share that task.
    func image(for url: URL, maxPixel: Int) async -> DisplayImage? {
        if let hit = store[url] {
            touch(url)
            ReaderPerformance.event("image_cache hit bytes=\(totalBytes) items=\(store.count)")
            return hit
        }

        if let running = inFlight[url] {
            ReaderPerformance.event("image_cache coalesced")
            return await running.value
        }

        ReaderPerformance.event("image_cache miss")
        let task = Task.detached(priority: .userInitiated) {
            ImageLoader.decodeDisplay(url, maxPixel: maxPixel)
        }
        inFlight[url] = task

        let img = await task.value
        inFlight[url] = nil

        guard let img else {
            ReaderPerformance.event("image_cache decode_failed")
            return nil
        }

        insert(url, img)
        ReaderPerformance.event("image_cache inserted bytes=\(totalBytes) items=\(store.count)")
        return img
    }

    /// Warm the cache for nearby pages with bounded parallelism.
    ///
    /// The cache is budgeted by decoded bitmap bytes rather than page count. Large pages therefore
    /// consume proportionally more of the budget and evict older pages sooner.
    func prefetch(_ urls: [URL], maxPixel: Int) async {
        let targets = urls.filter {
            store[$0] == nil && inFlight[$0] == nil
        }

        guard !targets.isEmpty else {
            ReaderPerformance.event("image_cache prefetch_requested=0 decoded=0")
            return
        }

        var decoded = 0
        var nextIndex = 0

        await withTaskGroup(of: Bool.self) { group in
            let initialCount = min(maxConcurrentPrefetch, targets.count)
            for index in 0..<initialCount {
                let url = targets[index]
                group.addTask {
                    await self.image(for: url, maxPixel: maxPixel) != nil
                }
                nextIndex += 1
            }

            while let result = await group.next() {
                if result { decoded += 1 }

                guard nextIndex < targets.count else { continue }

                let url = targets[nextIndex]
                group.addTask {
                    await self.image(for: url, maxPixel: maxPixel) != nil
                }
                nextIndex += 1
            }
        }

        ReaderPerformance.event(
            "image_cache prefetch_requested=\(targets.count) decoded=\(decoded)"
        )
    }

    /// Approximate resident bitmap memory, exposed for diagnostics and tests.
    var estimatedMemoryBytes: Int {
        totalBytes
    }

    /// Number of resident decoded images, exposed for diagnostics and tests.
    var imageCount: Int {
        store.count
    }

    /// The memory cost used for a decoded CGImage.
    static func estimatedCost(of image: DisplayImage) -> Int {
        image.cgImage.bytesPerRow * image.cgImage.height
    }

    private func insert(_ url: URL, _ img: DisplayImage) {
        let newCost = Self.estimatedCost(of: img)

        if let previousCost = costs.removeValue(forKey: url) {
            totalBytes -= previousCost
        }
        store[url] = img
        touch(url)
        costs[url] = newCost
        totalBytes += newCost

        // An individual page can legitimately exceed the normal budget. Keep that page as a
        // single cache entry rather than immediately evicting it; this bounds the cache to the
        // current oversized page instead of causing an endless decode/evict/decode loop.
        if newCost > maxBytes {
            for victim in order.dropFirst() {
                remove(victim)
            }
            ReaderPerformance.event(
                "image_cache oversize_page bytes=\(newCost) budget=\(maxBytes)"
            )
            return
        }

        while totalBytes > maxBytes, let victim = order.first {
            remove(victim)
        }
    }

    private func remove(_ url: URL) {
        store.removeValue(forKey: url)
        if let cost = costs.removeValue(forKey: url) {
            totalBytes -= cost
        }
        order.removeAll { $0 == url }
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
    }
}

/// Reader page cache for **web comics** — fetches page images over the network and decodes them in
/// memory only (nothing is written to disk, matching the "streamed, not stored" intent). Small LRU;
/// duplicate in-flight requests for the same page are coalesced.
actor RemotePageCache {
    static let shared = RemotePageCache()

    private var store: [URL: DisplayImage] = [:]
    private var order: [URL] = []
    private var inFlight: [URL: Task<DisplayImage?, Never>] = [:]
    private lazy var prefetchScheduler = RemotePrefetchScheduler { [weak self] url, maxPixel in
        guard let self else { return }
        _ = await self.image(for: url, maxPixel: maxPixel)
    }
    private let capacity = 8

    /// How many times to (re)try fetching a page before giving up. Streamed pages routinely fail
    /// transiently under a burst of requests or a flaky connection, but succeed on a retry — so we
    /// keep trying (with backoff) rather than flashing "couldn't load" for a page that will load.
    private static let maxAttempts = 10

    func image(for url: URL, maxPixel: Int) async -> DisplayImage? {
        if let hit = store[url] {
            touch(url)
            ReaderPerformance.event("remote_page_cache hit")
            return hit
        }
        if let running = inFlight[url] {
            ReaderPerformance.event("remote_page_cache coalesced")
            return await running.value
        }
        ReaderPerformance.event("remote_page_cache miss")
        let startedAt = ReaderPerformance.now()
        let task = Task<DisplayImage?, Never> {
            for attempt in 0..<Self.maxAttempts {
                if Task.isCancelled { return nil }
                if let (data, resp) = try? await URLSession.shared.data(from: url),
                   (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
                   let img = ImageLoader.decodeDisplay(data: data, maxPixel: maxPixel) {
                    return img
                }
                // Transient failure (network error, non-2xx, or partial/corrupt decode) — wait a
                // little (increasing, capped) and try again.
                if attempt < Self.maxAttempts - 1 {
                    try? await Task.sleep(for: .milliseconds(min(1200, 300 * (attempt + 1))))
                }
            }
            return nil
        }
        inFlight[url] = task
        let img = await task.value
        ReaderPerformance.metric(
            "remote_page_load",
            milliseconds: ReaderPerformance.milliseconds(since: startedAt)
        )
        inFlight[url] = nil
        if let img { insert(url, img) }
        return img
    }

    func prefetch(_ urls: [URL], maxPixel: Int) async {
        let targets = urls.filter {
            store[$0] == nil && inFlight[$0] == nil
        }
        await prefetchScheduler.setTarget(targets, maxPixel: maxPixel)
        ReaderPerformance.event(
            "remote_page_cache prefetch_target=\\(targets.count)"
        )
    }

    func cancelPrefetch() async {
        await prefetchScheduler.cancel()
        ReaderPerformance.event("remote_page_cache prefetch_cancelled")
    }


    private func insert(_ url: URL, _ img: DisplayImage) {
        store[url] = img; touch(url)
        while order.count > capacity { store[order.removeFirst()] = nil }
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }; order.append(url)
    }
}
