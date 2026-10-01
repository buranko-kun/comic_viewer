import Foundation

/// Shared contract decoding for production, fixtures, and unit tests.
enum SourcePluginContract {
    typealias Failure = SourcePluginRuntime.PluginError
    static func httpURL(_ raw: String, relativeTo base: URL? = nil) -> URL? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func manifest(_ data: Data) throws -> SourcePluginManifest {
        let value: SourcePluginManifest
        do { value = try JSONDecoder().decode(SourcePluginManifest.self, from: data) }
        catch { throw Failure.invalidPlugin("manifest: \(error)") }
        guard !value.id.isEmpty, value.id.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw Failure.invalidPlugin("manifest.id must contain only letters, digits, '.', '_' or '-'")
        }
        guard !value.name.trimmingCharacters(in: .whitespaces).isEmpty, !value.version.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Failure.invalidPlugin("manifest.name and version must be nonempty")
        }
        guard value.apiVersion == nil || value.apiVersion == 1 else { throw Failure.invalidPlugin("Unsupported manifest.apiVersion") }
        if let timeout = value.operationTimeoutSeconds, !(1...900).contains(timeout) {
            throw Failure.invalidPlugin("manifest.operationTimeoutSeconds must be between 1 and 900")
        }
        if value.capabilities?.contains("browser-session") == true, value.homepage.flatMap({ httpURL($0) }) == nil {
            throw Failure.invalidPlugin("browser-session requires manifest.homepage to be HTTP(S)")
        }
        var ids = Set<String>()
        for setting in value.settings ?? [] {
            guard !setting.id.isEmpty, ids.insert(setting.id).inserted else { throw Failure.invalidPlugin("settings.\(setting.id): duplicate or empty ID") }
            let valid: Bool
            switch setting.type.lowercased() {
            case "bool", "boolean", "toggle": valid = setting.defaultValue.boolValue != nil
            case "number": if case .number = setting.defaultValue { valid = true } else { valid = false }
            case "string", "text", "password": valid = setting.defaultValue.stringValue != nil
            case "select", "picker": valid = setting.defaultValue.stringValue.map { setting.options?.contains($0) == true } ?? false
            default: throw Failure.invalidPlugin("settings.\(setting.id).type is unsupported")
            }
            guard valid else { throw Failure.invalidPlugin("settings.\(setting.id).defaultValue does not match type/options") }
        }
        return value
    }
    static func object(_ json: String, limit: Int) throws -> [String: Any] {
        guard json.utf8.count <= limit else { throw Failure.oversizedResult }
        guard let result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw Failure.invalidResult }
        return result
    }
    static func stringify(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    static func resource(_ value: Any?, pluginID: String, baseURL: URL, path: String, warnings: inout [String]) -> PluginResourceRequest? {
        guard let value, !(value is NSNull) else { return nil }
        let object = value as? [String: Any]
        let raw = value as? String ?? object?["url"] as? String
        guard let raw, let url = httpURL(raw, relativeTo: baseURL) else {
            warnings.append("\(path): discarded invalid HTTP(S) resource URL"); return nil
        }
        let referrer = (object?["referrer"] as? String).flatMap { httpURL($0, relativeTo: baseURL) }
        if object?["referrer"] != nil && referrer == nil { warnings.append("\(path).referrer: invalid URL") }
        let request = PluginResourceRequest(url: url, referrer: referrer,
            useBrowserCookies: object?["useBrowserCookies"] as? Bool ?? false, pluginID: pluginID)
        PluginResourceRegistry.shared.register(request)
        return request
    }
    static func catalog(_ json: String, plugin: SourcePlugin, baseURL: URL) throws -> (catalog: RemoteCatalog, warnings: [String], json: String) {
        let object = try object(json, limit: 8_000_000)
        var warnings: [String] = [], used = Set<String>()
        func text(_ value: Any?, _ path: String) -> String? {
            guard let value, !(value is NSNull) else { return nil }
            if let value = value as? String { return value }
            if let value = value as? NSNumber { warnings.append("\(path): coerced number/bool to string"); return value.stringValue }
            warnings.append("\(path): discarded non-string value"); return nil
        }
        func flag(_ value: Any?, _ path: String) -> Bool? {
            guard let value, !(value is NSNull) else { return nil }
            if let number = value as? NSNumber { return number.boolValue }
            if let s = value as? String {
                warnings.append("\(path): coerced string to bool")
                if ["true", "1", "yes"].contains(s.lowercased()) { return true }
                if ["false", "0", "no"].contains(s.lowercased()) { return false }
            }
            warnings.append("\(path): discarded invalid bool"); return nil
        }
        if let comics = object["comics"], !(comics is NSNull), !(comics is [[String: Any]]) { throw Failure.invalidResultDetail("comics must be an array of objects") }
        if let catalogs = object["catalogs"], !(catalogs is NSNull), !(catalogs is [[String: Any]]) { throw Failure.invalidResultDetail("catalogs must be an array of objects") }
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? plugin.name
        var comics: [RemoteComic] = []
        for (index, item) in (object["comics"] as? [[String: Any]] ?? []).enumerated() {
            let path = "comics[\(index)]"
            let title = text(item["title"], path + ".title") ?? "Untitled"
            let rawLink = text(item["link"], path + ".link")
            let link = rawLink.flatMap { httpURL($0, relativeTo: baseURL) }
            if rawLink != nil && link == nil { warnings.append("\(path).link: discarded invalid HTTP(S) URL") }
            let rawID = text(item["id"], path + ".id") ?? rawLink ?? title
            var localID = rawID, duplicate = 0
            while !used.insert(localID).inserted { duplicate += 1; localID = "\(rawID)#\(index)-\(duplicate)" }
            if duplicate > 0 { warnings.append("\(path).id: duplicate ID disambiguated") }
            let cover = resource(item["cover"], pluginID: plugin.id, baseURL: baseURL, path: path + ".cover", warnings: &warnings)
            let mirrors = (item["mirrors"] as? [Any] ?? []).compactMap { value -> URL? in
                guard let s = text(value, path + ".mirrors"), let url = httpURL(s, relativeTo: baseURL) else { return nil }; return url
            }
            let readable = flag(item["canRead"], path + ".canRead") ?? false
            let navigable = flag(item["opensCatalog"], path + ".opensCatalog") ?? false
            if (readable || navigable) && link == nil { warnings.append("\(path).link: required for canRead/opensCatalog") }
            var metadata: [String: String] = [:]
            for (key, value) in item["metadata"] as? [String: Any] ?? [:] { metadata[key] = text(value, path + ".metadata." + key) }
            comics.append(RemoteComic(id: "plugin:\(plugin.id)#\(localID)", title: title,
                description: text(item["description"], path + ".description"), coverString: cover?.url.absoluteString,
                series: text(item["series"], path + ".series"), mirrors: mirrors,
                hasMirrors: flag(item["hasMirrors"], path + ".hasMirrors") ?? !mirrors.isEmpty,
                format: text(item["format"], path + ".format"), metadata: metadata, sourceName: name,
                sourceID: plugin.id, pageString: link?.absoluteString,
                mustRead: flag(item["mustRead"], path + ".mustRead") ?? false,
                mustReadTitle: text(item["mustReadTitle"], path + ".mustReadTitle"), size: text(item["size"], path + ".size"),
                opensCatalog: navigable, canRead: readable, coverResource: cover))
        }
        let folders: [RemoteCatalog.ChildCatalog] = (object["catalogs"] as? [[String: Any]] ?? []).enumerated().compactMap { index, item in
            guard let raw = item["url"] as? String, let url = httpURL(raw, relativeTo: baseURL) else {
                warnings.append("catalogs[\(index)].url: discarded invalid HTTP(S) URL"); return nil
            }
            return RemoteCatalog.ChildCatalog(name: item["name"] as? String ?? url.lastPathComponent, url: url, sourceID: plugin.id)
        }
        if comics.isEmpty && folders.isEmpty { warnings.append("empty-result: no comics or catalogs; check page/session/selectors") }
        let normalized: [String: Any] = ["name": name, "comics": comics.map { ["id": $0.id, "title": $0.title,
            "cover": $0.coverURL?.absoluteString as Any? ?? NSNull(), "link": $0.pageURL?.absoluteString as Any? ?? NSNull(),
            "canRead": $0.canRead, "opensCatalog": $0.opensCatalog,
            "mirrors": $0.mirrors.map(\.absoluteString), "hasMirrors": $0.hasMirrors,
            "size": $0.size as Any? ?? NSNull(), "format": $0.format as Any? ?? NSNull()] as [String: Any] },
            "catalogs": folders.map { ["name": $0.name, "url": $0.url.absoluteString] }]
        return (RemoteCatalog(name: name, sourceURL: baseURL, sourceID: plugin.id, comics: comics, childCatalogs: folders), warnings, stringify(normalized))
    }
    static func pages(_ json: String, pluginID: String, baseURL: URL) throws -> (pages: [URL], resources: [PluginResourceRequest], warnings: [String], json: String) {
        let object = try object(json, limit: 4_000_000)
        guard let entries = object["pages"] as? [Any] else { throw Failure.invalidResultDetail("pages must be an array") }
        var warnings: [String] = [], seen = Set<PluginResourceRequest>(), pages: [URL] = []
        var resources: [PluginResourceRequest] = []
        for (index, entry) in entries.enumerated() {
            if let request = resource(entry, pluginID: pluginID, baseURL: baseURL, path: "pages[\(index)]", warnings: &warnings), seen.insert(request).inserted {
                pages.append(request.url)
                resources.append(request)
            }
        }
        if pages.isEmpty { warnings.append("empty-result: no page images; check page/session/selectors") }
        return (pages, resources, warnings, stringify(["pages": pages.map(\.absoluteString)]))
    }
}
