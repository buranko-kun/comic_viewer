import XCTest

@testable import ComicViewer

final class StorageScannerTests: XCTestCase {
    func testDuplicateComicPathsAreCountedOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageScanner-" + UUID().uuidString, isDirectory: true)
        let comicURL = root.appendingPathComponent("Series").appendingPathComponent("Issue", isDirectory: true)
        let pageURL = comicURL.appendingPathComponent("001.jpg")
        try FileManager.default.createDirectory(
            at: comicURL,
            withIntermediateDirectories: true
        )
        try Data(repeating: 7, count: 4096).write(to: pageURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let comic = Comic(
            url: comicURL,
            series: "Series",
            isArchive: false,
            coverURL: pageURL,
            pageCount: 1,
            progress: nil,
            chapterCount: 0,
            metaTitle: nil,
            tooltip: nil
        )

        let report = StorageScanner.scan(
            comics: [comic, comic],
            roots: [root]
        )

        XCTAssertEqual(report.comics.count, 1)
        XCTAssertGreaterThan(report.totalBytes, 0)
        XCTAssertEqual(report.totalBytes, report.comics[0].bytes)
    }

    func testOverlappingLibraryRootsDoNotDuplicateTheComic() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageScanner-" + UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("Library", isDirectory: true)
        let comicURL = parent.appendingPathComponent("Series").appendingPathComponent("Issue", isDirectory: true)
        let pageURL = comicURL.appendingPathComponent("001.jpg")

        try FileManager.default.createDirectory(at: comicURL, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 8192).write(to: pageURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let comic = Comic(
            url: comicURL,
            series: "Series",
            isArchive: false,
            coverURL: pageURL,
            pageCount: 1,
            progress: nil,
            chapterCount: 0,
            metaTitle: nil,
            tooltip: nil
        )

        let single = StorageScanner.scan(comics: [comic], roots: [parent])
        let overlapping = StorageScanner.scan(
            comics: [comic, comic],
            roots: [parent, parent.appendingPathComponent("Series", isDirectory: true)]
        )

        XCTAssertEqual(overlapping.comics.count, 1)
        XCTAssertEqual(overlapping.totalBytes, single.totalBytes)
    }

    func testNestedComicDoesNotGetCountedInsideParentFolderComic() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageScanner-" + UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("Series", isDirectory: true)
        let child = parent.appendingPathComponent("Issue", isDirectory: true)
        let parentPage = parent.appendingPathComponent("parent.jpg")
        let childPage = child.appendingPathComponent("001.jpg")

        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: parentPage)
        try Data(repeating: 2, count: 8192).write(to: childPage)
        defer { try? FileManager.default.removeItem(at: root) }

        let parentComic = Comic(
            url: parent,
            series: "Series",
            isArchive: false,
            coverURL: parentPage,
            pageCount: 1,
            progress: nil,
            chapterCount: 0,
            metaTitle: nil,
            tooltip: nil
        )
        let childComic = Comic(
            url: child,
            series: "Series",
            isArchive: false,
            coverURL: childPage,
            pageCount: 1,
            progress: nil,
            chapterCount: 0,
            metaTitle: nil,
            tooltip: nil
        )

        let report = StorageScanner.scan(
            comics: [parentComic, childComic],
            roots: [root]
        )
        let parentAlone = StorageScanner.scan(
            comics: [parentComic],
            roots: [root]
        )

        XCTAssertEqual(report.comics.count, 2)

        let parentBytes = report.comics.first(where: { $0.url == parent })?.bytes ?? 0
        let childBytes = report.comics.first(where: { $0.url == child })?.bytes ?? 0
        let parentAloneBytes = parentAlone.comics.first?.bytes ?? 0

        XCTAssertGreaterThan(parentBytes, 0)
        XCTAssertGreaterThan(childBytes, 0)
        XCTAssertGreaterThan(parentAloneBytes, parentBytes)
        XCTAssertEqual(parentAloneBytes, parentBytes + childBytes)
        XCTAssertEqual(report.totalBytes, parentBytes + childBytes)
    }
}
