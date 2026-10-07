import XCTest

@testable import ComicViewer

@MainActor
final class ReaderSessionTests: XCTestCase {
    private var session: ReaderSession!

    override func setUp() {
        super.setUp()
        session = ReaderSession()
    }

    override func tearDown() {
        session.cancel()
        session = nil
        super.tearDown()
    }

    func testBeginComicSetsExplicitStartIndex() {
        let pages = (1...3).map {
            URL(fileURLWithPath: "/tmp/ComicViewerTests/page\($0).jpg")
        }

        session.beginComic(
            items: pages,
            folder: nil,
            comicKey: nil,
            start: 1
        )

        XCTAssertEqual(session.items, pages)
        XCTAssertEqual(session.index, 1)
    }

    func testReaderPageSourceTypeDistinguishesRemoteAndLocal() {
        let local = ReaderPageSource.local(streamer: nil)
        let remote = ReaderPageSource.remote

        XCTAssertFalse(local.isRemote)
        XCTAssertTrue(remote.isRemote)
    }
    func testRetryFailedPageKeepsPositionAndLoadsRecoveredFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = directory.appendingPathComponent("page.png")
        session.beginComic(items: [page], folder: directory, comicKey: nil, start: 0)
        for _ in 0..<100 {
            if !session.isLoadingPage { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(session.canRetryPage)
        XCTAssertNil(session.current)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=")!
        try png.write(to: page)
        session.retryPage()
        for _ in 0..<100 {
            if !session.isLoadingPage { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(session.index, 0)
        XCTAssertEqual(session.items, [page])
        XCTAssertNotNil(session.current)
        XCTAssertNil(session.failedURL)
    }

}
