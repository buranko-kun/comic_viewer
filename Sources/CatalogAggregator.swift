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
    private var failures: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]

    /// Refresh sources independently, keeping successful results visible during refresh.
    func loadRoots(refresh: Bool = false) async {
        let sources = CatalogSourceStore.shared.sources
        let plugins = SourcePluginStore.shared.enabledPlugins
        let active = Set(sources.map(\.id) + plugins.map { "plugin:" + $0.id })
        for key in Array(results.keys) where !active.contains(key) { results[key] = nil }
        for key in Array(failures.keys) where !active.contains(key) { failures[key] = nil }
        for key in Array(tasks.keys) where !active.contains(key) {
            tasks.removeValue(forKey: key)?.cancel()
            generations[key] = nil
        }
        publish()
        var pending: [Task<Void, Never>] = []
        for source in sources {
            pending.append(start(key: source.id, name: source.name) {
                try await CatalogClient.catalog(at: source.url)
            })
        }
        for plugin in plugins {
            pending.append(start(key: "plugin:" + plugin.id, name: plugin.name) {
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
        await start(key: "plugin:" + id, name: plugin.name) {
            try await SourcePluginRuntime.shared.catalog(plugin: plugin, refresh: true)
        }.value
    }

    private func start(key: String, name: String,
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
            } catch {
                guard !Task.isCancelled, self.generations[key] == generation else { return }
                self.failures[key] = "\(name): \(error.localizedDescription)"
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
        errors = keys.compactMap { failures[$0] }
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
        let broken = comics.filter { !$0.hasMirrors }
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
