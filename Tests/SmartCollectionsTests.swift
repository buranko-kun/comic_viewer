import XCTest

@testable import ComicViewer

final class SmartCollectionsTests: XCTestCase {
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
