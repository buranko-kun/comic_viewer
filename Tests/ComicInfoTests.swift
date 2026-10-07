import XCTest

@testable import ComicViewer

final class ComicInfoTests: XCTestCase {
    func testComicVineVolumeIDRoundTripsThroughXML() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicInfoTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var info = ComicInfo()
        info.title = "Spider-Man"
        info.series = "Spider-Man"
        info.year = "2018"
        info.publisher = "Marvel"
        info.comicVineVolumeID = 123456

        XCTAssertTrue(info.write(forComic: dir, isArchive: false))

        let loaded = ComicInfo.load(fromFolder: dir)
        XCTAssertEqual(loaded?.title, "Spider-Man")
        XCTAssertEqual(loaded?.series, "Spider-Man")
        XCTAssertEqual(loaded?.comicVineVolumeID, 123456)
    }

    func testComicInfoJSONRoundTripIncludesComicVineVolumeID() throws {
        var info = ComicInfo()
        info.series = "Batman"
        info.comicVineVolumeID = 98765

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ComicInfo.self, from: data)

        XCTAssertEqual(decoded, info)
        XCTAssertEqual(decoded.comicVineVolumeID, 98765)
    }
}
