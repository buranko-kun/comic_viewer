import Foundation

/// Schedules replaceable, bounded-concurrency remote prefetch work.
///
/// A new target cancels the scheduler's queued work and replaces it with the newest page range.
/// Individual loads are owned by the cache, so cancelling a scheduler task never cancels a
/// network request that a visible page may also be awaiting.
actor RemotePrefetchScheduler {
    typealias Loader = @Sendable (URL, Int) async -> Void

    private let loader: Loader
    private let maxConcurrent: Int
    private var target: [(url: URL, maxPixel: Int)] = []
    private var generation = 0
    private var pumpTask: Task<Void, Never>?

    init(maxConcurrent: Int = 2, loader: @escaping Loader) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.loader = loader
    }

    /// Replace the current queued target and begin pumping it in bounded batches.
    func setTarget(_ urls: [URL], maxPixel: Int) {
        generation &+= 1
        let currentGeneration = generation
        pumpTask?.cancel()

        var seen = Set<URL>()
        target = urls.compactMap { url in
            guard seen.insert(url).inserted else { return nil }
            return (url, maxPixel)
        }

        guard !target.isEmpty else {
            pumpTask = nil
            return
        }

        let work = target
        pumpTask = Task { [weak self] in
            await self?.pump(work, generation: currentGeneration)
        }
    }

    func cancel() {
        generation &+= 1
        target.removeAll()
        pumpTask?.cancel()
        pumpTask = nil
    }

    private func pump(
        _ work: [(url: URL, maxPixel: Int)],
        generation: Int
    ) async {
        var next = 0

        while next < work.count {
            guard generation == self.generation, !Task.isCancelled else { return }

            let end = min(next + maxConcurrent, work.count)
            let batch = Array(work[next..<end])
            next = end

            await withTaskGroup(of: Void.self) { group in
                for item in batch {
                    group.addTask {
                        await self.loader(item.url, item.maxPixel)
                    }
                }
            }
        }

        guard generation == self.generation else { return }
        pumpTask = nil
    }
}
