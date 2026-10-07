import Foundation
import CryptoKit
import SwiftTorrent

/// Creates standard BitTorrent v1 .torrent metadata from a local file or directory.
///
/// Piece data is hashed as a stream, so creating a torrent does not load the entire source into
/// memory. The generated info dictionary is deterministic for a given source tree, except for the
/// creation date which lives outside the info hash.
struct TorrentCreator {
    struct Result: Sendable {
        let data: Data
        /// Exact bencoded "info" dictionary bytes used for the torrent's v1 info hash.
        let infoDictionaryData: Data
        let info: TorrentInfo
        let magnet: String
        let sourceURL: URL
        let totalSize: Int64
        let pieceLength: Int
        let trackers: [String]
    }

    enum CreatorError: LocalizedError {
        case sourceMissing
        case sourceEmpty
        case unsupportedPath
        case invalidPieceLength
        case invalidTracker(String)
        case cannotReadFile(URL)

        var errorDescription: String? {
            switch self {
            case .sourceMissing: return "The selected source no longer exists."
            case .sourceEmpty: return "The selected source contains no files."
            case .unsupportedPath: return "The selected source is not a regular file or directory."
            case .invalidPieceLength: return "The torrent piece size is invalid."
            case .invalidTracker(let value): return "Invalid tracker URL: \(value)"
            case .cannotReadFile(let url): return "Couldn't read \(url.lastPathComponent)."
            }
        }
    }

    private struct SourceFile {
        let url: URL
        let relativePath: String
        let size: Int64
    }

    private indirect enum BencodeValue {
        case bytes(Data)
        case integer(Int64)
        case list([BencodeValue])
        case dictionary([(Data, BencodeValue)])
    }

    private static let defaultPieceLength = 256 * 1024

    static func create(
        sourceURL: URL,
        trackers: [String],
        pieceLength: Int = defaultPieceLength,
        comment: String? = nil
    ) throws -> Result {
        let source = sourceURL.standardizedFileURL
        let fm = FileManager.default
        var isDirectory = ObjCBool(false)

        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw CreatorError.sourceMissing
        }
        guard pieceLength > 0 else { throw CreatorError.invalidPieceLength }

        let files: [SourceFile]
        if isDirectory.boolValue {
            files = try enumerateDirectory(source)
        } else {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw CreatorError.unsupportedPath }
            let size = Int64(values.fileSize ?? 0)
            files = [SourceFile(url: source, relativePath: source.lastPathComponent, size: size)]
        }

        guard !files.isEmpty else { throw CreatorError.sourceEmpty }
        let totalSize = files.reduce(Int64(0)) { $0 + $1.size }

        let pieces = try hashPieces(files: files, pieceLength: pieceLength)

        var infoPairs: [(Data, BencodeValue)] = [
            (Data("name".utf8), .bytes(Data(source.lastPathComponent.utf8))),
            (Data("piece length".utf8), .integer(Int64(pieceLength))),
            (Data("pieces".utf8), .bytes(pieces))
        ]

        if isDirectory.boolValue {
            let fileValues = files.map { file in
                let components = file.relativePath.split(separator: "/").map { BencodeValue.bytes(Data($0.utf8)) }
                return BencodeValue.dictionary([
                    (Data("length".utf8), .integer(file.size)),
                    (Data("path".utf8), .list(components))
                ])
            }
            infoPairs.append((Data("files".utf8), .list(fileValues)))
        } else {
            infoPairs.append((Data("length".utf8), .integer(totalSize)))
        }

        let infoValue = BencodeValue.dictionary(infoPairs)
        let infoData = encode(infoValue)
        let normalizedTrackers = try normalizeTrackers(trackers)

        var rootPairs: [(Data, BencodeValue)] = [
            (Data("created by".utf8), .bytes(Data("ComicViewer".utf8))),
            (Data("creation date".utf8), .integer(Int64(Date().timeIntervalSince1970))),
            (Data("info".utf8), infoValue)
        ]

        if let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rootPairs.append((Data("comment".utf8), .bytes(Data(comment.utf8))))
        }

        if let first = normalizedTrackers.first {
            rootPairs.append((Data("announce".utf8), .bytes(Data(first.utf8))))
        }

        if !normalizedTrackers.isEmpty {
            let tiers = normalizedTrackers.map {
                BencodeValue.list([.bytes(Data($0.utf8))])
            }
            rootPairs.append((Data("announce-list".utf8), .list(tiers)))
        }

        let torrentData = encode(.dictionary(rootPairs))
        let parsed = try TorrentInfo.parse(from: torrentData)
        let hash = InfoHash.v1(from: infoData)
        guard parsed.infoHash == hash else {
            throw CreatorError.unsupportedPath
        }

        let magnet = MagnetLink(
            infoHash: hash,
            displayName: parsed.name,
            trackers: normalizedTrackers
        ).uri

        return Result(
            data: torrentData,
            infoDictionaryData: infoData,
            info: parsed,
            magnet: magnet,
            sourceURL: source,
            totalSize: totalSize,
            pieceLength: pieceLength,
            trackers: normalizedTrackers
        )
    }

    private static func enumerateDirectory(_ directory: URL) throws -> [SourceFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw CreatorError.sourceMissing
        }

        var files: [SourceFile] = []
        let rootPath = directory.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }

            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(prefix) else { continue }

            let relative = String(standardized.path.dropFirst(prefix.count))
            guard !relative.isEmpty else { continue }

            files.append(SourceFile(
                url: standardized,
                relativePath: relative,
                size: Int64(values.fileSize ?? 0)
            ))
        }

        return files.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private static func hashPieces(files: [SourceFile], pieceLength: Int) throws -> Data {
        var pending = Data()
        var pieces = Data()

        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file.url) else {
                throw CreatorError.cannotReadFile(file.url)
            }
            defer { try? handle.close() }

            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                pending.append(chunk)

                while pending.count >= pieceLength {
                    let hash = Insecure.SHA1.hash(data: pending.prefix(pieceLength))
                    pieces.append(contentsOf: hash)
                    pending = Data(pending.dropFirst(pieceLength))
                }
            }
        }

        if !pending.isEmpty {
            let hash = Insecure.SHA1.hash(data: pending)
            pieces.append(contentsOf: hash)
        }

        return pieces
    }

    private static func normalizeTrackers(_ trackers: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for raw in trackers {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("udp://") else {
                throw CreatorError.invalidTracker(value)
            }
            guard URL(string: value) != nil else {
                throw CreatorError.invalidTracker(value)
            }
            if seen.insert(value).inserted {
                result.append(value)
            }
        }

        return result
    }

    private static func encode(_ value: BencodeValue) -> Data {
        var output = Data()
        append(value, to: &output)
        return output
    }

    private static func append(_ value: BencodeValue, to output: inout Data) {
        switch value {
        case .bytes(let data):
            output.append(Data("\(data.count):".utf8))
            output.append(data)

        case .integer(let number):
            output.append(Data("i\(number)e".utf8))

        case .list(let values):
            output.append(0x6C)
            for value in values {
                append(value, to: &output)
            }
            output.append(0x65)

        case .dictionary(let pairs):
            output.append(0x64)
            let sorted = pairs.sorted { lhs, rhs in
                lexicographicallyPrecedes(lhs.0, rhs.0)
            }
            for (key, value) in sorted {
                output.append(Data("\(key.count):".utf8))
                output.append(key)
                append(value, to: &output)
            }
            output.append(0x65)
        }
    }

    private static func lexicographicallyPrecedes(_ lhs: Data, _ rhs: Data) -> Bool {
        let a = Array(lhs)
        let b = Array(rhs)
        for (x, y) in zip(a, b) where x != y {
            return x < y
        }
        return a.count < b.count
    }
}