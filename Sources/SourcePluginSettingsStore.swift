import Foundation
import Observation

@MainActor
@Observable
final class SourcePluginSettingsStore {
    static let shared = SourcePluginSettingsStore()

    private(set) var values: [String: [String: SourcePluginSettingValue]] = [:]

    private(set) var lastError: String?
    private let fileURL: URL
    private let didChange: (String) -> Void

    init(baseDirectory: URL = CentralStore.baseDir, didChange: ((String) -> Void)? = nil) {
        fileURL = baseDirectory.appendingPathComponent("source-plugin-settings.json")
        self.didChange = didChange ?? { id in
            SourcePluginRuntime.shared.invalidate(pluginID: id)
            CatalogAggregator.shared.invalidatePlugin(id)
        }
        load()
    }

    func value(for plugin: SourcePlugin, key: String) -> SourcePluginSettingValue {
        guard let setting = plugin.settings?.first(where: { $0.id == key }) else { return .string("") }
        if let value = values[plugin.id]?[key], Self.matches(value, setting: setting) { return value }
        return setting.defaultValue
    }

    func set(_ value: SourcePluginSettingValue, for plugin: SourcePlugin, key: String) {
        var draft = values[plugin.id] ?? [:]
        draft[key] = value
        do { try apply(draft, for: plugin) } catch { lastError = error.localizedDescription }
    }

    func reset(_ plugin: SourcePlugin) {
        do { try apply([:], for: plugin) } catch { lastError = error.localizedDescription }
    }

    func apply(_ draft: [String: SourcePluginSettingValue], for plugin: SourcePlugin) throws {
        var selected: [String: SourcePluginSettingValue] = [:]
        for setting in plugin.settings ?? [] {
            guard let value = draft[setting.id] else { continue }
            guard Self.matches(value, setting: setting) else {
                throw NSError(domain: "SourcePluginSettings", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid value for setting \(setting.id)."])
            }
            selected[setting.id] = value
        }
        var candidate = values
        candidate[plugin.id] = selected
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(candidate).write(to: fileURL, options: .atomic)
        values = candidate
        lastError = nil
        didChange(plugin.id)
    }

    private static func matches(_ value: SourcePluginSettingValue, setting: SourcePluginSetting) -> Bool {
        switch setting.type.lowercased() {
        case "bool", "boolean", "toggle": return value.boolValue != nil
        case "number": if case .number(let number) = value { return number.isFinite }; return false
        case "select", "picker": return value.stringValue.map { setting.options?.contains($0) == true } ?? false
        default: return value.stringValue != nil
        }
    }

    func settingsJSON(for plugin: SourcePlugin) -> String {
        var object: [String: Any] = [:]
        for setting in plugin.settings ?? [] {
            switch value(for: plugin, key: setting.id) {
            case .string(let v): object[setting.id] = v
            case .bool(let v): object[setting.id] = v
            case .number(let v): object[setting.id] = v
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            values = try JSONDecoder().decode([String: [String: SourcePluginSettingValue]].self,
                                             from: Data(contentsOf: fileURL))
        } catch { lastError = "Couldn't load plugin settings: \(error.localizedDescription)" }
    }
}
