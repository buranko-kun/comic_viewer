import XCTest

@testable import ComicViewer

final class ArchiveSessionManagerTests: XCTestCase {
    func testStaleRegistrationIsRejected() async {
        let manager = ArchiveSessionManager()
        let archive = makeURL("stale.cbz")
        let dir = makeDirectory("stale-session")

        let session = ArchiveSessionManager.Session(
            archive: archive,
            dir: dir,
            items: [],
            streamer: nil
        )

        await manager.beginRegistration(for: archive, token: 1)
        XCTAssertTrue(await manager.register(session, token: 1))

        await manager.beginRegistration(for: archive, token: 2)
        XCTAssertFalse(await manager.register(session, token: 1))

        await manager.cleanup()
    }

    func testReplacingSessionRemovesPreviousDirectory() async {
        let manager = ArchiveSessionManager()
        let archive = makeURL("replace.cbz")
        let firstDir = makeDirectory("first-session")
        let secondDir = makeDirectory("second-session")

        let first = ArchiveSessionManager.Session(
            archive: archive,
            dir: firstDir,
            items: [],
            streamer: nil
        )
        let second = ArchiveSessionManager.Session(
            archive: archive,
            dir: secondDir,
            items: [],
            streamer: nil
        )

        await manager.beginRegistration(for: archive, token: 1)
        XCTAssertTrue(await manager.register(first, token: 1))

        await manager.beginRegistration(for: archive, token: 2)
        XCTAssertTrue(await manager.register(second, token: 2))

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondDir.path))

        await manager.cleanup()
    }

    private func makeURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/ComicViewerTests/(name)")
    }

    private func makeDirectory(_ name: String) -> URL {
        let url = URL(fileURLWithPath: "/tmp/ComicViewerTests/(UUID().uuidString)-(name)")
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
