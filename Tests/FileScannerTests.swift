import XCTest

@testable import ComicViewer

final class FileScannerTests: XCTestCase {
    func testSortedUsesNaturalNumericOrderWithMixedCaseFilenames() {
        let urls = [
            URL(fileURLWithPath: "/tmp/page10.jpg"),
            URL(fileURLWithPath: "/tmp/PAGE1.jpg"),
            URL(fileURLWithPath: "/tmp/page3.jpg"),
            URL(fileURLWithPath: "/tmp/Page2.jpg")
        ]

        let sorted = FileScanner.sorted(urls)

        XCTAssertEqual(
            sorted.map { $0.lastPathComponent.lowercased() },
            ["page1.jpg", "page2.jpg", "page3.jpg", "page10.jpg"]
        )
    }
}
