import Foundation

enum SourcePluginSettingValue: Codable, Hashable {
    case string(String)
    case bool(Bool)
    case number(Double)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(Self.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected string, bool, or number"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        }
    }

    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
}

struct SourcePluginSetting: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let type: String
    let defaultValue: SourcePluginSettingValue
    let options: [String]?
}

struct SourcePlugin: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let version: String
    let homepage: String?
    let description: String?
    let tags: [String]?
    let capabilities: [String]?
    let settings: [SourcePluginSetting]?
    let sourceURL: URL
    let fileName: String
    let installedAt: Date
    var enabled: Bool
}

struct SourcePluginManifest: Codable, Hashable {
    let id: String
    let name: String
    let version: String
    let homepage: String?
    let description: String?
    let tags: [String]?
    let capabilities: [String]?
    let settings: [SourcePluginSetting]?
}
