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
