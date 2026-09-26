import XCTest

@testable import ComicViewer

final class ReaderNavigationTests: XCTestCase {
    func testSetIndexNormalizesToSpreadStart() {
        var navigation = ReaderNavigation()
        let pages = makePages(count: 4)

        navigation.configure(items: pages, folder: nil, coverAloneInSpread: false)

        XCTAssertTrue(navigation.goTo(index: 3))
        XCTAssertEqual(navigation.index, 3)

        XCTAssertEqual(navigation.toggleSpread(), "Two-page spread")
        XCTAssertEqual(navigation.index, 2)

        let state = navigation.makeState(comicKey: nil)
        XCTAssertEqual(state.lastPage, pages[3].absoluteString)
    }

    func testCoverAloneSpreadUsesCoverThenPairs() {
        var navigation = ReaderNavigation()
        let pages = makePages(count: 6)

        navigation.configure(items: pages, folder: nil, coverAloneInSpread: true)

        XCTAssertEqual(navigation.goTo(index: 0), true)
        XCTAssertEqual(navigation.toggleSpread(), "Two-page spread")
        XCTAssertEqual(navigation.index, 0)
        XCTAssertNil(navigation.secondaryIndex)

        XCTAssertTrue(navigation.next())
        XCTAssertEqual(navigation.index, 1)
        XCTAssertEqual(navigation.secondaryIndex, 2)

        XCTAssertTrue(navigation.next())
        XCTAssertEqual(navigation.index, 3)
        XCTAssertEqual(navigation.secondaryIndex, 4)

        XCTAssertTrue(navigation.goTo(index: 5))
        XCTAssertEqual(navigation.index, 5)
        XCTAssertNil(navigation.secondaryIndex)

        XCTAssertTrue(navigation.prev())
        XCTAssertEqual(navigation.index, 3)

        XCTAssertTrue(navigation.goTo(index: 2))
        XCTAssertEqual(navigation.index, 1)
        XCTAssertEqual(navigation.secondaryIndex, 2)

        XCTAssertTrue(navigation.prev())
        XCTAssertEqual(navigation.index, 0)
    }

    func testExplicitSpreadStatePreservesLogicalResumePage() {
        var navigation = ReaderNavigation()
        let pages = makePages(count: 5)

        navigation.configure(items: pages, folder: nil, coverAloneInSpread: true)
        XCTAssertTrue(navigation.goTo(index: 2))
        XCTAssertTrue(navigation.setSpreadEnabled(true))
        XCTAssertEqual(navigation.index, 1)

        let state = navigation.makeState(comicKey: nil)
        XCTAssertEqual(state.lastPage, pages[2].absoluteString)

        XCTAssertTrue(navigation.setSpreadEnabled(false))
        XCTAssertEqual(navigation.index, 2)
    }

    func testWidePagesStayStandaloneAndNavigationDoesNotSkip() {
        var navigation = ReaderNavigation()
        let pages = makePages(count: 6)

        navigation.configure(items: pages, folder: nil, coverAloneInSpread: true)
        XCTAssertTrue(navigation.setSpreadEnabled(true))

        navigation.setPageWide(index: 2, isWide: true)

        XCTAssertTrue(navigation.goTo(index: 1))
        XCTAssertEqual(navigation.index, 1)
        XCTAssertNil(navigation.secondaryIndex)

        XCTAssertTrue(navigation.next())
        XCTAssertEqual(navigation.index, 2)
        XCTAssertNil(navigation.secondaryIndex)

        XCTAssertTrue(navigation.next())
        XCTAssertEqual(navigation.index, 3)
        XCTAssertEqual(navigation.secondaryIndex, 4)

        XCTAssertTrue(navigation.prev())
        XCTAssertEqual(navigation.index, 2)

        navigation.setPageWide(index: 3, isWide: true)
        XCTAssertTrue(navigation.goTo(index: 4))
        XCTAssertEqual(navigation.index, 4)
        XCTAssertNil(navigation.secondaryIndex)
    }

    func testDisablingSpreadRestoresLogicalResumePage() {
        var navigation = ReaderNavigation()
        let pages = makePages(count: 5)

        navigation.configure(items: pages, folder: nil, coverAloneInSpread: true)
        XCTAssertTrue(navigation.goTo(index: 2))
        XCTAssertEqual(navigation.toggleSpread(), "Two-page spread")
        XCTAssertEqual(navigation.index, 1)

        XCTAssertEqual(navigation.toggleSpread(), "Single page")
        XCTAssertEqual(navigation.index, 2)
    }

    func testConfigurePreservesSpreadModeAcrossComicOpens() {
        var navigation = ReaderNavigation()
        let first = makePages(count: 4)
        let second = makePages(count: 3).map { $0.deletingLastPathComponent().appendingPathComponent("other-" + $0.lastPathComponent) }

        navigation.configure(items: first, folder: nil)
        XCTAssertEqual(navigation.toggleSpread(), "Two-page spread")
        XCTAssertTrue(navigation.spreadEnabled)

        navigation.configure(items: second, folder: nil)

        XCTAssertTrue(navigation.spreadEnabled)
        XCTAssertEqual(navigation.items, second)
        XCTAssertEqual(navigation.index, 0)
    }

    func testChapterOrderingUsesPageOrderAndCustomNames() {
        var navigation = ReaderNavigation()
        let pages = makePages(count: 5)

        navigation.configure(items: pages, folder: nil)

        XCTAssertEqual(navigation.goTo(index: 1), true)
        XCTAssertTrue(navigation.toggleChapter().contains("Chapter 1"))

        XCTAssertEqual(navigation.goTo(index: 4), true)
        XCTAssertTrue(navigation.toggleChapter().contains("Chapter 2"))

        navigation.renameChapter(atIndex: 4, to: "Finale")

        XCTAssertEqual(
            navigation.orderedChapters.map(\.name),
            ["Chapter 1", "Finale"]
        )
        XCTAssertEqual(
            navigation.chapterEntries.map(\.index),
            [1, 4]
        )
    }

    func testLoadStateMapsSavedPageAndChaptersToCurrentItems() {
        var navigation = ReaderNavigation()
        let pages = makePages(count: 3)

        let state = ComicState(
            version: 3,
            chapters: [pages[1].absoluteString],
            chapterNames: [pages[1].absoluteString: "Chapter Two"],
            lastPage: pages[2].absoluteString,
            lastIndex: 2,
            pageCount: 3,
            manualRotate: nil,
            path: nil
        )

        navigation.configure(items: pages, folder: nil)
        navigation.loadState(state)

        XCTAssertEqual(navigation.resumeIndex(), 2)
        XCTAssertEqual(navigation.orderedChapters.first?.name, "Chapter Two")
    }

    func testNavigationBoundariesDoNotMove() {
        var navigation = ReaderNavigation()
        let pages = makePages(count: 2)

        navigation.configure(items: pages, folder: nil)

        XCTAssertFalse(navigation.prev())
        XCTAssertEqual(navigation.index, 0)

        XCTAssertTrue(navigation.last())
        XCTAssertEqual(navigation.index, 1)

        XCTAssertFalse(navigation.next())
        XCTAssertEqual(navigation.index, 1)
    }

    private func makePages(count: Int) -> [URL] {
        (1...count).map {
            URL(fileURLWithPath: "/tmp/ComicViewerTests/page\($0).jpg")
        }
    }
}
