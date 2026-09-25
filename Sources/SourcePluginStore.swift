import Foundation
import Observation

@MainActor
@Observable
final class SourcePluginStore {
    static let shared = SourcePluginStore()

    private(set) var plugins: [SourcePlugin] = []

    private static var fileURL: URL {
        CentralStore.baseDir.appendingPathComponent("source-plugins.json")
    }

    static var pluginDirectory: URL {
        CentralStore.baseDir.appendingPathComponent("source-plugins", isDirectory: true)
    }

    init() {
        load()
    }

    func script(for plugin: SourcePlugin) -> String? {
        try? String(
            contentsOf: Self.pluginDirectory.appendingPathComponent(plugin.fileName),
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
    func install(from url: URL) async throws -> SourcePlugin {
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

        return try await install(script: script, sourceURL: normalized)
    }

    @discardableResult
    func install(localURL url: URL) async throws -> SourcePlugin {
        guard url.isFileURL else { throw SourcePluginStoreError.invalidURL }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_000_000 else { throw SourcePluginStoreError.tooLarge }
        guard let script = String(data: data, encoding: .utf8) else {
            throw SourcePluginStoreError.notUTF8
        }
        return try await install(script: script, sourceURL: url)
    }

    func update(_ plugin: SourcePlugin) async throws -> SourcePlugin {
        if plugin.sourceURL.isFileURL { return try await install(localURL: plugin.sourceURL) }
        return try await install(from: plugin.sourceURL)
    }

    func setEnabled(_ id: String, enabled: Bool) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[index].enabled = enabled
        save()
    }

    func remove(_ plugin: SourcePlugin) {
        try? FileManager.default.removeItem(
            at: Self.pluginDirectory.appendingPathComponent(plugin.fileName)
        )
        plugins.removeAll { $0.id == plugin.id }
        save()
    }

    nonisolated static func makeURL(from input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value) else { return nil }
        switch url.scheme?.lowercased() {
        case "http", "https", "file": return normalizeSourceURL(url)
        default: return nil
        }
    }

    private func install(script: String, sourceURL: URL) async throws -> SourcePlugin {
        let manifest = try await SourcePluginRuntime.shared.manifest(for: script)
        let old = plugins.first(where: { $0.id == manifest.id })

        CentralStore.ensureDirs()
        try FileManager.default.createDirectory(
            at: Self.pluginDirectory,
            withIntermediateDirectories: true
        )

        let fileName = old?.fileName ?? ("plugin-" + safeFileName(manifest.id) + ".js")
        try script.write(
            to: Self.pluginDirectory.appendingPathComponent(fileName),
            atomically: true,
            encoding: .utf8
        )

        let plugin = SourcePlugin(
            id: manifest.id,
            name: manifest.name,
            version: manifest.version,
            homepage: manifest.homepage,
            description: manifest.description,
            sourceURL: sourceURL,
            fileName: fileName,
            installedAt: Date(),
            enabled: old?.enabled ?? true
        )

        if let index = plugins.firstIndex(where: { $0.id == plugin.id }) {
            plugins[index] = plugin
        } else {
            plugins.append(plugin)
        }

        plugins.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        save()
        return plugin
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let saved = try? JSONDecoder().decode([SourcePlugin].self, from: data)
        else { return }

        plugins = saved.filter {
            FileManager.default.fileExists(
                atPath: Self.pluginDirectory.appendingPathComponent($0.fileName).path
            )
        }
    }

    private func save() {
        CentralStore.ensureDirs()
        if let data = try? JSONEncoder().encode(plugins) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    private func safeFileName(_ id: String) -> String {
        let cleaned = id.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "-",
            options: .regularExpression
        )
        return cleaned.isEmpty ? UUID().uuidString : cleaned
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

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid HTTP(S) plugin URL."
        case .badResponse(let code): return "Plugin server returned HTTP \(code)."
        case .tooLarge: return "Plugin file is larger than the 1 MB limit."
        case .notUTF8: return "Plugin file isn't valid UTF-8."
        }
    }
}
