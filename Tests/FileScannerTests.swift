import XCTest

@testable import ComicViewer

final class FileScannerTests: XCTestCase {
    func testWebPPagesAreIncludedInFlatAndRecursiveScans() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("chapter", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["10.webp", "2.WEBP", "ComicInfo.xml"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        try Data([1]).write(to: nested.appendingPathComponent("1.webp"))
        XCTAssertEqual(FileScanner.scan(root).map(\.lastPathComponent), ["2.WEBP", "10.webp"])
        XCTAssertEqual(FileScanner.scanRecursive(root).count, 3)
        XCTAssertTrue(SupportedTypes.utTypes.contains(.webP))
        XCTAssertTrue(SupportedTypes.openPanelTypes.contains(.webP))
    }

    @MainActor
    func testDeleteFolderMovesEntireDirectoryAndPreservesSibling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Batman/Absolute Batman", isDirectory: true)
        let nested = folder.appendingPathComponent("Extras", isDirectory: true)
        let sibling = root.appendingPathComponent("Batman/Other series", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("issue.cbz"))
        try Data([2]).write(to: nested.appendingPathComponent("notes.txt"))
        let destination = root.appendingPathComponent("Trash/Absolute Batman", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var moved: [URL] = []
        try LibraryModel().deleteFolder(folder) { url in
            moved.append(url)
            try FileManager.default.moveItem(at: url, to: destination)
        }
        XCTAssertEqual(moved, [folder])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("issue.cbz").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Extras/notes.txt").path))
    }

    @MainActor
    func testDeleteFolderSurfacesFailureAndRejectsIndividualFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("issue.cbz")
        try Data([1]).write(to: file)
        let model = LibraryModel()
        XCTAssertThrowsError(try model.deleteFolder(folder) { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try model.deleteFolder(file) { _ in XCTFail("Must not trash a file through the folder action") })
    }

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
