import XCTest
import SwiftTorrent
@testable import ComicViewer

final class TorrentMetadataSeedingTests: XCTestCase {
    func testExtractsExactInfoDictionaryFromTorrent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicViewerTorrentMetadataTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Test Comic.cbz")
        try Data((0..<900_000).map { UInt8($0 % 251) }).write(to: source)

        let result = try TorrentCreator.create(
            sourceURL: source,
            trackers: [],
            pieceLength: 256 * 1024
        )

        let extracted = try TorrentMetadataWire.extractInfoDictionary(
            from: result.data,
            matching: result.info.infoHash
        )

        XCTAssertEqual(extracted, result.infoDictionaryData)
        XCTAssertEqual(InfoHash.v1(from: extracted), result.info.infoHash)
    }

    func testExtendedHandshakeAdvertisesUtMetadataAndSize() throws {
        let payload = TorrentMetadataWire.extendedHandshake(metadataSize: 12_345)
        let value = try BencodeDecoder().decode(payload)
        let wireMessage = PeerMessage.extended(
            id: TorrentMetadataWire.handshakeExtensionID,
            payload: payload
        ).encode()
        let decodedWireMessage = try PeerMessage.decode(
            from: Data(wireMessage.dropFirst(4))
        )

        XCTAssertEqual(
            decodedWireMessage,
            .extended(id: TorrentMetadataWire.handshakeExtensionID, payload: payload)
        )

        XCTAssertEqual(
            value["m"]?["ut_metadata"]?.integerValue,
            Int64(TorrentMetadataWire.localExtensionID)
        )
        XCTAssertEqual(value["metadata_size"]?.integerValue, 12_345)
    }

    func testMetadataRequestAndResponseUseBep9WireFormat() throws {
        let request = BencodeEncoder().encode(.dictionary([
            (key: Data("msg_type".utf8), value: .integer(0)),
            (key: Data("piece".utf8), value: .integer(1))
        ]))

        XCTAssertEqual(TorrentMetadataWire.metadataRequestPiece(from: request), 1)

        let metadata = Data((0..<20_000).map { UInt8($0 % 251) })
        let payload = try XCTUnwrap(
            TorrentMetadataWire.metadataResponse(piece: 1, metadata: metadata)
        )

        let (header, range) = try BencodeDecoder().decodeWithRange(payload)
        XCTAssertEqual(header["msg_type"]?.integerValue, 1)
        XCTAssertEqual(header["piece"]?.integerValue, 1)
        XCTAssertEqual(header["total_size"]?.integerValue, Int64(metadata.count))
        XCTAssertEqual(
            Data(payload[range]),
            Data(metadata.dropFirst(TorrentMetadataWire.metadataPieceSize))
        )
    }
}
