import XCTest
import CoreGraphics

@testable import ComicViewer

final class PageScrubberTests: XCTestCase {
    func testTargetIndexMapsAcrossLeftToRightTimeline() {
        XCTAssertEqual(
            PageScrubber.targetIndex(
                x: 0,
                width: 100,
                count: 11,
                direction: .leftToRight
            ),
            0
        )
        XCTAssertEqual(
            PageScrubber.targetIndex(
                x: 50,
                width: 100,
                count: 11,
                direction: .leftToRight
            ),
            5
        )
        XCTAssertEqual(
            PageScrubber.targetIndex(
                x: 100,
                width: 100,
                count: 11,
                direction: .leftToRight
            ),
            10
        )
    }

    func testTargetIndexReversesForRightToLeft() {
        XCTAssertEqual(
            PageScrubber.targetIndex(
                x: 0,
                width: 100,
                count: 11,
                direction: .rightToLeft
            ),
            10
        )
        XCTAssertEqual(
            PageScrubber.targetIndex(
                x: 100,
                width: 100,
                count: 11,
                direction: .rightToLeft
            ),
            0
        )
    }

    func testTargetClampsAtBounds() {
        XCTAssertEqual(
            PageScrubber.targetIndex(
                x: -20,
                width: 100,
                count: 10,
                direction: .leftToRight
            ),
            0
        )
        XCTAssertEqual(
            PageScrubber.targetIndex(
                x: 140,
                width: 100,
                count: 10,
                direction: .leftToRight
            ),
            9
        )
    }
}
