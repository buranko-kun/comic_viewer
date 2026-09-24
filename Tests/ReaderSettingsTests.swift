import XCTest

@testable import ComicViewer

@MainActor
final class ReaderSettingsTests: XCTestCase {
    func testReadingDirectionValuesExposeExpectedPresentation() {
        XCTAssertEqual(
            ReaderSettings.ReadingDirection.leftToRight.label,
            "Left to right"
        )
        XCTAssertEqual(
            ReaderSettings.ReadingDirection.rightToLeft.label,
            "Right to left"
        )

        XCTAssertFalse(ReaderSettings.ReadingDirection.leftToRight.isRightToLeft)
        XCTAssertTrue(ReaderSettings.ReadingDirection.rightToLeft.isRightToLeft)
    }

    func testReadingDirectionControlsArrowAndSpreadSemantics() {
        let ltr = ReaderSettings.ReadingDirection.leftToRight
        XCTAssertTrue(ltr.rightArrowAdvances)
        XCTAssertEqual(ltr.arrangeSpread(1, 2).left, 1)
        XCTAssertEqual(ltr.arrangeSpread(1, 2).right, 2)

        let rtl = ReaderSettings.ReadingDirection.rightToLeft
        XCTAssertFalse(rtl.rightArrowAdvances)
        XCTAssertEqual(rtl.arrangeSpread(1, 2).left, 2)
        XCTAssertEqual(rtl.arrangeSpread(1, 2).right, 1)
    }

    func testReadingDirectionPersistsThroughUserDefaults() {
        let settings = ReaderSettings.shared
        let previous = settings.readingDirection
        defer { settings.readingDirection = previous }

        settings.readingDirection = .rightToLeft
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "reader.readingDirection"),
            "rightToLeft"
        )

        settings.readingDirection = .leftToRight
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "reader.readingDirection"),
            "leftToRight"
        )
    }
}
