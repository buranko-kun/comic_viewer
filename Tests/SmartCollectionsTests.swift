import XCTest
import Observation

@testable import ComicViewer

final class SmartCollectionsTests: XCTestCase {
    @MainActor
    func testResetStreamedReadingUpdatesHomeAndKeepsChapters() async throws {
        try await checkStreamedReset(removingChapters: false)
    }

    @MainActor
    func testResetStreamedReadingUpdatesHomeAndRemovesChapters() async throws {
        try await checkStreamedReset(removingChapters: true)
    }

    @MainActor
    private func checkStreamedReset(removingChapters: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let historyURL = directory.appendingPathComponent("history.json")
        let history = RemoteReadingHistory(fileURL: historyURL)
        let pages = (1...10).map { URL(string: "https://fixture.invalid/pages/\($0).jpg")! }
        let comic = Comic(url: URL(string: "https://fixture.invalid/\(UUID().uuidString)")!,
                          series: "RCO fixture", isArchive: false, coverURL: pages.first,
                          pageCount: 10, progress: ComicProgress(page: 4, count: 10),
                          chapterCount: 1, metaTitle: "Streamed issue", tooltip: nil, remotePages: pages)
        let key = CentralStore.key(for: comic.url)
        let stateURL = CentralStore.stateURL(for: key)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: stateURL)
        }
        history.record(comic)
        var state = ComicState()
        state.chapters = [pages[0].absoluteString]
        state.chapterNames = [pages[0].absoluteString: "First chapter"]
        state.lastPage = pages[3].absoluteString
        state.lastIndex = 3; state.pageCount = 10; state.lastReadAt = Date()
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        let library = LibraryModel(remoteHistory: history)
        let refreshed = expectation(description: "Home observes reset streamed history")
        withObservationTracking {
            XCTAssertEqual(SmartCollectionKind.homeShelves(in: library).count, 2)
        } onChange: {
            refreshed.fulfill()
        }
        library.resetState(comic, removingChapters: removingChapters)
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertTrue(SmartCollectionKind.homeShelves(in: library).isEmpty)
        XCTAssertTrue(RemoteReadingHistory(fileURL: historyURL).issues.isEmpty)
        let saved = CentralStore.loadState(forKey: key)
        XCTAssertNil(saved?.lastIndex)
        XCTAssertNil(saved?.lastReadAt)
        if removingChapters {
            XCTAssertNil(saved)
        } else {
            XCTAssertEqual(saved?.chapters, state.chapters)
            XCTAssertEqual(saved?.chapterNames, state.chapterNames)
        }
        // Reading again creates a fresh entry, rather than permanently hiding the issue.
        history.record(comic)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        XCTAssertEqual(library.continueReading.map(\.id), [comic.id])
    }

    @MainActor
    func testStreamedReadingHistoryAppearsInSmartCollectionsAndSurvivesReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let historyURL = directory.appendingPathComponent("history.json")
        let history = RemoteReadingHistory(fileURL: historyURL)
        var stateURLs: [URL] = []
        defer {
            try? FileManager.default.removeItem(at: directory)
            for url in stateURLs { try? FileManager.default.removeItem(at: url) }
        }
        func record(title: String, index: Int?, readAt: Date) throws -> Comic {
            let url = URL(string: "https://fixture.invalid/comic/\(UUID().uuidString)")!
            let pages = (1...10).map { URL(string: "https://fixture.invalid/pages/\($0).jpg")! }
            let comic = Comic(url: url, series: "Series", isArchive: false, coverURL: pages.first,
                              pageCount: pages.count, progress: nil, chapterCount: 0,
                              metaTitle: title, tooltip: nil, remotePages: pages)
            history.record(comic)
            var state = ComicState()
            state.lastIndex = index; state.pageCount = pages.count; state.lastReadAt = readAt
            state.lastPage = index.map { pages[$0].absoluteString }
            state.chapters = index == nil ? [pages[0].absoluteString] : []
            let destination = CentralStore.stateURL(for: CentralStore.key(for: url))
            stateURLs.append(destination)
            try JSONEncoder().encode(state).write(to: destination, options: .atomic)
            return comic
        }
        let started = try record(title: "In progress", index: 3, readAt: Date(timeIntervalSince1970: 100))
        let finished = try record(title: "Finished", index: 9, readAt: Date(timeIntervalSince1970: 200))
        let opened = try record(title: "Just opened", index: 0, readAt: Date(timeIntervalSince1970: 50))
        _ = try record(title: "Reset, chapters kept", index: nil, readAt: Date())

        let reloaded = RemoteReadingHistory(fileURL: historyURL)
        let library = LibraryModel(remoteHistory: reloaded)
        let continuing = SmartCollectionKind.continueReading.comics(in: library)
        XCTAssertEqual(continuing.map(\.id), [started.id])
        XCTAssertEqual(continuing.first?.progress?.page, 4)
        XCTAssertEqual(continuing.first?.remotePages?.map { PluginResourceRegistry.shared.request(for: $0).url }, started.remotePages)
        XCTAssertEqual(continuing.first?.coverURL.map { PluginResourceRegistry.shared.request(for: $0).url }, started.coverURL)
        XCTAssertEqual(SmartCollectionKind.recentlyRead.comics(in: library).map(\.id),
                       [finished.id, started.id, opened.id])
        XCTAssertTrue(SmartCollectionKind.unread.comics(in: library).isEmpty)
        let shelves = SmartCollectionKind.homeShelves(in: library)
        XCTAssertEqual(shelves.first { $0.kind == .continueReading }?.comics.map(\.id), [started.id])
        XCTAssertEqual(shelves.first { $0.kind == .recentlyRead }?.comics.map(\.id),
                       [finished.id, started.id, opened.id])
    }

    func testSmartCollectionKindsExposeStablePresentation() {
        XCTAssertEqual(
            SmartCollectionKind.allCases.map(\.rawValue),
            [
                "continueReading",
                "recentlyRead",
                "unread",
                "completed",
                "withChapters",
                "recentlyAdded"
            ]
        )

        XCTAssertEqual(SmartCollectionKind.continueReading.title, "Continue Reading")
        XCTAssertEqual(SmartCollectionKind.recentlyRead.title, "Recently Read")
        XCTAssertEqual(SmartCollectionKind.unread.title, "Unread")
        XCTAssertEqual(SmartCollectionKind.completed.title, "Completed")
        XCTAssertEqual(SmartCollectionKind.withChapters.title, "With Chapters")
        XCTAssertEqual(SmartCollectionKind.recentlyAdded.title, "Recently Added")
    }

    func testSmartCollectionPresentationHasIconsAndDescriptions() {
        for kind in SmartCollectionKind.allCases {
            XCTAssertFalse(kind.icon.isEmpty)
            XCTAssertFalse(kind.subtitle.isEmpty)
        }
    }
}
