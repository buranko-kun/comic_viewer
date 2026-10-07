import SwiftUI
import Foundation

/// The user's configured catalog sources, persisted as JSON in `CentralStore.baseDir`. Sources
/// are added in Settings or imported from a `.txt` (one URL per line; `#` comments and blank
/// lines ignored; an optional `Name | URL` gives a custom label). Nothing is hardcoded — the
/// app ships with no sources; each user points it at their own server(s).
@MainActor
@Observable
final class CatalogSourceStore {
    static let shared = CatalogSourceStore()

    private(set) var sources: [CatalogSource]

    private static var fileURL: URL { CentralStore.baseDir.appendingPathComponent("catalogs.json") }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([CatalogSource].self, from: data) {
            sources = saved
        } else {
            sources = []
        }
    }

    @discardableResult
    func add(name: String, url: URL) -> Bool {
        guard Self.isAcceptable(url), !sources.contains(where: { $0.url == url }) else { return false }
        let name = name.trimmingCharacters(in: .whitespaces)
        sources.append(CatalogSource(name: name.isEmpty ? Self.defaultName(url) : name, url: url))
        save()
        return true
    }

    /// Interpret user input as a source URL: an http(s)/file URL, or an absolute filesystem
    /// path (with `~` expanded) turned into a `file://` URL. nil if it's neither.
    nonisolated static func makeURL(from input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let u = URL(string: s), isAcceptable(u) { return u }
        let path = (s as NSString).expandingTildeInPath
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }

    /// A source we can fetch: web (http/https) or a local file.
    nonisolated static func isAcceptable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "file": return true
        default: return false
        }
    }

    /// A friendly default label: the host for web sources, or the containing folder for files.
    private nonisolated static func defaultName(_ url: URL) -> String {
        if url.isFileURL { return url.deletingLastPathComponent().lastPathComponent }
        return url.host ?? url.absoluteString
    }

    func remove(_ source: CatalogSource) {
        sources.removeAll { $0.id == source.id }
        save()
    }

    /// Import sources from a `.txt`. Returns how many new sources were added.
    @discardableResult
    func importTextFile(_ fileURL: URL) -> Int {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        var added = 0
        for parsed in Self.parseText(text) where add(name: parsed.name, url: parsed.url) { added += 1 }
        return added
    }

    /// Pure parser for a `.txt` of sources — one per line; `#` comments and blank lines ignored;
    /// an optional `Name | URL` gives a custom label. Testable in isolation.
    nonisolated static func parseText(_ text: String) -> [(name: String, url: URL)] {
        var out: [(name: String, url: URL)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let name: String, urlStr: String
            if let sep = line.range(of: " | ") {
                name = String(line[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                urlStr = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                name = ""; urlStr = line
            }
            if let url = makeURL(from: urlStr) {
                out.append((name, url))
            }
        }
        return out
    }

    private func save() {
        CentralStore.ensureDirs()
        if let data = try? JSONEncoder().encode(sources) {
            try? data.write(to: Self.fileURL)
        }
    }
}
