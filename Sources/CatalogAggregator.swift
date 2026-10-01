import SwiftUI
import Foundation

/// Queries every configured CatalogSource and installed source plugin, merging them into the same
/// Online browse layer. Existing JSON/OPDS sources remain supported unchanged.
@MainActor
@Observable
final class CatalogAggregator {
    static let shared = CatalogAggregator()

    private(set) var loading = false
    private(set) var comics: [RemoteComic] = []
    private(set) var folders: [RemoteCatalog.ChildCatalog] = []
    private(set) var errors: [String] = []
    private(set) var loadedOnce = false

    private(set) var revision = 0
    private var results: [String: RemoteCatalog] = [:]
    private var failures: [String: SourceFailure] = [:]
    var sourceFailures: [SourceFailure] { failures.values.sorted { $0.name < $1.name } }
    private let diskCache = CatalogSnapshotCache()
    private var hydrated = Set<String>()
    private(set) var cachedSources = Set<String>()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]

    /// Refresh sources independently, keeping successful results visible during refresh.
    func loadRoots(refresh: Bool = false) async {
        let sources = CatalogSourceStore.shared.sources
        let plugins = SourcePluginStore.shared.enabledPlugins
        let active = Set(sources.map(\.id) + plugins.map { "plugin:" + $0.id })
        cachedSources.formIntersection(active)
        for key in Array(results.keys) where !active.contains(key) { results[key] = nil }
        for key in Array(failures.keys) where !active.contains(key) { failures[key] = nil }
        for key in Array(tasks.keys) where !active.contains(key) {
            tasks.removeValue(forKey: key)?.cancel()
            generations[key] = nil
        }
        for source in sources where !hydrated.contains(source.id) {
            hydrated.insert(source.id)
            if let cached = await diskCache.load(key: source.id) { results[source.id] = cached; cachedSources.insert(source.id) }
        }
        for plugin in plugins {
            let key = "plugin:" + plugin.id
            if hydrated.insert(key).inserted, let cached = await diskCache.load(key: cacheKey(plugin)) {
                results[key] = cached; cachedSources.insert(key)
                for comic in cached.comics { if let resource = comic.coverResource { PluginResourceRegistry.shared.register(resource) } }
            }
        }
        publish()
        var pending: [Task<Void, Never>] = []
        for source in sources {
            pending.append(start(key: source.id, name: source.name, cacheKey: source.id) {
                try await CatalogClient.catalog(at: source.url)
            })
        }
        for plugin in plugins {
            pending.append(start(key: "plugin:" + plugin.id, name: plugin.name, cacheKey: cacheKey(plugin)) {
                try await SourcePluginRuntime.shared.catalog(plugin: plugin, refresh: refresh)
            })
        }
        for task in pending { await task.value }
        loadedOnce = true
        writeSkippedLog(for: comics)
    }

    func invalidatePlugin(_ id: String) {
        let key = "plugin:" + id
        tasks.removeValue(forKey: key)?.cancel()
        generations[key] = nil
        failures[key] = nil
        BrowseState.shared.invalidatePlugin(id)
        if SourcePluginStore.shared.plugin(id: id)?.enabled != true { results[key] = nil }
        publish()
    }

    func refreshPlugin(_ id: String) async {
        invalidatePlugin(id)
        guard let plugin = SourcePluginStore.shared.plugin(id: id), plugin.enabled else { return }
        await start(key: "plugin:" + id, name: plugin.name, cacheKey: cacheKey(plugin)) {
            try await SourcePluginRuntime.shared.catalog(plugin: plugin, refresh: true)
        }.value
    }

    private func cacheKey(_ plugin: SourcePlugin) -> String {
        "plugin:" + plugin.id + ":" + (plugin.scriptHash ?? plugin.version) + ":" + CentralStore.sha256(SourcePluginSettingsStore.shared.settingsJSON(for: plugin))
    }

    func isLoadingSource(_ key: String) -> Bool { tasks[key] != nil }

    func retrySource(_ key: String) async {
        if key.hasPrefix("plugin:") { await refreshPlugin(String(key.dropFirst(7))); return }
        guard let source = CatalogSourceStore.shared.sources.first(where: { $0.id == key }) else { return }
        await start(key: key, name: source.name, cacheKey: key) {
            try await CatalogClient.catalog(at: source.url)
        }.value
    }

    private func start(key: String, name: String, cacheKey: String,
                       fetch: @escaping @MainActor () async throws -> RemoteCatalog) -> Task<Void, Never> {
        if let task = tasks[key] { return task }
        let generation = UUID()
        generations[key] = generation
        loading = true
        let task = Task { @MainActor in
            do {
                let result = try await fetch()
                guard !Task.isCancelled, self.generations[key] == generation else { return }
                self.results[key] = result
                self.failures[key] = nil
                self.cachedSources.remove(key)
                await self.diskCache.save(result, key: cacheKey)
                guard self.generations[key] == generation else { return }
            } catch {
                guard !Task.isCancelled, self.generations[key] == generation else { return }
                if self.results[key] != nil { self.cachedSources.insert(key) }
                self.failures[key] = SourceFailure(id: key, name: name, detail: SourcePluginDiagnostics.redacted(error.localizedDescription))
            }
            self.tasks[key] = nil
            self.publish()
        }
        tasks[key] = task
        return task
    }

    private func publish() {
        let keys = CatalogSourceStore.shared.sources.map(\.id)
            + SourcePluginStore.shared.enabledPlugins.map { "plugin:" + $0.id }
        comics = keys.flatMap { results[$0]?.comics ?? [] }
        folders = keys.flatMap { results[$0]?.childCatalogs ?? [] }
        errors = keys.compactMap { failures[$0].map { "\($0.name): \($0.detail)" } }
        loading = !tasks.isEmpty
        revision += 1
    }

    /// Where the skipped-items report is written.
    static let skippedLogURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ComicViewer", isDirectory: true)
        return dir.appendingPathComponent("skipped-items.log")
    }()

    /// Writes a report of entries that have no download links (still shown in the grid) so the
    /// user can fix them at the source later.
    private func writeSkippedLog(for comics: [RemoteComic]) {
        let broken = comics.filter { !$0.hasMirrors && !$0.opensCatalog && !$0.canRead }
        var lines = [
            "Catalog entries with no download links",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "Total: \(broken.count) of \(comics.count)",
            ""
        ]

        for comic in broken {
            lines.append("\(comic.title)  [\(comic.sourceName)]")
        }

        let url = Self.skippedLogURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try lines.joined(separator: "\n").write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            errors.append("Couldn't write skipped-items log: \(error.localizedDescription)")
        }
    }
}

/// Recovery labels retain the underlying detail rather than guessing that every 403 is a login failure.
struct SourceFailure: Identifiable {
    let id: String
    let name: String
    let detail: String
    var summary: String {
        let text = detail.lowercased()
        if text.contains("401") || text.contains("login required") || text.contains("sign in") { return "Login required" }
        if text.contains("403") || text.contains("challenge") || text.contains("captcha") { return "Site blocked access" }
        if text.contains("429") { return "Source is rate limiting requests" }
        if text.contains("timed out") || text.contains("timeout") { return "Source timed out" }
        return "Request failed"
    }
}

/// Last successful root catalogs are shown while a fresh request runs. Corrupt/old files are ignored.
actor CatalogSnapshotCache {
    struct Snapshot: Codable { let saved: Date; let catalog: RemoteCatalog }
    let directory: URL
    init(directory: URL = CentralStore.baseDir.appendingPathComponent("catalog-snapshots")) { self.directory = directory }
    private func file(_ key: String) -> URL { directory.appendingPathComponent(CentralStore.sha256(key) + ".json") }
    func load(key: String) -> RemoteCatalog? {
        let url = file(key)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000,
              let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              Date().timeIntervalSince(snapshot.saved) < 7 * 24 * 3600 else { return nil }
        return snapshot.catalog
    }
    func save(_ catalog: RemoteCatalog, key: String) {
        guard let data = try? JSONEncoder().encode(Snapshot(saved: Date(), catalog: catalog)), data.count <= 20_000_000 else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(key), options: .atomic)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let ordered = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for old in ordered.dropFirst(30) { try? FileManager.default.removeItem(at: old) }
    }
}
