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
        case oversizedResult

        var errorDescription: String? {
            switch self {
            case .invalidPlugin(let message): return "Invalid source plugin: \(message)"
            case .navigation(let error): return "Source page couldn't be loaded: \(error.localizedDescription)"
            case .javascript(let error): return "Source plugin failed: \(error.localizedDescription)"
            case .invalidResult: return "Source plugin returned invalid catalog data."
            case .oversizedResult: return "Source plugin returned too much data."
            }
        }
    }

    private let webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    override init() {
        webView = WKWebView(frame: .zero)
        super.init()
        webView.navigationDelegate = self
    }

    func manifest(for script: String) async throws -> SourcePluginManifest {
        try await loadHTML("<!doctype html><html><body></body></html>")
        try await install(script)

        let json = try await callAsyncJSON("""
        JSON.stringify((() => {
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
        guard let script = SourcePluginStore.shared.script(for: plugin) else {
            throw PluginError.invalidPlugin("installed script is missing")
        }
        return try await catalog(plugin: plugin, script: script, at: nil)
    }

    func catalog(plugin: SourcePlugin, script: String, at explicitURL: URL?) async throws -> RemoteCatalog {
        let url: URL

        if let explicitURL {
            url = explicitURL
        } else {
            try await loadHTML("<!doctype html><html><body></body></html>")
            try await install(script)

            let raw = try await callAsyncJSON("""
            JSON.stringify((async () => {
                const value = ComicViewerSource.browseURL;
                return typeof value === "function" ? await value() : value;
            })())
            """)

            guard let route = decodeJSONString(raw), let resolved = URL(string: route) else {
                throw PluginError.invalidResult
            }
            url = resolved
        }

        return try await parseCatalog(plugin: plugin, script: script, pageURL: url)
    }

    func catalog(plugin: SourcePlugin, at url: URL) async throws -> RemoteCatalog {
        guard let script = SourcePluginStore.shared.script(for: plugin) else {
            throw PluginError.invalidPlugin("installed script is missing")
        }
        return try await parseCatalog(plugin: plugin, script: script, pageURL: url)
    }

    private func parseCatalog(plugin: SourcePlugin, script: String, pageURL: URL) async throws -> RemoteCatalog {
        try await load(URLRequest(url: pageURL))
        try await install(script)

        let json = try await callAsyncJSON("""
        JSON.stringify(await ComicViewerSource.parseCatalog())
        """)

        guard json.utf8.count <= 2_000_000 else {
            throw PluginError.oversizedResult
        }

        guard let data = json.data(using: .utf8),
              let document = try? JSONDecoder().decode(PluginCatalog.self, from: data)
        else {
            throw PluginError.invalidResult
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
                size: item.size
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
    }

    private struct PluginCatalogRef: Decodable {
        let name: String?
        let url: String
    }

    private func install(_ script: String) async throws {
        _ = try await evaluateJavaScript("""
        delete globalThis.ComicViewerSource;
        \(script)
        void 0;
        """)
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
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: nil,
                contentWorld: .page
            ) { result in
                switch result {
                case .success(let value):
                    guard let text = value as? String else {
                        continuation.resume(throwing: PluginError.invalidResult)
                        return
                    }
                    continuation.resume(returning: text)
                case .failure(let error):
                    continuation.resume(throwing: PluginError.javascript(error))
                }
            }
        }
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
