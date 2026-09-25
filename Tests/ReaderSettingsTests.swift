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

    func testTimelineScopeLabels() {
        XCTAssertEqual(ReaderSettings.TimelineScope.chapter.label, "Chapter")
        XCTAssertEqual(ReaderSettings.TimelineScope.issue.label, "Issue")
        XCTAssertEqual(ReaderSettings.TimelineScope.series.label, "Series")
    }

    func testTimelineSettingsPersistThroughUserDefaults() {
        let settings = ReaderSettings.shared
        let previousScope = settings.timelineScope
        let previousMarkers = settings.showChapterMarkers
        defer {
            settings.timelineScope = previousScope
            settings.showChapterMarkers = previousMarkers
        }

        settings.timelineScope = .series
        settings.showChapterMarkers = false

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "reader.timelineScope"),
            "series"
        )
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: "reader.showChapterMarkers") as? Bool,
            false
        )

        settings.timelineScope = .chapter
        settings.showChapterMarkers = true
    }

    func testSpreadSettingsPersistThroughUserDefaults() {
        let settings = ReaderSettings.shared
        let previousCover = settings.coverAloneInSpread
        let previousGutter = settings.spreadGutter
        defer {
            settings.coverAloneInSpread = previousCover
            settings.spreadGutter = previousGutter
        }

        settings.coverAloneInSpread = false
        settings.spreadGutter = 24

        XCTAssertEqual(
            UserDefaults.standard.object(forKey: "reader.coverAloneInSpread") as? Bool,
            false
        )
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: "reader.spreadGutter") as? Double,
            24
        )
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
