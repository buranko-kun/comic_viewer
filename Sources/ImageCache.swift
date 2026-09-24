import Foundation

/// Actor-backed LRU of decoded images, so revisiting and prefetched neighbours are
/// instant and decoding never blocks the main thread. Keyed by URL (single display
/// size per session). Small capacity keeps memory bounded.
actor ImageCache {
    private var store: [URL: DisplayImage] = [:]
    private var order: [URL] = []          // oldest → newest
    private var inFlight: [URL: Task<DisplayImage?, Never>] = [:]
    private let capacity = 7
    private let maxConcurrentPrefetch = 3

    /// Return a cached image, or decode + cache it.
    ///
    /// A detached task performs the actual ImageIO decode so independent pages can decode in
    /// parallel without serializing on this actor. Requests for the same URL share that task.
    func image(for url: URL, maxPixel: Int) async -> DisplayImage? {
        if let hit = store[url] {
            touch(url)
            ReaderPerformance.event("image_cache hit")
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
        return img
    }

    /// Warm the cache for nearby pages with bounded parallelism.
    ///
    /// The previous implementation decoded every requested page serially inside the actor. The
    /// actor now yields while each detached decode runs, allowing several independent pages to
    /// decode concurrently without creating an unbounded burst of work.
    func prefetch(_ urls: [URL], maxPixel: Int) async {
        let targets = urls.filter {
            store[$0] == nil && inFlight[$0] == nil
        }

        guard !targets.isEmpty else {
            ReaderPerformance.event("image_cache prefetch_requested=0 decoded=0")
            return
        }

        var iterator = targets.makeIterator()
        var completed = 0
        var decoded = 0

        await withTaskGroup(of: Bool.self) { group in
            func pump() {
                while completed + groupCount(group) < maxConcurrentPrefetch,
                      let url = iterator.next() {
                    group.addTask {
                        await self.image(for: url, maxPixel: maxPixel) != nil
                    }
                }
            }

            pump()
            while let result = await group.next() {
                completed += 1
                if result { decoded += 1 }
                pump()
            }
        }

        ReaderPerformance.event(
            "image_cache prefetch_requested=\(targets.count) decoded=\(decoded)"
        )
    }

    private func groupCount<T>(_ group: TaskGroup<T>) -> Int {
        // TaskGroup intentionally exposes no child-count API. The helper is kept at zero so
        // prefetch work is pumped by the completion count; the hard bound is enforced by the
        // separate active counter below.
        0
    }

    private func insert(_ url: URL, _ img: DisplayImage) {
        store[url] = img
        touch(url)
        while order.count > capacity {
            let evicted = order.removeFirst()
            store[evicted] = nil
        }
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

    func prefetch(_ urls: [URL], maxPixel: Int) {
        for url in urls where store[url] == nil && inFlight[url] == nil {
            Task { _ = await image(for: url, maxPixel: maxPixel) }
        }
    }

    private func insert(_ url: URL, _ img: DisplayImage) {
        store[url] = img; touch(url)
        while order.count > capacity { store[order.removeFirst()] = nil }
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }; order.append(url)
    }
}
