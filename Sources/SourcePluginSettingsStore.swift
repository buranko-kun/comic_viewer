import Foundation
import Observation

@MainActor
@Observable
final class SourcePluginSettingsStore {
    static let shared = SourcePluginSettingsStore()

    private(set) var values: [String: [String: SourcePluginSettingValue]] = [:]

    private static var fileURL: URL {
        CentralStore.baseDir.appendingPathComponent("source-plugin-settings.json")
    }

    init() { load() }

    func value(for plugin: SourcePlugin, key: String) -> SourcePluginSettingValue {
        if let value = values[plugin.id]?[key] { return value }
        return plugin.settings?.first(where: { $0.id == key })?.defaultValue ?? .string("")
    }

    func set(_ value: SourcePluginSettingValue, for plugin: SourcePlugin, key: String) {
        values[plugin.id, default: [:]][key] = value
        save()
    }

    func reset(_ plugin: SourcePlugin) {
        values.removeValue(forKey: plugin.id)
        save()
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
        guard let data = try? Data(contentsOf: Self.fileURL),
              let saved = try? JSONDecoder().decode([String: [String: SourcePluginSettingValue]].self, from: data)
        else { return }
        values = saved
    }

    private func save() {
        CentralStore.ensureDirs()
        if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
