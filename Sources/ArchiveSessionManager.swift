import Foundation

/// Owns temporary archive extraction sessions for the whole app.
///
/// A session contains the extracted directory, the ordered page URLs visible to the reader,
/// and (for streamed ZIP/CBZ archives) the on-demand streamer. Keeping this behind one actor
/// prevents AppModel and LibraryModel from creating separate extraction caches for the same archive.
actor ArchiveSessionManager {
    struct Session: Sendable {
        let archive: URL
        let dir: URL
        let items: [URL]
        let streamer: ArchiveStreamer?
    }

    static let shared = ArchiveSessionManager()

    private var sessions: [String: Session] = [:]
    private var order: [String] = []
    private var currentKey: String?
    private var registrationTokens: [String: Int] = [:]
    private let maxCachedSessions = 4

    /// Return an existing session and mark it as recently used.
    func session(for archive: URL) async -> Session? {
        let key = CentralStore.key(for: archive)
        guard let session = sessions[key] else { return nil }
        guard FileManager.default.fileExists(atPath: session.dir.path) else {
            sessions.removeValue(forKey: key)
            order.removeAll { $0 == key }
            await session.streamer?.cancel()
            return nil
        }
        touch(key)
        return session
    }

    /// Begin an archive open identified by the reader's generation.
    ///
    /// A newer open for the same archive replaces the token, so stale work cannot register a
    /// completed extraction over a newer session.
    func beginRegistration(for archive: URL, token: Int) {
        registrationTokens[CentralStore.key(for: archive)] = token
    }

    /// Register a newly prepared session. When a token is supplied, registration succeeds only
    /// if that token is still the newest open for the archive.
    @discardableResult
    func register(
        _ session: Session,
        token: Int? = nil,
        makeCurrent: Bool = false
    ) async -> Bool {
        let key = CentralStore.key(for: session.archive)
        if let token, registrationTokens[key] != token {
            return false
        }
        let previous = sessions[key]
        sessions[key] = session
        touch(key)
        if makeCurrent {
            currentKey = key
        }

        if let previous, previous.dir != session.dir {
            await previous.streamer?.cancel()
            try? FileManager.default.removeItem(at: previous.dir)
        }

        await evictIfNeeded()
        return true
    }

    /// Remove a cached session and its extracted directory.
    ///
    /// The streamer's background work is cancelled before the directory is removed so a stale
    /// open cannot continue writing into an evicted temp directory.
    func remove(_ archive: URL, token: Int? = nil) async {
        let key = CentralStore.key(for: archive)
        if let token, registrationTokens[key] != token {
            return
        }
        registrationTokens.removeValue(forKey: key)
        guard let session = sessions.removeValue(forKey: key) else {
            order.removeAll { $0 == key }
            if currentKey == key { currentKey = nil }
            return
        }

        order.removeAll { $0 == key }
        if currentKey == key { currentKey = nil }
        await session.streamer?.cancel()
        try? FileManager.default.removeItem(at: session.dir)
    }

    /// Mark the archive currently being read. The current session is never evicted.
    func setCurrent(_ archive: URL?) async {
        currentKey = archive.map(CentralStore.key(for:))
        if let currentKey, sessions[currentKey] != nil {
            touch(currentKey)
        }
        await evictIfNeeded()
    }

    /// Fully extract an archive if no session exists yet.
    ///
    /// If a streamed session already exists, wait for its background fill and reuse its directory
    /// rather than extracting the same archive a second time.
    func extractFully(for archive: URL) async -> Session? {
        if let existing = await session(for: archive) {
            if let streamer = existing.streamer {
                await streamer.finishBackgroundFill()
                let items = Self.scanImages(in: existing.dir)
                guard !items.isEmpty else { return existing }

                let refreshed = Session(
                    archive: existing.archive,
                    dir: existing.dir,
                    items: items,
                    streamer: streamer
                )
                sessions[CentralStore.key(for: archive)] = refreshed
                touch(CentralStore.key(for: archive))
                return refreshed
            }
            return existing
        }

        guard let dir = await Task.detached(priority: .userInitiated, operation: {
            ArchiveExtractor.extract(archive)
        }).value else {
            return nil
        }

        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }

        let items = Self.scanImages(in: dir)
        guard !items.isEmpty else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }

        let session = Session(archive: archive, dir: dir, items: items, streamer: nil)
        await register(session)
        return session
    }

    /// Remove every cached extraction directory.
    ///
    /// Any active streamers are cancelled before their directories are removed.
    func cleanup() async {
        let cached = Array(sessions.values)
        sessions.removeAll()
        order.removeAll()
        currentKey = nil
        registrationTokens.removeAll()

        for session in cached {
            await session.streamer?.cancel()
            try? FileManager.default.removeItem(at: session.dir)
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() async {
        while order.count > maxCachedSessions {
            guard let victim = order.first(where: { $0 != currentKey }) else { return }
            order.removeAll { $0 == victim }
            if let session = sessions.removeValue(forKey: victim) {
                await session.streamer?.cancel()
                try? FileManager.default.removeItem(at: session.dir)
            }
        }
    }

    private nonisolated static func scanImages(in dir: URL) -> [URL] {
        let fm = FileManager.default
        var images: [URL] = []

        func walk(_ current: URL) {
            let children = (try? fm.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for child in children {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    walk(child)
                } else if SupportedTypes.isSupported(child) {
                    images.append(child.standardizedFileURL)
                }
            }
        }

        walk(dir.standardizedFileURL)
        return images.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}
