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

    func testSpreadNormalizesOddIndexWithoutChangingResumeTarget() {
        let pages = (1...4).map {
            URL(fileURLWithPath: "/tmp/ComicViewerTests/page\($0).jpg")
        }

        session.beginComic(
            items: pages,
            folder: nil,
            comicKey: nil,
            start: 1
        )

        let message = session.toggleSpread()

        XCTAssertEqual(message, "Two-page spread")
        XCTAssertTrue(session.spreadEnabled)
        XCTAssertEqual(session.index, 1)
    }

    func testReaderPageSourceTypeDistinguishesRemoteAndLocal() {
        let local = ReaderPageSource.local(streamer: nil)
        let remote = ReaderPageSource.remote

        XCTAssertFalse(local.isRemote)
        XCTAssertTrue(remote.isRemote)
    }
}
