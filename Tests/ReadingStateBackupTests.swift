import XCTest

@testable import ComicViewer

final class ReadingStateBackupTests: XCTestCase {
    func testEncodeAndDecodeRoundTripPreservesReadingState() throws {
        let state = ComicState(
            version: 3,
            chapters: ["02/page.jpg", "18/page.jpg"],
            chapterNames: ["02/page.jpg": "Chapter Two", "18/page.jpg": "Finale"],
            lastPage: "21/page.jpg",
            lastIndex: 20,
            pageCount: 24,
            manualRotate: true,
            path: "/Books/Series/Issue.cbz",
            lastReadAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let backup = ReadingStateBackup(
            libraryRoots: ["/Books"],
            entries: [
                .init(
                    path: "/Books/Series/Issue.cbz",
                    relativePaths: ["Series/Issue.cbz"],
                    state: state
                )
            ]
        )

        let data = try ReadingStateBackup.encode(backup)
        let decoded = try ReadingStateBackup.decode(data)

        XCTAssertEqual(decoded.format, ReadingStateBackup.format)
        XCTAssertEqual(decoded.version, ReadingStateBackup.currentVersion)
        XCTAssertEqual(decoded.libraryRoots, ["/Books"])
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries.first?.path, "/Books/Series/Issue.cbz")
        XCTAssertEqual(decoded.entries.first?.relativePaths, ["Series/Issue.cbz"])
        XCTAssertEqual(decoded.entries.first?.state.chapters, state.chapters)
        XCTAssertEqual(decoded.entries.first?.state.chapterNames, state.chapterNames)
        XCTAssertEqual(decoded.entries.first?.state.lastPage, state.lastPage)
        XCTAssertEqual(decoded.entries.first?.state.lastIndex, state.lastIndex)
        XCTAssertEqual(decoded.entries.first?.state.pageCount, state.pageCount)
        XCTAssertEqual(decoded.entries.first?.state.manualRotate, state.manualRotate)
        XCTAssertEqual(decoded.entries.first?.state.path, state.path)
        XCTAssertEqual(decoded.entries.first?.state.lastReadAt, state.lastReadAt)
    }

    func testRelativePathsAreCapturedForContainingRootsOnly() {
        let roots = ["/Books", "/Volumes/Comics"]
        let paths = ReadingStateBackup.relativePaths(
            for: "/Books/Marvel/Spider-Man.cbz",
            roots: roots
        )

        XCTAssertEqual(paths, ["Marvel/Spider-Man.cbz"])

        let outside = ReadingStateBackup.relativePaths(
            for: "/Bookshelf/Spider-Man.cbz",
            roots: roots
        )
        XCTAssertTrue(outside.isEmpty)
    }

    func testImportPlanRemapsMovedLibraryRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingStateBackupTests-" + UUID().uuidString)
        let currentRoot = root.appendingPathComponent("Current")
        let comic = currentRoot
            .appendingPathComponent("Marvel", isDirectory: true)
            .appendingPathComponent("Issue.cbz")
        try FileManager.default.createDirectory(
            at: comic.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: comic)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = ComicState(
            version: 3,
            chapters: ["001.jpg"],
            chapterNames: ["001.jpg": "Start"],
            lastPage: "008.jpg",
            lastIndex: 7,
            pageCount: 20,
            manualRotate: nil,
            path: "/OldBooks/Marvel/Issue.cbz",
            lastReadAt: Date()
        )
        let backup = ReadingStateBackup(
            libraryRoots: ["/OldBooks"],
            entries: [
                .init(
                    path: "/OldBooks/Marvel/Issue.cbz",
                    relativePaths: ["Marvel/Issue.cbz"],
                    state: state
                )
            ]
        )

        let plan = ReadingStateBackup.makeImportPlan(
            backup: backup,
            currentLibraryRoots: [currentRoot]
        )

        XCTAssertEqual(plan.items.count, 1)
        XCTAssertTrue(plan.ambiguous.isEmpty)
        XCTAssertTrue(plan.items[0].remapped)
        XCTAssertEqual(plan.items[0].destinationPath, comic.standardizedFileURL.path)
    }

    func testImportPlanPrefersExactExistingPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingStateBackupTests-" + UUID().uuidString)
        let comic = root
            .appendingPathComponent("Issue.cbz")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: comic)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = ComicState(path: comic.path)
        let backup = ReadingStateBackup(
            libraryRoots: [root.path],
            entries: [
                .init(
                    path: comic.path,
                    relativePaths: ["Issue.cbz"],
                    state: state
                )
            ]
        )

        let plan = ReadingStateBackup.makeImportPlan(
            backup: backup,
            currentLibraryRoots: [root]
        )

        XCTAssertEqual(plan.items.count, 1)
        XCTAssertFalse(plan.items[0].remapped)
        XCTAssertEqual(plan.items[0].destinationPath, comic.standardizedFileURL.path)
    }

    func testInvalidAndFutureBackupsAreRejected() throws {
        let invalid = Data(#"{ "format": "Something Else", "version": 1, "entries": [] }"#.utf8)
        XCTAssertThrowsError(try ReadingStateBackup.decode(invalid))

        let future = Data(#"{ "format": "ComicViewer Reading State", "version": 999, "entries": [{ "path": "/Books/Issue.cbz", "relativePaths": [], "state": { "path": "/Books/Issue.cbz" } }] }"#.utf8)
        XCTAssertThrowsError(try ReadingStateBackup.decode(future))
    }
}
