import Foundation
import Network
import SwiftTorrent

/// A lightweight BitTorrent v1 seeder for existing ComicViewer files.
///
/// One TCP listener can seed multiple torrents. The server only reads from the source files and
/// never mutates them. Incoming peers must present the matching torrent info hash before receiving
/// any data.
@MainActor
final class TorrentSeedServer {
    static let shared = TorrentSeedServer()
    nonisolated static let defaultPort: UInt16 = 6881

    struct SeedContext: Sendable {
        let info: TorrentInfo
        let sourceURL: URL
        /// Exact bencoded "info" dictionary bytes used to calculate the info hash.
        let metadata: Data
    }

    var isRunning: Bool { listener != nil }
    private(set) var port: UInt16 = defaultPort
    private(set) var lastError: String?

    private var listener: NWListener?
    private var seeds: [String: SeedContext] = [:]
    private var peers: [UUID: TorrentSeedPeer] = [:]
    private var peerHashes: [UUID: String] = [:]
    private var uploadedByHash: [String: Int64] = [:]
    private var rateSamples: [String: (date: Date, bytes: Int64)] = [:]
    private let peerID = generatePeerID()

    var peerCount: Int { peers.count }

    var onUpload: ((String, Int64) -> Void)?

    func peerCount(for infoHash: String) -> Int {
        peerHashes.values.filter { $0 == infoHash }.count
    }

    func uploadedBytes(for infoHash: String) -> Int64 {
        uploadedByHash[infoHash] ?? 0
    }

    func uploadRate(for infoHash: String) -> Double {
        let currentBytes = uploadedByHash[infoHash] ?? 0
        let now = Date()

        guard let sample = rateSamples[infoHash] else {
            rateSamples[infoHash] = (now, currentBytes)
            return 0
        }

        let elapsed = now.timeIntervalSince(sample.date)
        guard elapsed > 0 else { return 0 }

        rateSamples[infoHash] = (now, currentBytes)
        return Double(max(0, currentBytes - sample.bytes)) / elapsed
    }

    func recordExternalUpload(infoHash: String, bytes: Int64) {
        uploadedByHash[infoHash, default: 0] += bytes
    }

    func start(port: UInt16 = defaultPort) throws {
        guard listener == nil else { return }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SeedServerError.invalidPort(port)
        }

        do {
            let newListener = try NWListener(using: .tcp, on: nwPort)
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { @MainActor in
                        self?.lastError = nil
                    }
                case .failed(let error):
                    Task { @MainActor in
                        self?.lastError = error.localizedDescription
                        self?.listener?.cancel()
                        self?.listener = nil
                    }
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let id = UUID()
                Task { @MainActor in
                    let peer = TorrentSeedPeer(
                        id: id,
                        connection: connection,
                        peerID: self.peerID,
                        resolveSeed: { [weak self] hash in
                            await self?.seedContext(for: hash)
                        },
                        onReady: { [weak self] id, hash in
                            Task { @MainActor in
                                self?.peerHashes[id] = hash
                            }
                        },
                        onUpload: { [weak self] id, bytes in
                            Task { @MainActor in
                                guard let self, let hash = self.peerHashes[id] else { return }
                                self.recordExternalUpload(infoHash: hash, bytes: bytes)
                                self.onUpload?(hash, bytes)
                            }
                        },
                        onClosed: { [weak self] id in
                            Task { @MainActor in
                                self?.peers.removeValue(forKey: id)
                                self?.peerHashes.removeValue(forKey: id)
                            }
                        }
                    )
                    self.peers[id] = peer
                    peer.start()
                }
            }

            listener = newListener
            self.port = port
            newListener.start(queue: DispatchQueue(label: "ComicViewer.TorrentSeedListener"))
        } catch {
            throw SeedServerError.listener(error.localizedDescription)
        }
    }

    func addSeed(info: TorrentInfo, sourceURL: URL, metadata: Data) {
        let id = info.infoHash.description
        guard InfoHash.v1(from: metadata) == info.infoHash else {
            assertionFailure("Seed metadata does not match torrent info hash")
            return
        }
        seeds[id] = SeedContext(
            info: info,
            sourceURL: sourceURL.standardizedFileURL,
            metadata: metadata
        )
        uploadedByHash[id, default: 0] = uploadedByHash[id, default: 0]
        rateSamples[id] = (Date(), uploadedByHash[id] ?? 0)
    }

    func removeSeed(infoHash: String) {
        seeds.removeValue(forKey: infoHash)
        uploadedByHash.removeValue(forKey: infoHash)
        rateSamples.removeValue(forKey: infoHash)

        let affected = peerHashes.compactMap { $0.value == infoHash ? $0.key : nil }
        for id in affected {
            peers[id]?.cancel()
            peers.removeValue(forKey: id)
            peerHashes.removeValue(forKey: id)
        }

        if seeds.isEmpty {
            listener?.cancel()
            listener = nil
        }
    }

    private func seedContext(for hash: Data) -> SeedContext? {
        guard hash.count == 20 else { return nil }
        let key = InfoHash(bytes: hash).description
        return seeds[key]
    }
}

private final class TorrentSeedPeer: @unchecked Sendable {
    private let id: UUID
    private let connection: NWConnection
    private let peerID: Data
    private let resolveSeed: @Sendable (Data) async -> TorrentSeedServer.SeedContext?
    private let onReady: @Sendable (UUID, String) -> Void
    private let onUpload: @Sendable (UUID, Int64) -> Void
    private let onClosed: @Sendable (UUID) -> Void
    private let queue: DispatchQueue

    private var receiveBuffer = Data()
    private var seed: TorrentSeedServer.SeedContext?
    private var peerMetadataID: UInt8?
    private var closed = false

    init(
        id: UUID,
        connection: NWConnection,
        peerID: Data,
        resolveSeed: @escaping @Sendable (Data) async -> TorrentSeedServer.SeedContext?,
        onReady: @escaping @Sendable (UUID, String) -> Void,
        onUpload: @escaping @Sendable (UUID, Int64) -> Void,
        onClosed: @escaping @Sendable (UUID) -> Void
    ) {
        self.id = id
        self.connection = connection
        self.peerID = peerID
        self.resolveSeed = resolveSeed
        self.onReady = onReady
        self.onUpload = onUpload
        self.onClosed = onClosed
        self.queue = DispatchQueue(label: "ComicViewer.TorrentPeer.\(id.uuidString)")
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.finish()
            } else if case .cancelled = state {
                self?.finish()
            }
        }
        connection.start(queue: queue)
        receiveHandshake()
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveHandshake() {
        receive(maximum: Handshake.length) { [weak self] in
            self?.receiveHandshakeChunk($0)
        }
    }

    private func receiveHandshakeChunk(_ data: Data?) {
        if let data { receiveBuffer.append(data) }

        guard receiveBuffer.count < Handshake.length else {
            let handshakeData = Data(receiveBuffer.prefix(Handshake.length))
            receiveBuffer.removeFirst(Handshake.length)

            do {
                let handshake = try Handshake.decode(from: handshakeData)
                Task { [weak self] in
                    guard let self, let seed = await self.resolveSeed(handshake.infoHash) else {
                        self?.finish()
                        return
                    }
                    self.queue.async {
                        self.seed = seed
                        print("[TorrentSeedPeer] handshake accepted hash=\(seed.info.infoHash.description) pieces=\(seed.info.pieceCount) pieceLength=\(seed.info.pieceLength) totalSize=\(seed.info.totalSize)")
                        self.onReady(self.id, seed.info.infoHash.description)
                        self.sendInitialState(seed: seed)
                    }
                }
            } catch {
                finish()
            }
            return
        }

        receiveHandshake()
    }

    private func sendInitialState(seed: TorrentSeedServer.SeedContext) {
        // Advertise and initialize BEP-10 because magnet clients such as qBittorrent
        // need BEP-9 ut_metadata to obtain the torrent info dictionary before they can
        // evaluate piece availability.
        let response = Handshake(
            infoHash: seed.info.infoHash.bytes,
            peerID: peerID,
            reserved: Handshake.defaultReserved()
        ).encode()
        send(response)

        let metadataHandshake = TorrentMetadataWire.extendedHandshake(
            metadataSize: seed.metadata.count
        )
        print("[TorrentSeedPeer] sending ut_metadata handshake metadataSize=(seed.metadata.count)")
        send(PeerMessage.extended(id: TorrentMetadataWire.localExtensionID, payload: metadataHandshake).encode())

        if seed.info.pieceCount > 0 {
            let bitfield = allPieces(count: seed.info.pieceCount)
            print("[TorrentSeedPeer] sending bitfield bytes=\(bitfield.count) hex=\(bitfield.map { String(format: "%02x", $0) }.joined())")
            send(PeerMessage.bitfield(bitfield).encode())
        }
        print("[TorrentSeedPeer] sending unchoke")
        send(PeerMessage.unchoke.encode())
        receiveMessages()
    }

    private func receiveMessages() {
        receive(maximum: 64 * 1024) { [weak self] data in
            guard let self else { return }
            if let data { self.receiveBuffer.append(data) }
            self.processFrames()

            if self.closed { return }
            self.receiveMessages()
        }
    }

    private func processFrames() {
        while receiveBuffer.count >= 4 {
            let length = Int(receiveBuffer.readUInt32BE(at: 0))

            guard length <= 2 * 1024 * 1024 else {
                finish()
                return
            }

            guard receiveBuffer.count >= 4 + length else {
                return
            }

            let base = receiveBuffer.startIndex
            let payloadStart = base + 4
            let payloadEnd = payloadStart + length
            let payload = Data(receiveBuffer[payloadStart..<payloadEnd])
            receiveBuffer.removeFirst(4 + length)

            guard length > 0 else {
                continue
            }

            guard let message = try? PeerMessage.decode(from: payload) else {
                print("[TorrentSeedPeer] failed to decode peer frame length=\(length) payload=\(payload.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))")
                continue
            }

            print("[TorrentSeedPeer] received \(message)")
            handle(message)
            if closed { return }
        }
    }

    private func handle(_ message: PeerMessage) {
        guard let seed else { return }

        switch message {
        case .extended(let extensionID, let payload):
            guard let seed else { return }

            if extensionID == TorrentMetadataWire.handshakeExtensionID {
                if let peerID = TorrentMetadataWire.peerMetadataExtensionID(from: payload) {
                    peerMetadataID = peerID
                    print("[TorrentSeedPeer] peer ut_metadata extension id=(peerID)")
                }
                return
            }

            guard let peerMetadataID, extensionID == peerMetadataID,
                  let requestPiece = TorrentMetadataWire.metadataRequestPiece(from: payload) else {
                return
            }

            guard let metadataResponse = TorrentMetadataWire.metadataResponse(
                piece: requestPiece,
                metadata: seed.metadata
            ) else {
                print("[TorrentSeedPeer] rejecting invalid metadata piece=(requestPiece)")
                return
            }

            print("[TorrentSeedPeer] sending ut_metadata piece=(requestPiece)")
            send(PeerMessage.extended(
                id: TorrentMetadataWire.localExtensionID,
                payload: metadataResponse
            ).encode())

        case .interested:
            print("[TorrentSeedPeer] peer is INTERESTED -> unchoking")
            send(PeerMessage.unchoke.encode())

        case .notInterested:
            print("[TorrentSeedPeer] peer is NOT INTERESTED")

        case .request(let index, let begin, let length):
            print("[TorrentSeedPeer] request index=\(index) begin=\(begin) length=\(length)")
            guard length > 0, length <= 16 * 1024 else { return }
            let pieceIndex = Int(index)
            let offset = Int(begin)
            guard pieceIndex >= 0, pieceIndex < seed.info.pieceCount else { return }

            let pieceSize = pieceSize(for: seed.info, index: pieceIndex)
            guard offset >= 0, offset + Int(length) <= pieceSize else { return }

            do {
                let block = try readBlock(
                    seed: seed,
                    pieceIndex: pieceIndex,
                    begin: offset,
                    length: Int(length)
                )
                print("[TorrentSeedPeer] sending piece index=\(index) begin=\(begin) bytes=\(block.count)")
                send(PeerMessage.piece(index: index, begin: begin, block: block).encode())
                onUpload(id, Int64(block.count))
            } catch {
                finish()
            }

        default:
            break
        }
    }

    private func receive(maximum: Int, _ completion: @escaping (Data?) -> Void) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: maximum
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard !self.closed else { return }

            if error != nil {
                self.finish()
                return
            }

            if let data {
                completion(data)
            } else if isComplete {
                self.finish()
            } else {
                completion(nil)
            }
        }
    }

    private func readBlock(
        seed: TorrentSeedServer.SeedContext,
        pieceIndex: Int,
        begin: Int,
        length: Int
    ) throws -> Data {
        let absoluteStart = Int64(pieceIndex) * Int64(seed.info.pieceLength) + Int64(begin)
        let absoluteEnd = absoluteStart + Int64(length)
        var output = Data()
        let sourceParent = seed.sourceURL.deletingLastPathComponent().standardizedFileURL
        let parentPrefix = sourceParent.path.hasSuffix("/") ? sourceParent.path : sourceParent.path + "/"

        for file in seed.info.files {
            let fileStart = file.offset
            let fileEnd = file.offset + file.length
            let overlapStart = max(absoluteStart, fileStart)
            let overlapEnd = min(absoluteEnd, fileEnd)
            guard overlapStart < overlapEnd else { continue }

            let fileURL = sourceParent
                .appendingPathComponent(file.path)
                .standardizedFileURL
            guard fileURL.path == sourceParent.path || fileURL.path.hasPrefix(parentPrefix) else {
                throw SeedError.unsafePath
            }

            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(overlapStart - fileStart))
            let bytes = try handle.read(upToCount: Int(overlapEnd - overlapStart)) ?? Data()
            guard bytes.count == Int(overlapEnd - overlapStart) else {
                throw SeedError.shortRead
            }
            output.append(bytes)
        }

        guard output.count == length else { throw SeedError.shortRead }
        return output
    }

    private func pieceSize(for info: TorrentInfo, index: Int) -> Int {
        let start = Int64(index) * Int64(info.pieceLength)
        return Int(min(Int64(info.pieceLength), info.totalSize - start))
    }

    private func allPieces(count: Int) -> Data {
        var data = Data(count: (count + 7) / 8)
        for i in 0..<count {
            data[i / 8] |= UInt8(1 << (7 - (i % 8)))
        }
        return data
    }

    private func send(_ data: Data) {
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.finish() }
        })
    }

    private func finish() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.connection.cancel()
            self.onClosed(self.id)
        }
    }
}

internal enum TorrentMetadataWire {
    static let handshakeExtensionID: UInt8 = 0
    static let localExtensionID: UInt8 = 1
    static let metadataPieceSize = 16 * 1024

    static func extendedHandshake(metadataSize: Int) -> Data {
        let encoder = BencodeEncoder()
        let value = BencodeValue.dictionary([
            (
                key: Data("m".utf8),
                value: .dictionary([
                    (key: Data("ut_metadata".utf8), value: .integer(Int64(localExtensionID)))
                ])
            ),
            (key: Data("metadata_size".utf8), value: .integer(Int64(metadataSize)))
        ])
        return encoder.encode(value)
    }

    static func peerMetadataExtensionID(from payload: Data) -> UInt8? {
        let decoder = BencodeDecoder()
        guard let value = try? decoder.decode(payload),
              let extensions = value["m"],
              let extensionID = extensions["ut_metadata"]?.integerValue,
              extensionID >= 0,
              extensionID <= Int64(UInt8.max) else {
            return nil
        }
        return UInt8(extensionID)
    }

    static func metadataRequestPiece(from payload: Data) -> Int? {
        let decoder = BencodeDecoder()
        guard let value = try? decoder.decode(payload),
              value["msg_type"]?.integerValue == 0,
              let piece = value["piece"]?.integerValue,
              piece >= 0,
              piece <= Int64(Int.max) else {
            return nil
        }
        return Int(piece)
    }

    static func metadataResponse(piece: Int, metadata: Data) -> Data? {
        guard piece >= 0 else { return nil }

        let multiplication = piece.multipliedReportingOverflow(by: metadataPieceSize)
        guard !multiplication.overflow, multiplication.partialValue < metadata.count else {
            return nil
        }
        let start = multiplication.partialValue
        let end = min(start + metadataPieceSize, metadata.count)
        let block = metadata[start..<end]

        let encoder = BencodeEncoder()
        let header = encoder.encode(.dictionary([
            (key: Data("msg_type".utf8), value: .integer(1)),
            (key: Data("piece".utf8), value: .integer(Int64(piece))),
            (key: Data("total_size".utf8), value: .integer(Int64(metadata.count)))
        ]))

        var payload = header
        payload.append(block)
        return payload
    }

    static func extractInfoDictionary(from torrentData: Data, matching infoHash: InfoHash) throws -> Data {
        let key = Data("4:info".utf8)
        let decoder = BencodeDecoder()
        var searchStart = torrentData.startIndex

        while searchStart < torrentData.endIndex,
              let keyRange = torrentData.range(of: key, options: [], in: searchStart..<torrentData.endIndex) {
            let valueStart = keyRange.upperBound
            let suffix = Data(torrentData[valueStart...])

            if let (value, range) = try? decoder.decodeWithRange(suffix),
               case .dictionary = value {
                let candidate = Data(suffix[range])
                if InfoHash.v1(from: candidate) == infoHash {
                    return candidate
                }
            }

            searchStart = valueStart
        }

        throw TorrentInfoError.invalidFormat("Unable to extract raw info dictionary")
    }
}

private enum SeedServerError: LocalizedError {
    case invalidPort(UInt16)
    case listener(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port): return "Invalid BitTorrent listen port: \(port)."
        case .listener(let message): return "Couldn't start BitTorrent listener: \(message)"
        }
    }
}

private enum SeedError: Error {
    case unsafePath
    case shortRead
}

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { buffer in
            copyBytes(to: buffer, from: start..<start + 4)
        }
        return UInt32(bigEndian: value)
    }
}