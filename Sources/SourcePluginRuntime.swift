import Foundation
import WebKit

/// Runs a third-party source scraper in a WKWebView page context.
///
/// The plugin gets browser JavaScript and DOM access, but no Swift objects, filesystem APIs, or
/// native application message handlers. It returns JSON that is normalized into RemoteCatalog and
/// RemoteComic, the same models used by built-in online sources.
@MainActor
final class SourcePluginRuntime: NSObject, WKNavigationDelegate {
    static let shared = SourcePluginRuntime()

    enum PluginError: LocalizedError {
        case invalidPlugin(String)
        case navigation(Error)
        case javascript(Error)
        case invalidResult
        case invalidResultDetail(String)
        case oversizedResult

        var errorDescription: String? {
            switch self {
            case .invalidPlugin(let message): return "Invalid source plugin: \(message)"
            case .navigation(let error): return "Source page couldn't be loaded: \(error.localizedDescription)"
            case .javascript(let error): return "Source plugin failed: \(error.localizedDescription)"
            case .invalidResult:
                return "Source plugin returned invalid catalog data."
            case .invalidResultDetail(let detail):
                return "Source plugin returned invalid catalog data: \(detail)"
            case .oversizedResult: return "Source plugin returned too much data."
            }
        }
    }

    private let webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    /// All operations use one WKWebView, so navigation and JavaScript execution must never overlap.
    private var operationTail: Task<Void, Never>?

    /// The persistent browser used by plugin parsing. A generic session UI can embed this same
    /// web view so cookies and local storage remain available to subsequent plugin requests.
    var sessionWebView: WKWebView { webView }

    override init() {
        webView = WKWebView(frame: .zero)
        super.init()
        webView.navigationDelegate = self
    }

    /// Open the source homepage in the plugin's persistent browser session so a user can
    /// complete login, cookie, or browser challenge steps required by the source.
    func openSession(for plugin: SourcePlugin) async throws {
        try await serialized {
            guard let rawURL = plugin.homepage, let url = URL(string: rawURL) else {
                throw PluginError.invalidPlugin("source does not declare a valid homepage")
            }
            try await self.load(URLRequest(url: url))
        }
    }

    func manifest(for script: String) async throws -> SourcePluginManifest {
        try await serialized { try await self.manifestImpl(for: script) }
    }

    private func manifestImpl(for script: String) async throws -> SourcePluginManifest {
        try await loadHTML("<!doctype html><html><body></body></html>")
        try await install(script)

        let json = try await callAsyncJSON("""
        return JSON.stringify((() => {
            const source = globalThis.ComicViewerSource;
            if (!source || typeof source !== "object") throw new Error("ComicViewerSource is missing");
            if (!source.manifest || typeof source.manifest !== "object") throw new Error("manifest is missing");
            if (!(typeof source.browseURL === "string" || typeof source.browseURL === "function")) {
                throw new Error("browseURL must be a string or function");
            }
            if (typeof source.parseCatalog !== "function") throw new Error("parseCatalog() is missing");
            return source.manifest;
        })())
        """)

        guard let data = json.data(using: .utf8),
              let manifest = try? JSONDecoder().decode(SourcePluginManifest.self, from: data)
        else {
            throw PluginError.invalidPlugin("manifest has the wrong shape")
        }

        guard !manifest.id.isEmpty,
              manifest.id.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
        else {
            throw PluginError.invalidPlugin("id must contain only letters, numbers, '.', '_' or '-'")
        }

        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginError.invalidPlugin("name is empty")
        }

        guard !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginError.invalidPlugin("version is empty")
        }

        return manifest
    }

    func catalog(plugin: SourcePlugin) async throws -> RemoteCatalog {
        try await serialized {
            guard let script = SourcePluginStore.shared.script(for: plugin) else {
                throw PluginError.invalidPlugin("installed script is missing")
            }
            return try await self.catalogImpl(plugin: plugin, script: script, at: nil)
        }
    }

    func catalog(plugin: SourcePlugin, script: String, at explicitURL: URL?) async throws -> RemoteCatalog {
        try await serialized {
            try await self.catalogImpl(plugin: plugin, script: script, at: explicitURL)
        }
    }

    private func catalogImpl(plugin: SourcePlugin, script: String, at explicitURL: URL?) async throws -> RemoteCatalog {
        let preservesSession = plugin.capabilities?.contains("browser-session") == true
        let url: URL

        if let explicitURL {
            url = explicitURL
            if preservesSession {
                try await ensureSession(for: plugin)
            }
        } else {
            if preservesSession {
                try await ensureSession(for: plugin)
            } else {
                try await loadHTML("<!doctype html><html><body></body></html>")
            }

            try await install(script)
            try await injectSettings(for: plugin)

            let raw = try await callAsyncJSON("""
            return JSON.stringify((async () => {
                const value = ComicViewerSource.browseURL;
                return typeof value === "function" ? await value() : value;
            })())
            """)

            guard let route = decodeJSONString(raw), let resolved = URL(string: route) else {
                throw PluginError.invalidResult
            }
            url = resolved
        }

        return try await parseCatalog(
            plugin: plugin,
            script: script,
            pageURL: url,
            navigate: !preservesSession
        )
    }

    func catalog(plugin: SourcePlugin, at url: URL) async throws -> RemoteCatalog {
        try await serialized {
            guard let script = SourcePluginStore.shared.script(for: plugin) else {
                throw PluginError.invalidPlugin("installed script is missing")
            }
            return try await self.parseCatalog(
                plugin: plugin,
                script: script,
                pageURL: url,
                navigate: plugin.capabilities?.contains("browser-session") != true
            )
        }
    }

    private func parseCatalog(
        plugin: SourcePlugin,
        script: String,
        pageURL: URL,
        navigate: Bool
    ) async throws -> RemoteCatalog {
        if navigate {
            try await load(URLRequest(url: pageURL))
        }
        try await install(script)
        try await injectSettings(for: plugin)

        let json: String
        print("SourcePluginRuntime: parsing catalog for plugin=" + plugin.id
            + " version=" + plugin.version
            + " scriptBytes=" + String(script.utf8.count)
            + " pageURL=" + pageURL.absoluteString
            + " navigate=" + String(navigate))

        if navigate {
            json = try await callAsyncJSON("""
            const result = await ComicViewerSource.parseCatalog();
            const encoded = JSON.stringify(result);
            if (encoded === "{}") {
                throw new Error(
                    "parseCatalog returned {}: type=" + typeof result
                    + "; tag=" + Object.prototype.toString.call(result)
                    + "; keys=" + Object.keys(result || {}).join(",")
                    + "; ownNames=" + Object.getOwnPropertyNames(result || {}).join(",")
                );
            }
            return encoded;
            """)
        } else {
            json = try await callAsyncJSON("""
            const result = await ComicViewerSource.parseCatalog({ url: targetURL });
            const encoded = JSON.stringify(result);
            if (encoded === "{}") {
                throw new Error(
                    "parseCatalog returned {}: type=" + typeof result
                    + "; tag=" + Object.prototype.toString.call(result)
                    + "; keys=" + Object.keys(result || {}).join(",")
                    + "; ownNames=" + Object.getOwnPropertyNames(result || {}).join(",")
                );
            }
            return encoded;
            """, arguments: ["targetURL": pageURL.absoluteString])
        }

        guard json.utf8.count <= 8_000_000 else {
            throw PluginError.oversizedResult
        }

        guard let data = json.data(using: .utf8) else {
            throw PluginError.invalidResult
        }

        let document: PluginCatalog
        do {
            document = try JSONDecoder().decode(PluginCatalog.self, from: data)
        } catch {
            let detail: String
            if case let DecodingError.keyNotFound(key, context) = error {
                detail = "missing key '\(key.stringValue)' at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            } else if case let DecodingError.typeMismatch(type, context) = error {
                detail = "expected \(type) at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
            } else if case let DecodingError.valueNotFound(type, context) = error {
                detail = "missing \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            } else if case let DecodingError.dataCorrupted(context) = error {
                detail = "data corrupted at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            } else {
                detail = error.localizedDescription
            }

            var shape = "unavailable"
            if let object = try? JSONSerialization.jsonObject(with: data) {
                if let dictionary = object as? [String: Any] {
                    let keys = dictionary.keys.sorted().joined(separator: ",")
                    if let comics = dictionary["comics"] as? [Any] {
                        var firstTypes = "none"
                        if let first = comics.first as? [String: Any] {
                            firstTypes = first.keys.sorted().map { key in
                                let type = String(describing: Swift.type(of: first[key] as Any))
                                return key + "=" + type
                            }.joined(separator: ", ")
                        }
                        shape = "top-level keys=[" + keys
                            + "]; comics.count=" + String(comics.count)
                            + "; comics[0] types=[" + firstTypes + "]"
                    } else if let comicsValue = dictionary["comics"] {
                        shape = "top-level keys=[" + keys
                            + "]; comics is "
                            + String(describing: Swift.type(of: comicsValue))
                    } else {
                        shape = "top-level keys=[" + keys + "]; comics is missing"
                    }
                } else {
                    shape = "top-level JSON type="
                        + String(describing: Swift.type(of: object))
                }
            }

            let prefix = String(json.prefix(1500))
            print("SourcePluginRuntime: catalog JSON decoding failed: " + detail
                + "; bytes=" + String(json.utf8.count)
                + "; " + shape)
            print("SourcePluginRuntime: catalog JSON prefix: " + prefix)
            throw PluginError.invalidResultDetail("\(detail); \(shape)")
        }

        let sourceName = document.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? document.name!
            : plugin.name

        var seenIDs = Set<String>()

        let comics = (document.comics ?? []).enumerated().map { index, item -> RemoteComic in
            let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? item.title!
                : "Untitled"
            let localID = item.id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? item.id!
                : item.link ?? item.title ?? "comic"
            let uniqueID = seenIDs.insert(localID).inserted ? localID : "\(localID)#\(index)"
            let mirrors = (item.mirrors ?? []).compactMap { resolveURL($0, relativeTo: pageURL) }
            let cover = item.cover.flatMap { resolveURL($0, relativeTo: pageURL)?.absoluteString }
            let link = item.link.flatMap { resolveURL($0, relativeTo: pageURL)?.absoluteString }

            return RemoteComic(
                id: "plugin:\(plugin.id)#\(uniqueID)",
                title: title,
                description: item.description,
                coverString: cover,
                series: item.series,
                mirrors: mirrors,
                hasMirrors: item.hasMirrors ?? !mirrors.isEmpty,
                format: item.format,
                metadata: item.metadata ?? [:],
                sourceName: sourceName,
                sourceID: plugin.id,
                pageString: link,
                mustRead: item.mustRead ?? false,
                mustReadTitle: item.mustReadTitle,
                size: item.size,
                opensCatalog: item.opensCatalog ?? false,
                canRead: item.canRead ?? false
            )
        }

        let folders = (document.catalogs ?? []).compactMap { item -> RemoteCatalog.ChildCatalog? in
            guard let url = resolveURL(item.url, relativeTo: pageURL) else { return nil }
            let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? item.name!
                : url.deletingPathExtension().lastPathComponent
            return RemoteCatalog.ChildCatalog(name: name, url: url, sourceID: plugin.id)
        }

        return RemoteCatalog(
            name: sourceName,
            sourceURL: pageURL,
            sourceID: plugin.id,
            comics: comics,
            childCatalogs: folders
        )
    }

    private struct PluginCatalog: Decodable {
        let name: String?
        let comics: [PluginComic]?
        let catalogs: [PluginCatalogRef]?
    }

    private struct PluginComic: Decodable {
        let id: String?
        let title: String?
        let description: String?
        let cover: String?
        let series: String?
        let format: String?
        let mirrors: [String]?
        let hasMirrors: Bool?
        let link: String?
        let size: String?
        let mustRead: Bool?
        let mustReadTitle: String?
        let metadata: [String: String]?
        let opensCatalog: Bool?
        let canRead: Bool?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeLossyString(forKey: .id)
            title = try c.decodeLossyString(forKey: .title)
            description = try c.decodeLossyString(forKey: .description)
            cover = try c.decodeLossyString(forKey: .cover)
            series = try c.decodeLossyString(forKey: .series)
            format = try c.decodeLossyString(forKey: .format)
            mirrors = try c.decodeLossyStringArray(forKey: .mirrors)
            hasMirrors = try c.decodeLossyBool(forKey: .hasMirrors)
            link = try c.decodeLossyString(forKey: .link)
            size = try c.decodeLossyString(forKey: .size)
            mustRead = try c.decodeLossyBool(forKey: .mustRead)
            mustReadTitle = try c.decodeLossyString(forKey: .mustReadTitle)
            metadata = try c.decodeLossyStringDictionary(forKey: .metadata)
            opensCatalog = try c.decodeLossyBool(forKey: .opensCatalog)
            canRead = try c.decodeLossyBool(forKey: .canRead)
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, description, cover, series, format, mirrors, hasMirrors, link, size
            case mustRead, mustReadTitle, metadata, opensCatalog, canRead
        }
    }


    private struct PluginCatalogRef: Decodable {
        let name: String?
        let url: String
    }

    /// Resolve a readable plugin comic into its ordered page-image URLs.
    func pages(for plugin: SourcePlugin, comic: RemoteComic) async throws -> [URL] {
        try await serialized {
            guard let script = SourcePluginStore.shared.script(for: plugin) else {
                throw PluginError.invalidPlugin("installed script is missing")
            }
            guard comic.canRead, let url = comic.pageURL else {
                throw PluginError.invalidPlugin("comic is not readable by this plugin")
            }
            return try await self.pagesImpl(plugin: plugin, script: script, at: url)
        }
    }

    func pages(plugin: SourcePlugin, script: String, at pageURL: URL) async throws -> [URL] {
        try await serialized {
            try await self.pagesImpl(plugin: plugin, script: script, at: pageURL)
        }
    }

    private func pagesImpl(plugin: SourcePlugin, script: String, at pageURL: URL) async throws -> [URL] {
        let preservesSession = plugin.capabilities?.contains("browser-session") == true
        if preservesSession {
            try await ensureSession(for: plugin)
        } else {
            try await load(URLRequest(url: pageURL))
        }
        try await install(script)
        try await injectSettings(for: plugin)

        let json: String
        if preservesSession {
            json = try await callAsyncJSON("""
            return JSON.stringify(await ComicViewerSource.parsePages({ url: targetURL }))
            """, arguments: ["targetURL": pageURL.absoluteString])
        } else {
            json = try await callAsyncJSON("""
            return JSON.stringify(await ComicViewerSource.parsePages())
            """)
        }

        guard json.utf8.count <= 4_000_000 else {
            throw PluginError.oversizedResult
        }

        guard let data = json.data(using: .utf8),
              let document = try? JSONDecoder().decode(PluginPages.self, from: data)
        else {
            throw PluginError.invalidResult
        }

        var seen = Set<String>()
        return document.pages.compactMap { raw -> URL? in
            guard let url = resolveURL(raw, relativeTo: pageURL),
                  seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    private struct PluginPages: Decodable {
        let pages: [String]
    }

    private func serialized<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = operationTail
        let task = Task { @MainActor in
            if let previous {
                await previous.value
            }
            return try await operation()
        }
        operationTail = Task { @MainActor in
            _ = try? await task.value
        }
        return try await task.value
    }

    private func install(_ script: String) async throws {
        _ = try await evaluateJavaScript("""
        delete globalThis.ComicViewerSource;
        \(script)
        void 0;
        """)
    }

    private func injectSettings(for plugin: SourcePlugin) async throws {
        let json = await MainActor.run {
            SourcePluginSettingsStore.shared.settingsJSON(for: plugin)
        }
        _ = try await webView.callAsyncJavaScript(
            """
            const source = globalThis.ComicViewerSource;
            if (source && typeof source === "object") {
                source.settings = JSON.parse(settingsJSON);
            }
            return null;
            """,
            arguments: ["settingsJSON": json],
            in: nil,
            contentWorld: .page
        )
    }

    private func ensureSession(for plugin: SourcePlugin) async throws {
        guard let rawHomepage = plugin.homepage,
              let homepage = URL(string: rawHomepage),
              let host = homepage.host else {
            throw PluginError.invalidPlugin("source does not declare a valid homepage")
        }

        if let current = webView.url,
           current.scheme == homepage.scheme,
           current.host == host {
            return
        }

        try await load(URLRequest(url: homepage))
    }

    private func resolveURL(_ raw: String, relativeTo base: URL?) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let absolute = URL(string: trimmed), absolute.scheme != nil { return absolute }
        guard let base else { return nil }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    private func decodeJSONString(_ json: String) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(json.utf8))
    }

    private func loadHTML(_ html: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func load(_ request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation = continuation
            webView.load(request)
        }
    }

    private func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: PluginError.javascript(error)) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    private func callAsyncJSON(_ script: String, arguments: [String: Any] = [:]) async throws -> String {
        print("SourcePluginRuntime: CALL-ASYNC-JSON BUILD MARKER 2026-09-28")
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: nil,
                contentWorld: .page
            )
        } catch {
            throw PluginError.javascript(error)
        }

        guard let text = value as? String else {
            print("SourcePluginRuntime: callAsyncJavaScript returned non-String value: "
                + String(describing: value))
            throw PluginError.invalidResult
        }
        print("SourcePluginRuntime: callAsyncJavaScript returned JSON bytes="
            + String(text.utf8.count)
            + ", prefix=" + String(text.prefix(300)))
        return text
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        continuation.resume()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(with: PluginError.navigation(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finishNavigation(with: PluginError.navigation(error))
    }

    private func finishNavigation(with error: Error) {
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        continuation.resume(throwing: error)
    }
}

fileprivate extension KeyedDecodingContainer {
    func decodeLossyString(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        if let value = try? decode(Bool.self, forKey: key) { return String(value) }
        return nil
    }

    func decodeLossyBool(forKey key: Key) throws -> Bool? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        return nil
    }

    func decodeLossyStringArray(forKey key: Key) throws -> [String]? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let values = try? decode([String].self, forKey: key) { return values }
        if let values = try? decode([Int].self, forKey: key) { return values.map { String($0) } }
        return nil
    }

    func decodeLossyStringDictionary(forKey key: Key) throws -> [String: String]? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let values = try? decode([String: String].self, forKey: key) { return values }
        if let values = try? decode([String: Int].self, forKey: key) {
            return values.mapValues { String($0) }
        }
        if let values = try? decode([String: Double].self, forKey: key) {
            return values.mapValues { String($0) }
        }
        return nil
    }
}
