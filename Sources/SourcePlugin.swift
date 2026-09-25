import Foundation

struct SourcePlugin: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let version: String
    let homepage: String?
    let description: String?
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
}
