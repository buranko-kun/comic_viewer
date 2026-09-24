import XCTest

@testable import ComicViewer

@MainActor
final class ReaderStateStoreTests: XCTestCase {
    private var comicKey: String!
    private var stateURL: URL!

    override func setUp() {
        super.setUp()
        comicKey = "/tmp/ComicViewerTests/state-" + UUID().uuidString
        stateURL = CentralStore.stateURL(for: comicKey)
        try? FileManager.default.removeItem(at: stateURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateURL)
        stateURL = nil
        comicKey = nil
        super.tearDown()
    }

    func testSaveAndLoadRoundTrip() {
        let store = ReaderStateStore()
        store.configure(comicKey: comicKey, legacyStateURLs: [])

        let state = ComicState(
            version: 3,
            chapters: ["page-2.jpg"],
            chapterNames: ["page-2.jpg": "Chapter Two"],
            lastPage: "page-3.jpg",
            lastIndex: 2,
            pageCount: 3,
            manualRotate: nil,
            path: comicKey
        )

        store.save(state)
        let loaded = store.load()

        XCTAssertFalse(loaded.migratedFromLegacy)
        XCTAssertEqual(loaded.state?.chapters, state.chapters)
        XCTAssertEqual(loaded.state?.chapterNames, state.chapterNames)
        XCTAssertEqual(loaded.state?.lastPage, state.lastPage)
        XCTAssertEqual(loaded.state?.lastIndex, state.lastIndex)
        XCTAssertEqual(loaded.state?.pageCount, state.pageCount)
    }

    func testLegacySidecarIsLoadedAndMarkedForMigration() throws {
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicViewerLegacy-" + UUID().uuidString + ".comicviewer.json")
        defer { try? FileManager.default.removeItem(at: legacyURL) }

        let data = Data(#"{ "version": 1, "chapters": ["page-2.jpg"] }"#.utf8)
        try data.write(to: legacyURL, options: .atomic)

        let store = ReaderStateStore()
        store.configure(
            comicKey: comicKey,
            legacyStateURLs: [legacyURL]
        )

        let loaded = store.load()

        XCTAssertTrue(loaded.migratedFromLegacy)
        XCTAssertEqual(loaded.state?.chapters, ["page-2.jpg"])
    }

    func testConfigureCancelsPendingSaveForPreviousComic() async {
        let firstKey = comicKey!
        let secondKey = "/tmp/ComicViewerTests/state-" + UUID().uuidString

        let store = ReaderStateStore()
        store.configure(comicKey: firstKey, legacyStateURLs: [])

        let first = ComicState(
            version: 3,
            chapters: [],
            chapterNames: [:],
            lastPage: "page-1.jpg",
            lastIndex: 0,
            pageCount: 1,
            manualRotate: nil,
            path: firstKey
        )
        store.scheduleSave(first)

        store.configure(comicKey: secondKey, legacyStateURLs: [])

        try? await Task.sleep(for: .seconds(0.8))

        XCTAssertFalse(FileManager.default.fileExists(atPath: CentralStore.stateURL(for: firstKey).path))
        try? FileManager.default.removeItem(at: CentralStore.stateURL(for: secondKey))
    }
}
