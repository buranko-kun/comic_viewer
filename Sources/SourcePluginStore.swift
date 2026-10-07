import Foundation
import Observation

@MainActor
@Observable
final class SourcePluginStore {
    static let shared = SourcePluginStore()

    private(set) var plugins: [SourcePlugin] = []

    private(set) var lastError: String?
    private let baseDirectory: URL
    private let validate: (String) async throws -> SourcePluginManifest
    private let didChange: (String) -> Void
    private var fileURL: URL { baseDirectory.appendingPathComponent("source-plugins.json") }
    private var directory: URL { baseDirectory.appendingPathComponent("source-plugins", isDirectory: true) }
    static var pluginDirectory: URL { CentralStore.baseDir.appendingPathComponent("source-plugins", isDirectory: true) }

    init(baseDirectory: URL = CentralStore.baseDir,
         validate: ((String) async throws -> SourcePluginManifest)? = nil,
         didChange: ((String) -> Void)? = nil) {
        self.baseDirectory = baseDirectory
        self.validate = validate ?? { try await SourcePluginRuntime.shared.manifest(for: $0) }
        self.didChange = didChange ?? { id in
            SourcePluginRuntime.shared.invalidate(pluginID: id)
            CatalogAggregator.shared.invalidatePlugin(id)
        }
        load()
    }

    func script(for plugin: SourcePlugin) -> String? {
        try? String(
            contentsOf: directory.appendingPathComponent(plugin.fileName),
            encoding: .utf8
        )
    }

    func plugin(id: String) -> SourcePlugin? {
        plugins.first { $0.id == id }
    }

    var enabledPlugins: [SourcePlugin] {
        plugins.filter(\.enabled)
    }

    @discardableResult
    func install(from url: URL, expectedID: String? = nil) async throws -> SourcePlugin {
        let normalized = Self.normalizeSourceURL(url)
        guard ["http", "https"].contains(normalized.scheme?.lowercased() ?? "") else {
            throw SourcePluginStoreError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: normalized)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SourcePluginStoreError.badResponse(http.statusCode)
        }
        guard data.count <= 1_000_000 else { throw SourcePluginStoreError.tooLarge }
        guard let script = String(data: data, encoding: .utf8) else {
            throw SourcePluginStoreError.notUTF8
        }

        return try await install(script: script, sourceURL: normalized, expectedID: expectedID)
    }

    @discardableResult
    func install(localURL url: URL, expectedID: String? = nil) async throws -> SourcePlugin {
        guard url.isFileURL else { throw SourcePluginStoreError.invalidURL }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_000_000 else { throw SourcePluginStoreError.tooLarge }
        guard let script = String(data: data, encoding: .utf8) else {
            throw SourcePluginStoreError.notUTF8
        }
        return try await install(script: script, sourceURL: url, expectedID: expectedID)
    }

    func update(_ plugin: SourcePlugin) async throws -> SourcePlugin {
        if plugin.sourceURL.isFileURL { return try await install(localURL: plugin.sourceURL, expectedID: plugin.id) }
        return try await install(from: plugin.sourceURL, expectedID: plugin.id)
    }

    func setEnabled(_ id: String, enabled: Bool) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        var candidate = plugins
        candidate[index].enabled = enabled
        do {
            try persist(candidate)
            plugins = candidate
            lastError = nil
            didChange(id)
        } catch { lastError = error.localizedDescription }
    }

    func remove(_ plugin: SourcePlugin) {
        let candidate = plugins.filter { $0.id != plugin.id }
        do {
            // Commit the registry first: failure must not destroy the working script.
            try persist(candidate)
            plugins = candidate
            didChange(plugin.id)
            try FileManager.default.removeItem(at: directory.appendingPathComponent(plugin.fileName))
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    nonisolated static func makeURL(from input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value) else { return nil }
        guard url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" else {
            return nil
        }
        return normalizeSourceURL(url)
    }

    @discardableResult
    func install(script: String, sourceURL: URL, expectedID: String? = nil) async throws -> SourcePlugin {
        guard script.utf8.count <= 1_000_000 else { throw SourcePluginStoreError.tooLarge }
        let manifest = try await validate(script)
        if let expectedID, manifest.id != expectedID {
            throw SourcePluginStoreError.identityChanged(expectedID, manifest.id)
        }
        let old = plugins.first(where: { $0.id == manifest.id })
        let hash = CentralStore.sha256(script)
        let fileName = "plugin-" + CentralStore.sha256(manifest.id) + "-" + hash + ".js"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script.write(to: directory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        var plugin = SourcePlugin(
            id: manifest.id, name: manifest.name, version: manifest.version,
            homepage: manifest.homepage, description: manifest.description,
            tags: manifest.tags, capabilities: manifest.capabilities, settings: manifest.settings,
            sourceURL: sourceURL, fileName: fileName, installedAt: Date(), enabled: old?.enabled ?? true
        )
        plugin.scriptHash = hash
        plugin.apiVersion = manifest.apiVersion
        plugin.operationTimeoutSeconds = manifest.operationTimeoutSeconds
        var candidate = plugins.filter { $0.id != plugin.id }
        candidate.append(plugin)
        candidate.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try persist(candidate)
        plugins = candidate
        lastError = nil
        didChange(plugin.id)
        return plugin
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode([SourcePlugin].self, from: Data(contentsOf: fileURL))
            plugins = saved
            for index in plugins.indices {
                if let script = script(for: plugins[index]) {
                    plugins[index].scriptHash = CentralStore.sha256(script)
                } else {
                    lastError = "Installed script is missing for \(plugins[index].name). Reload it from its source."
                }
            }
        } catch { lastError = "Couldn't load installed plugins: \(error.localizedDescription)" }
    }

    private func persist(_ candidate: [SourcePlugin]) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(candidate).write(to: fileURL, options: .atomic)
    }

    nonisolated static func normalizeSourceURL(_ url: URL) -> URL {
        guard url.host?.lowercased() == "github.com" else { return url }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 5, parts[2] == "blob" else { return url }

        let owner = parts[0]
        let repo = parts[1]
        let ref = parts[3]
        let path = parts.dropFirst(4).joined(separator: "/")

        return URL(
            string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/\(path)"
        ) ?? url
    }
}

enum SourcePluginStoreError: LocalizedError {
    case invalidURL
    case badResponse(Int)
    case tooLarge
    case notUTF8
    case identityChanged(String, String)

    var errorDescription: String? {
        switch self {
        case .identityChanged(let old, let new): return "Update changed plugin ID from \(old) to \(new). Install it separately instead."
        case .invalidURL: return "Enter a valid HTTP(S) plugin URL."
        case .badResponse(let code): return "Plugin server returned HTTP \(code)."
        case .tooLarge: return "Plugin file is larger than the 1 MB limit."
        case .notUTF8: return "Plugin file isn't valid UTF-8."
        }
    }
}
