import XCTest
@testable import ComicViewer

/// The correctness core: EXIF orientation → visual size / portrait decision, across
/// all 8 values plus edge cases. Values 5–8 (90°/270°) must swap width/height.
final class OrientationTests: XCTestCase {

    func testValues1to4DoNotSwap() {
        for exif in 1...4 {
            let v = Orientation.visualSize(pixelWidth: 1000, pixelHeight: 600, exif: exif)
            XCTAssertEqual(v.width, 1000, "exif \(exif)")
            XCTAssertEqual(v.height, 600, "exif \(exif)")
            XCTAssertFalse(Orientation.isPortrait(pixelWidth: 1000, pixelHeight: 600, exif: exif),
                           "exif \(exif) landscape pixels stay landscape")
        }
    }

    func testValues5to8Swap() {
        for exif in 5...8 {
            let v = Orientation.visualSize(pixelWidth: 1000, pixelHeight: 600, exif: exif)
            XCTAssertEqual(v.width, 600, "exif \(exif) swaps")
            XCTAssertEqual(v.height, 1000, "exif \(exif) swaps")
            // Landscape pixels + a 90/270 flag = a visually PORTRAIT image.
            XCTAssertTrue(Orientation.isPortrait(pixelWidth: 1000, pixelHeight: 600, exif: exif),
                          "exif \(exif) landscape pixels become portrait")
        }
    }

    func testPortraitPixelsUpright() {
        XCTAssertTrue(Orientation.isPortrait(pixelWidth: 600, pixelHeight: 1000, exif: 1))
    }

    func testPortraitPixelsWith90FlagBecomeLandscape() {
        // 600×1000 portrait pixels + orientation 6 → visual 1000×600 landscape.
        XCTAssertFalse(Orientation.isPortrait(pixelWidth: 600, pixelHeight: 1000, exif: 6))
    }

    func testSquareIsNotPortrait() {
        XCTAssertFalse(Orientation.isPortrait(pixelWidth: 800, pixelHeight: 800, exif: 1))
    }

    func testUnexpectedOrientationDefaultsToNoSwap() {
        let v = Orientation.visualSize(pixelWidth: 800, pixelHeight: 400, exif: 99)
        XCTAssertEqual(v.width, 800)
        XCTAssertEqual(v.height, 400)
    }
}
