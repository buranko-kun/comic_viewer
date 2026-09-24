import XCTest

@testable import ComicViewer

final class RemotePrefetchSchedulerTests: XCTestCase {
    func testLimitsConcurrentLoads() async throws {
        let tracker = LoadTracker()
        let scheduler = RemotePrefetchScheduler(maxConcurrent: 2) { url, _ in
            await tracker.started(url)
            try? await Task.sleep(for: .milliseconds(40))
            await tracker.finished(url)
        }

        let urls = (1...6).map { URL(string: "https://example.com/page\($0).jpg")! }
        await scheduler.setTarget(urls, maxPixel: 1000)

        try await Task.sleep(for: .milliseconds(220))

        let snapshot = await tracker.snapshot()
        XCTAssertLessThanOrEqual(snapshot.maximumConcurrent, 2)
        XCTAssertEqual(snapshot.completed.count, 6)
    }

    func testReplacingTargetDropsQueuedWork() async throws {
        let tracker = LoadTracker()
        let scheduler = RemotePrefetchScheduler(maxConcurrent: 2) { url, _ in
            await tracker.started(url)
            try? await Task.sleep(for: .milliseconds(60))
            await tracker.finished(url)
        }

        let oldURLs = (1...8).map { URL(string: "https://example.com/old-\($0).jpg")! }
        let newURLs = (1...2).map { URL(string: "https://example.com/new-\($0).jpg")! }

        await scheduler.setTarget(oldURLs, maxPixel: 1000)
        try await Task.sleep(for: .milliseconds(10))
        await scheduler.setTarget(newURLs, maxPixel: 1000)
        try await Task.sleep(for: .milliseconds(180))

        let snapshot = await tracker.snapshot()
        let completedNames = Set(snapshot.completed.map { $0.lastPathComponent })

        XCTAssertTrue(completedNames.contains("new-1.jpg"))
        XCTAssertTrue(completedNames.contains("new-2.jpg"))
        XCTAssertFalse(completedNames.contains("old-3.jpg"))
        XCTAssertFalse(completedNames.contains("old-4.jpg"))
        XCTAssertFalse(completedNames.contains("old-5.jpg"))
        XCTAssertFalse(completedNames.contains("old-6.jpg"))
        XCTAssertFalse(completedNames.contains("old-7.jpg"))
        XCTAssertFalse(completedNames.contains("old-8.jpg"))
    }

    private actor LoadTracker {
        private var current = 0
        private var maximum = 0
        private var completed: [URL] = []

        func started(_ url: URL) {
            current += 1
            maximum = max(maximum, current)
        }

        func finished(_ url: URL) {
            current -= 1
            completed.append(url)
        }

        struct Snapshot {
            let maximumConcurrent: Int
            let completed: [URL]
        }

        func snapshot() -> Snapshot {
            Snapshot(maximumConcurrent: maximum, completed: completed)
        }
    }
}
