import XCTest
import SwiftTorrent
@testable import ComicViewer

final class TorrentCreatorTests: XCTestCase {
    func testCreatesValidSingleFileTorrent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicViewerTorrentTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Test Comic.cbz")
        let bytes = Data((0..<900_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)

        let result = try TorrentCreator.create(
            sourceURL: source,
            trackers: ["http://tracker.example/announce"],
            pieceLength: 256 * 1024,
            comment: "ComicViewer test"
        )

        XCTAssertEqual(result.sourceURL, source.standardizedFileURL)
        XCTAssertEqual(result.totalSize, Int64(bytes.count))
        XCTAssertEqual(result.info.name, "Test Comic.cbz")
        XCTAssertEqual(result.info.files.count, 1)
        XCTAssertEqual(result.info.files[0].length, Int64(bytes.count))
        XCTAssertEqual(result.info.pieceLength, 256 * 1024)
        XCTAssertEqual(result.infoHash, result.info.infoHash)
        XCTAssertEqual(result.trackers, ["http://tracker.example/announce"])

        let reparsed = try TorrentInfo.parse(from: result.data)
        XCTAssertEqual(reparsed.infoHash, result.info.infoHash)
        XCTAssertEqual(reparsed.totalSize, result.totalSize)
        XCTAssertEqual(reparsed.announceURL, "http://tracker.example/announce")
        XCTAssertEqual(reparsed.comment, "ComicViewer test")

        guard let magnet = MagnetLink(uri: result.magnet) else {
            XCTFail("Generated magnet should parse")
            return
        }

        XCTAssertEqual(magnet.infoHash, result.info.infoHash)
        XCTAssertEqual(magnet.displayName, result.info.name)
        XCTAssertEqual(magnet.trackers, ["http://tracker.example/announce"])
    }

    func testCreatesValidMultiFileTorrentWithPieceSpanningFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicViewerTorrentTest-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Series", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileA = source.appendingPathComponent("001.cbz")
        let fileB = source.appendingPathComponent("002.cbz")
        let dataA = Data(repeating: 0x11, count: 180_000)
        let dataB = Data(repeating: 0x22, count: 180_000)
        try dataA.write(to: fileA)
        try dataB.write(to: fileB)

        let result = try TorrentCreator.create(
            sourceURL: source,
            trackers: [],
            pieceLength: 256 * 1024
        )

        XCTAssertEqual(result.info.files.count, 2)
        XCTAssertEqual(result.info.files[0].length + result.info.files[1].length, Int64(360_000))
        XCTAssertEqual(result.info.pieceCount, 2)
        XCTAssertTrue(result.magnet.contains("magnet:?xt=urn:btih:"))
        XCTAssertTrue(result.info.files.allSatisfy { $0.path.hasPrefix("Series/") })
    }
}
