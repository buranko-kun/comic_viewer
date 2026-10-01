import Foundation
import WebKit
import ImageIO

/// Resource context is serializable; credentials themselves are never persisted in reading history.
struct PluginResourceRequest: Codable, Hashable {
    var url: URL
    var referrer: URL?
    var useBrowserCookies: Bool
    var pluginID: String?

    init(url: URL, referrer: URL? = nil, useBrowserCookies: Bool = false, pluginID: String? = nil) {
        self.url = url; self.referrer = referrer
        self.useBrowserCookies = useBrowserCookies; self.pluginID = pluginID
    }

    private enum CodingKeys: String, CodingKey { case url, referrer, useBrowserCookies, pluginID }
    init(from decoder: Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(String.self), let url = URL(string: raw) {
            self.init(url: url); return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: try c.decode(URL.self, forKey: .url),
                  referrer: try c.decodeIfPresent(URL.self, forKey: .referrer),
                  useBrowserCookies: try c.decodeIfPresent(Bool.self, forKey: .useBrowserCookies) ?? false,
                  pluginID: try c.decodeIfPresent(String.self, forKey: .pluginID))
    }

    func cacheKey(maxPixel: Int) -> String {
        let epoch = useBrowserCookies ? PluginResourceRegistry.shared.sessionEpoch : "public"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let revision = PluginResourceRegistry.shared.revision(for: pluginID)
        let encoded = (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? url.absoluteString
        return CentralStore.sha256(encoded + "|size=\(maxPixel)|session=\(epoch)|revision=\(revision)")
    }
}

/// Compatibility bridge for existing URL-based reader/thumbnail APIs. New code should carry the
/// explicit request; history persists those requests and restores them before returning comics.
final class PluginResourceRegistry: @unchecked Sendable {
    static let shared = PluginResourceRegistry()
    private let lock = NSLock()
    private var resources: [URL: PluginResourceRequest] = [:]
    private var epoch = UUID().uuidString
    private var revisions: [String: String] = [:]
    func revision(for pluginID: String?) -> String {
        lock.lock(); defer { lock.unlock() }
        return pluginID.flatMap { revisions[$0] } ?? "initial"
    }
    var sessionEpoch: String { lock.lock(); defer { lock.unlock() }; return epoch }
    /// Bind context to a unique internal URL so two sources using one CDN URL cannot collide.
    func boundURL(for request: PluginResourceRequest) -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(request)) ?? Data()
        var parts = URLComponents(url: request.url, resolvingAgainstBaseURL: true)!
        parts.fragment = "comicviewer-resource=" + CentralStore.sha256(String(decoding: data, as: UTF8.self))
        let alias = parts.url!
        lock.lock(); resources[alias] = request; lock.unlock()
        return alias
    }
    func register(_ request: PluginResourceRequest) {
        lock.lock(); defer { lock.unlock() }; resources[request.url] = request
    }
    func request(for url: URL) -> PluginResourceRequest {
        lock.lock(); defer { lock.unlock() }; return resources[url] ?? PluginResourceRequest(url: url)
    }
    func invalidateSession(pluginID: String? = nil) {
        lock.lock(); defer { lock.unlock() }; epoch = UUID().uuidString
        if let pluginID { revisions[pluginID] = UUID().uuidString }
    }
}

enum PluginResourceError: LocalizedError {
    case invalidURL, http(Int), nonImage, decode, network(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Image resource must use HTTP or HTTPS."
        case .http(let status): return "Image server returned HTTP \(status)."
        case .nonImage: return "Image server returned a non-image response."
        case .decode: return "Image response could not be decoded."
        case .network(let message): return "Image request failed: \(message)"
        }
    }
    var retryable: Bool {
        switch self {
        case .http(let status): return status == 429 || status >= 500
        case .network: return true
        default: return false
        }
    }
}

@MainActor
private final class ResourceCookieObserver: NSObject, WKHTTPCookieStoreObserver {
    static let shared = ResourceCookieObserver()
    override init() {
        super.init()
        WKWebsiteDataStore.default().httpCookieStore.add(self)
    }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        PluginResourceRegistry.shared.invalidateSession()
    }
    func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }
}

/// Uses a fresh, cookie-disabled URLSession and explicitly filters browser cookies for every hop.
/// A redirect can never inherit the previous host's Cookie header or downgrade HTTPS credentials.
final class PluginResourceTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let resource: PluginResourceRequest
    private let cookies: [HTTPCookie]
    init(resource: PluginResourceRequest, cookies: [HTTPCookie]) {
        self.resource = resource; self.cookies = cookies
    }

    static func cookieMatches(_ cookie: HTTPCookie, url: URL, now: Date = Date()) -> Bool {
        guard let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        let rawDomain = cookie.domain.lowercased()
        let domain = rawDomain.hasPrefix(".") ? String(rawDomain.dropFirst()) : rawDomain
        guard host == domain || (rawDomain.hasPrefix(".") && host.hasSuffix("." + domain)) else { return false }
        guard !cookie.isSecure || url.scheme?.lowercased() == "https" else { return false }
        guard cookie.expiresDate.map({ $0 > now }) ?? true else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        return path == cookiePath || (path.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
    }

    func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        if resource.useBrowserCookies {
            let matching = cookies.filter { Self.cookieMatches($0, url: url) }
            for (name, value) in HTTPCookie.requestHeaderFields(with: matching) { request.setValue(value, forHTTPHeaderField: name) }
        }
        if let referrer = resource.referrer,
           ["http", "https"].contains(referrer.scheme?.lowercased() ?? ""),
           !(referrer.scheme == "https" && url.scheme == "http") {
            var parts = URLComponents(url: referrer, resolvingAgainstBaseURL: true)
            parts?.user = nil; parts?.password = nil; parts?.fragment = nil
            if referrer.host != url.host || referrer.port != url.port || referrer.scheme != url.scheme { parts?.path = "/"; parts?.query = nil }
            request.setValue(parts?.url?.absoluteString, forHTTPHeaderField: "Referer")
        }
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = newRequest.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !(response.url?.scheme == "https" && url.scheme == "http") else { completionHandler(nil); return }
        completionHandler(request(for: url))
    }

    static func data(for resource: PluginResourceRequest, cookies: [HTTPCookie]? = nil) async throws -> Data {
        try await fetch(resource, cookies: cookies).data
    }

    private static func fetch(_ resource: PluginResourceRequest, cookies suppliedCookies: [HTTPCookie]? = nil) async throws -> (data: Data, response: URLResponse) {
        guard ["http", "https"].contains(resource.url.scheme?.lowercased() ?? ""), resource.url.host != nil else { throw PluginResourceError.invalidURL }
        let cookies: [HTTPCookie]
        if let suppliedCookies { cookies = suppliedCookies }
        else { cookies = resource.useBrowserCookies ? await ResourceCookieObserver.shared.cookies() : [] }
        let delegate = PluginResourceTransport(resource: resource, cookies: cookies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: delegate.request(for: resource.url))
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw PluginResourceError.http(http.statusCode) }
            if let mime = response.mimeType, mime == "text/html" || mime == "application/json" { throw PluginResourceError.nonImage }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary) != nil else { throw PluginResourceError.decode }
            return (data, response)
        } catch let error as PluginResourceError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw PluginResourceError.network("transport error \((error as NSError).code)") }
    }

    struct Probe: Codable {
        let success: Bool
        let byteCount: Int
        let message: String
        let statusCode: Int?
        let contentType: String?
    }
    static func probe(_ resource: PluginResourceRequest) async -> Probe {
        do {
            let result = try await fetch(resource)
            return Probe(success: true, byteCount: result.data.count, message: "Image decoded successfully",
                         statusCode: (result.response as? HTTPURLResponse)?.statusCode, contentType: result.response.mimeType)
        } catch PluginResourceError.http(let status) {
            return Probe(success: false, byteCount: 0, message: PluginResourceError.http(status).localizedDescription,
                         statusCode: status, contentType: nil)
        } catch {
            return Probe(success: false, byteCount: 0, message: error.localizedDescription, statusCode: nil, contentType: nil)
        }
    }
}
