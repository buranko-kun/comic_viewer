import Foundation
import AppKit
import Observation
import SwiftTorrent

/// Persistent settings for BitTorrent sharing. HTTP(S) trackers are supported for the built-in
/// seeder; UDP trackers remain valid in created .torrent files and are supported by SwiftTorrent
/// when downloading.
@MainActor
@Observable
final class TorrentSettingsStore {
    static let shared = TorrentSettingsStore()

    private static let trackerKey = "torrentTrackerURLs"
    private static let portKey = "torrentListenPort"

    static let defaultTrackers = [
        "https://tracker.pmman.tech:443/announce",
        "https://tracker.zhuqiy.com:443/announce",
        "https://tr.nyacat.pw:443/announce"
    ]

    var trackerText: String {
        get {
            if let value = UserDefaults.standard.string(forKey: Self.trackerKey) {
                return value
            }
            return Self.defaultTrackers.joined(separator: "\n")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.trackerKey)
        }
    }

    var listenPort: UInt16 {
        get {
            let value = UserDefaults.standard.integer(forKey: Self.portKey)
            return value > 0 && value <= Int(UInt16.max) ? UInt16(value) : TorrentSeedServer.defaultPort
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: Self.portKey)
        }
    }

    var trackers: [String] {
        trackerText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func resetTrackers() {
        trackerText = Self.defaultTrackers.joined(separator: "\n")
    }
}

@MainActor
@Observable
final class TorrentManager {
    static let shared = TorrentManager()

    enum State: String, Sendable {
        case downloading
        case seeding
        case paused
        case error
    }

    struct Item: Identifiable, Equatable {
        let id: String
        var name: String
        let infoHash: String
        let magnet: String
        let totalSize: Int64
        var state: State
        var progress: Double
        var peers: Int
        var downloadRate: Double
        var uploadRate: Double
        var totalDownloaded: Int64
        var totalUploaded: Int64
        let sourceURL: URL?
        let torrentURL: URL?
        var error: String?
    }

    private struct StoredSeed: Codable, Sendable {
        let infoHash: String
        let sourcePath: String
        let torrentPath: String
        let trackers: [String]
    }

    private var session: Session?
    private var downloadHandles: [String: TorrentHandle] = [:]
    private let seedServer = TorrentSeedServer.shared
    private var trackerTasks: [String: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private(set) var items: [Item] = []
    private(set) var lastError: String?
    private(set) var trackerStatus: [String: String] = [:]

    private var storedSeedsURL: URL {
        CentralStore.baseDir.appendingPathComponent("torrent-seeds.json")
    }

    init() {
        seedServer.onUpload = { [weak self] infoHash, bytes in
            self?.recordUpload(infoHash: infoHash, bytes: bytes)
        }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatuses()
                try? await Task.sleep(for: .seconds(1))
            }
        }

        restoreStoredSeeds()
    }

    var activeCount: Int {
        items.filter { $0.state == .downloading || $0.state == .seeding }.count
    }

    var seededCount: Int {
        items.filter { $0.state == .seeding }.count
    }

    func startTorrentSessionIfNeeded() throws {
        guard session == nil else { return }

        let settings = TorrentSettingsStore.shared
        let destination = defaultSaveFolder()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let torrentSession = Session(settings: SessionSettings(
            listenPort: settings.listenPort,
            dhtEnabled: true,
            dhtPort: Int(settings.listenPort),
            savePath: destination.path
        ))
        session = torrentSession

        Task {
            try? await torrentSession.startDHT()
        }
    }

    func importTorrent(from url: URL, destination: URL? = nil) async throws {
        try startTorrentSessionIfNeeded()

        let savePath = (destination ?? defaultSaveFolder()).standardizedFileURL
        try FileManager.default.createDirectory(at: savePath, withIntermediateDirectories: true)

        let params = try AddTorrentParams.fromFile(url.path, savePath: savePath.path)
        guard let infoHash = params.infoHash else { throw TorrentManagerError.invalidTorrent }

        guard let session else { throw TorrentManagerError.sessionUnavailable }
        let handle = try await session.addTorrent(params)
        let status = await handle.status()
        let magnet = MagnetLink(
            infoHash: status.infoHash,
            displayName: status.name
        ).uri

        let id = status.infoHash.description
        downloadHandles[id] = handle
        upsert(Item(
            id: id,
            name: status.name,
            infoHash: id,
            magnet: magnet,
            totalSize: status.totalSize,
            state: mapState(status.state),
            progress: status.progress,
            peers: status.numPeers,
            downloadRate: status.downloadRate,
            uploadRate: status.uploadRate,
            totalDownloaded: status.totalDownloaded,
            totalUploaded: status.totalUploaded,
            sourceURL: nil,
            torrentURL: url.standardizedFileURL,
            error: nil
        ))
        _ = infoHash
    }

    func addMagnet(_ uri: String, destination: URL? = nil) async throws {
        try startTorrentSessionIfNeeded()

        let savePath = (destination ?? defaultSaveFolder()).standardizedFileURL
        try FileManager.default.createDirectory(at: savePath, withIntermediateDirectories: true)

        let params = try AddTorrentParams.fromMagnet(uri, savePath: savePath.path)
        guard let session else { throw TorrentManagerError.sessionUnavailable }
        let handle = try await session.addTorrent(params)
        let status = await handle.status()
        let magnet = MagnetLink(
            infoHash: status.infoHash,
            displayName: status.name
        ).uri
        let id = status.infoHash.description
        downloadHandles[id] = handle

        upsert(Item(
            id: id,
            name: status.name,
            infoHash: id,
            magnet: magnet,
            totalSize: status.totalSize,
            state: mapState(status.state),
            progress: status.progress,
            peers: status.numPeers,
            downloadRate: status.downloadRate,
            uploadRate: status.uploadRate,
            totalDownloaded: status.totalDownloaded,
            totalUploaded: status.totalUploaded,
            sourceURL: nil,
            torrentURL: nil,
            error: nil
        ))
    }

    func seed(created: TorrentCreator.Result, torrentURL: URL) throws {
        try seedServer.start(port: TorrentSettingsStore.shared.listenPort)
        seedServer.addSeed(
            info: created.info,
            sourceURL: created.sourceURL,
            metadata: created.infoDictionaryData
        )

        let trackers = created.trackers.isEmpty
            ? TorrentSettingsStore.shared.trackers
            : created.trackers

        let id = created.info.infoHash.description
        upsert(Item(
            id: id,
            name: created.info.name,
            infoHash: id,
            magnet: MagnetLink(
                infoHash: created.info.infoHash,
                displayName: created.info.name,
                trackers: trackers
            ).uri,
            totalSize: created.totalSize,
            state: .seeding,
            progress: 1,
            peers: seedServer.peerCount(for: id),
            downloadRate: 0,
            uploadRate: 0,
            totalDownloaded: created.totalSize,
            totalUploaded: 0,
            sourceURL: created.sourceURL,
            torrentURL: torrentURL.standardizedFileURL,
            error: nil
        ))

        startTrackerLoop(id: id, info: created.info, trackers: trackers)
        saveStoredSeeds()
    }

    func pause(_ item: Item) {
        guard let handle = downloadHandles[item.id] else { return }
        Task {
            await handle.pause()
            await refreshStatuses()
        }
    }

    func resume(_ item: Item) {
        guard let handle = downloadHandles[item.id] else { return }
        Task {
            do {
                try await handle.resume()
            } catch {
                update(id: item.id, state: .error, error: error.localizedDescription)
            }
        }
    }

    func remove(_ item: Item, deleteFiles: Bool = false) {
        trackerTasks[item.id]?.cancel()
        trackerTasks[item.id] = nil

        if item.state == .seeding {
            stopAnnouncing(item)
            seedServer.removeSeed(infoHash: item.id)
            removeStoredSeed(item.id)
        }

        if let handle = downloadHandles.removeValue(forKey: item.id),
           let session,
           let hash = InfoHash(hex: item.id) {
            Task {
                await session.removeTorrent(hash, deleteFiles: deleteFiles)
                await refreshStatuses()
            }
            _ = handle
        }

        items.removeAll { $0.id == item.id }
    }

    func copyMagnet(_ item: Item) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.magnet, forType: .string)
    }

    func openInFinder(_ item: Item) {
        if let torrentURL = item.torrentURL {
            NSWorkspace.shared.activateFileViewerSelecting([torrentURL])
        } else if let sourceURL = item.sourceURL {
            NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
        }
    }

    func stopAllSeeds() {
        let seeds = items.filter { $0.state == .seeding }
        for item in seeds {
            remove(item)
        }
    }

    private func refreshStatuses() async {
        guard session != nil else {
            refreshSeedCounts()
            return
        }

        for handle in downloadHandles.values {
            let status = await handle.status()
            let id = status.infoHash.description
            let wasSeeding = items.first { $0.id == id }?.state == .seeding
            update(
                id: id,
                name: status.name,
                state: mapState(status.state),
                progress: status.progress,
                peers: status.numPeers,
                downloadRate: status.downloadRate,
                uploadRate: status.uploadRate,
                totalDownloaded: status.totalDownloaded,
                totalUploaded: status.totalUploaded
            )

            if status.state == .seeding && !wasSeeding {
                LibraryModel.shared.rescan()
            }
        }

        refreshSeedCounts()
    }

    private func refreshSeedCounts() {
        for item in items where item.state == .seeding {
            itemUpdate(item.id) { item in
                item.peers = seedServer.peerCount(for: item.id)
                item.totalUploaded = seedServer.uploadedBytes(for: item.id)
                item.uploadRate = seedServer.uploadRate(for: item.id)
            }
        }
    }

    private func mapState(_ state: TorrentState) -> State {
        switch state {
        case .seeding: return .seeding
        case .paused, .stopped: return .paused
        case .error: return .error
        default: return .downloading
        }
    }

    private func recordUpload(infoHash: String, bytes: Int64) {
        itemUpdate(infoHash) { item in
            item.totalUploaded += bytes
            item.uploadRate += Double(bytes)
        }
    }

    private func startTrackerLoop(id: String, info: TorrentInfo, trackers: [String]) {
        trackerTasks[id]?.cancel()
        trackerTasks[id] = Task { [weak self] in
            guard let self else { return }
            var firstAnnounce = true

            while !Task.isCancelled {
                let uploaded = self.items.first { $0.id == id }?.totalUploaded ?? 0
                let trackerURLs = trackers.filter {
                    $0.hasPrefix("http://") || $0.hasPrefix("https://")
                }

                var interval = 1800
                for trackerURL in trackerURLs {
                    do {
                        let responseInterval = try await self.announceSeedTracker(
                            announceURL: trackerURL,
                            infoHash: info.infoHash,
                            uploaded: uploaded,
                            totalSize: info.totalSize,
                            event: firstAnnounce ? "started" : nil
                        )
                        interval = max(60, responseInterval)
                        trackerStatus[trackerURL] = "OK"
                        firstAnnounce = false
                        break
                    } catch {
                        trackerStatus[trackerURL] = error.localizedDescription
                        continue
                    }
                }

                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func announceSeedTracker(
        announceURL: String,
        infoHash: InfoHash,
        uploaded: Int64,
        totalSize: Int64,
        event: String?
    ) async throws -> Int {
        guard let baseURL = URL(string: announceURL) else {
            throw TorrentManagerError.invalidTrackerURL
        }

        var queryItems = [
            "info_hash=\(infoHash.urlEncoded)",
            "peer_id=\(String(data: seedServerPeerID, encoding: .ascii) ?? "")",
            "port=\(TorrentSettingsStore.shared.listenPort)",
            "uploaded=\(uploaded)",
            "downloaded=\(totalSize)",
            "left=0",
            "compact=1",
            "numwant=50"
        ]

        if let event {
            queryItems.append("event=\(event)")
        }

        let separator = baseURL.query == nil ? "?" : "&"
        let urlString = announceURL + separator + queryItems.joined(separator: "&")
        guard let url = URL(string: urlString) else {
            throw TorrentManagerError.invalidTrackerURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw TorrentManagerError.trackerHTTPStatus(http.statusCode)
        }

        let value = try BencodeDecoder().decode(data)
        if let failure = value["failure reason"]?.utf8String {
            throw TorrentManagerError.trackerFailure(failure)
        }

        return value["interval"]?.integerValue.map(Int.init) ?? 1800
    }

    private var seedServerPeerID: Data {
        // HTTP trackers expect peer_id to be a 20-byte value. Keep it printable ASCII so URL
        // construction is lossless and stable across app launches.
        let key = "ComicViewerTorrentPeerID"
        if let data = UserDefaults.standard.data(forKey: key),
           data.count == 20,
           String(data: data, encoding: .ascii) != nil {
            return data
        }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let generated = Data("-CV0001-\(suffix)".utf8)
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private func stopAnnouncing(_ item: Item) {
        guard let hash = InfoHash(hex: item.id) else { return }
        let trackers = TorrentSettingsStore.shared.trackers
        let uploaded = item.totalUploaded
        Task {
            for trackerURL in trackers where trackerURL.hasPrefix("http://") || trackerURL.hasPrefix("https://") {
                _ = try? await announceSeedTracker(
                    announceURL: trackerURL,
                    infoHash: hash,
                    uploaded: uploaded,
                    totalSize: item.totalSize,
                    event: "stopped"
                )
            }
        }
    }

    private func defaultSaveFolder() -> URL {
        if let custom = DownloadDestinationStore.shared.customFolder {
            return custom.standardizedFileURL
        }
        if let library = LibraryModel.shared.folders.first {
            return library.standardizedFileURL
        }
        let fallback = CentralStore.baseDir.appendingPathComponent("Torrent Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    private func upsert(_ item: Item) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }
    }

    private func update(
        id: String,
        name: String? = nil,
        state: State? = nil,
        progress: Double? = nil,
        peers: Int? = nil,
        downloadRate: Double? = nil,
        uploadRate: Double? = nil,
        totalDownloaded: Int64? = nil,
        totalUploaded: Int64? = nil,
        error: String? = nil
    ) {
        itemUpdate(id) { item in
            if let name { item.name = name }
            if let state { item.state = state }
            if let progress { item.progress = progress }
            if let peers { item.peers = peers }
            if let downloadRate { item.downloadRate = downloadRate }
            if let uploadRate { item.uploadRate = uploadRate }
            if let totalDownloaded { item.totalDownloaded = totalDownloaded }
            if let totalUploaded { item.totalUploaded = totalUploaded }
            item.error = error
        }
    }

    private func itemUpdate(_ id: String, _ body: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        body(&item)
        items[index] = item
    }

    private func restoreStoredSeeds() {
        guard let data = try? Data(contentsOf: storedSeedsURL),
              let entries = try? JSONDecoder().decode([StoredSeed].self, from: data) else { return }

        for entry in entries {
            let sourceURL = URL(fileURLWithPath: entry.sourcePath).standardizedFileURL
            let torrentURL = URL(fileURLWithPath: entry.torrentPath).standardizedFileURL
            guard
                FileManager.default.fileExists(atPath: sourceURL.path),
                FileManager.default.fileExists(atPath: torrentURL.path),
                let torrentData = try? Data(contentsOf: torrentURL),
                let info = try? TorrentInfo.parse(from: torrentData),
                let metadata = try? TorrentMetadataWire.extractInfoDictionary(
                    from: torrentData,
                    matching: info.infoHash
                )
            else {
                continue
            }

            do {
                try seedServer.start(port: TorrentSettingsStore.shared.listenPort)
                seedServer.addSeed(
                    info: info,
                    sourceURL: sourceURL,
                    metadata: metadata
                )
                let id = info.infoHash.description
                let trackers = entry.trackers
                upsert(Item(
                    id: id,
                    name: info.name,
                    infoHash: id,
                    magnet: MagnetLink(infoHash: info.infoHash, displayName: info.name, trackers: trackers).uri,
                    totalSize: info.totalSize,
                    state: .seeding,
                    progress: 1,
                    peers: seedServer.peerCount(for: id),
                    downloadRate: 0,
                    uploadRate: 0,
                    totalDownloaded: info.totalSize,
                    totalUploaded: 0,
                    sourceURL: sourceURL,
                    torrentURL: torrentURL,
                    error: nil
                ))
                startTrackerLoop(id: id, info: info, trackers: trackers)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func saveStoredSeeds() {
        let entries = items.compactMap { item -> StoredSeed? in
            guard item.state == .seeding, let source = item.sourceURL, let torrent = item.torrentURL else { return nil }
            return StoredSeed(
                infoHash: item.id,
                sourcePath: source.standardizedFileURL.path,
                torrentPath: torrent.standardizedFileURL.path,
                trackers: TorrentSettingsStore.shared.trackers
            )
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        CentralStore.ensureDirs()
        try? data.write(to: storedSeedsURL, options: .atomic)
    }

    private func removeStoredSeed(_ infoHash: String) {
        guard let data = try? Data(contentsOf: storedSeedsURL),
              var entries = try? JSONDecoder().decode([StoredSeed].self, from: data) else { return }
        entries.removeAll { $0.infoHash == infoHash }
        if let encoded = try? JSONEncoder().encode(entries) {
            try? encoded.write(to: storedSeedsURL, options: .atomic)
        }
    }
}

enum TorrentManagerError: LocalizedError {
    case invalidTorrent
    case sessionUnavailable
    case invalidTrackerURL
    case trackerHTTPStatus(Int)
    case trackerFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidTorrent: return "The torrent metadata is invalid."
        case .sessionUnavailable: return "The BitTorrent session is unavailable."
        case .invalidTrackerURL: return "The configured tracker URL is invalid."
        case .trackerHTTPStatus(let status): return "Tracker returned HTTP status \(status)."
        case .trackerFailure(let message): return "Tracker rejected the announce: \(message)"
        }
    }
}