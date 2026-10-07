import Foundation
import SwiftUI
import Swifter

/// An opt-in LAN HTTP server that shares the local library with other devices (phase 1 of an
/// iPhone companion). Reuses the app's data + image pipeline; access is gated by a pairing code
/// and the service is advertised over Bonjour so clients can discover it. Toggle from Settings.
@MainActor
@Observable
final class ComicServer {
    static let shared = ComicServer()

    nonisolated static let appName = "Comic Viewer"
    nonisolated static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    private(set) var isRunning = false
    private(set) var port = 0
    private(set) var addresses: [String] = []     // LAN IPv4 addresses, for display
    private(set) var pairingCode: String

    /// Session credentials issued after pairing. Storage is thread-safe because HTTP middleware
    /// executes off the main actor.
    private let authStore = ComicServerAuth()
    private var server: HttpServer?
    private var net: NetService?

    private static let enabledKey = "ComicServer.enabled"
    private static let codeKey = "ComicServer.code"

    init() {
        if let c = UserDefaults.standard.string(forKey: Self.codeKey) {
            pairingCode = c
        } else {
            let c = Self.makePairingCode()
            UserDefaults.standard.set(c, forKey: Self.codeKey)
            pairingCode = c
        }
    }

    /// Exchange the human pairing code for a random session token.
    func issueSessionToken(for code: String) -> String? {
        guard code == pairingCode else { return nil }
        return authStore.issueToken()
    }

    /// Generate a new pairing code and invalidate all currently paired devices.
    func regeneratePairingCode() {
        pairingCode = Self.makePairingCode()
        UserDefaults.standard.set(pairingCode, forKey: Self.codeKey)
        authStore.invalidateAll()
        if isRunning {
            stop()
            start()
        }
    }

    private static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    /// Whether sharing is on. Setting it persists the choice and starts/stops the server. (The
    /// lifecycle `stop()` on quit does not change this, so sharing resumes next launch.)
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            newValue ? start() : stop()
        }
    }

    /// Called at launch to resume the server if the user left it on.
    func startIfEnabled() { if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() } }

    /// The primary connection URL for display (first LAN address).
    var primaryURL: String? { addresses.first.map { "http://\($0):\(port)" } }

    func start() {
        guard !isRunning else { return }
        let s = HttpServer()
        let code = pairingCode
        let authStore = self.authStore

        // Ping and pairing are public. Normal API calls accept an issued session token.
        // Query code and HTTP Basic remain supported for OPDS and external readers.
        s.middleware.append { req in
            let p = req.path
            if p == "/api/ping" || p == "/api/pair" { return nil }
            if !p.hasPrefix("/api") && !p.hasPrefix("/opds") { return nil }
            let header = req.headers["x-comic-auth"]
            let tokenQuery = req.queryParams.first { $0.0 == "token" }?.1
            let query = req.queryParams.first { $0.0 == "code" }?.1
            let basic = Self.basicAuthPassword(req.headers["authorization"])
            let ok = authStore.contains(header) || authStore.contains(tokenQuery)
                || query == code || basic == code
            return ok ? nil : .raw(401, "Unauthorized",
                                   ["WWW-Authenticate": "Basic realm=\"Comic Viewer\""], nil)
        }
        ComicServerAPI.register(on: s)
        OPDSServer.register(on: s, code: code)

        var chosen = 0
        for candidate in 8080...8090 {
            do { try s.start(in_port_t(candidate), forceIPv4: true); chosen = candidate; break }
            catch { continue }
        }
        guard chosen != 0 else { return }

        server = s
        port = chosen
        addresses = Self.localIPv4Addresses()
        isRunning = true
        publishBonjour(port: chosen)
    }

    func stop() {
        server?.stop(); server = nil
        net?.stop(); net = nil
        authStore.invalidateAll()
        PageIndex.shared.clear()
        CBZBuilder.shared.clear()
        isRunning = false
        addresses = []
        port = 0
    }

    /// The password from an HTTP `Authorization: Basic <base64(user:pass)>` header, else nil.
    nonisolated static func basicAuthPassword(_ header: String?) -> String? {
        guard let header, header.lowercased().hasPrefix("basic ") else { return nil }
        let b64 = header.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard let data = Data(base64Encoded: b64), let creds = String(data: data, encoding: .utf8),
              let colon = creds.firstIndex(of: ":") else { return nil }
        return String(creds[creds.index(after: colon)...])
    }

    // MARK: - Bonjour

    private func publishBonjour(port: Int) {
        let name = Host.current().localizedName ?? Self.appName
        let ns = NetService(domain: "local.", type: "_comicviewer._tcp.", name: name, port: Int32(port))
        ns.publish()
        net = ns
    }

    // MARK: - Network interfaces

    /// The Mac's non-loopback IPv4 addresses on Wi-Fi/Ethernet (`enX`), for the connection URL.
    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  (flags & IFF_LOOPBACK) == 0,
                  ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }

    /// Thread-safe in-memory session tokens. Tokens are intentionally ephemeral: stopping the LAN
/// server, regenerating the pairing code, or quitting the app invalidates every paired device.
private final class ComicServerAuth {
    private let lock = NSLock()
    private var tokens = Set<String>()

    func issueToken() -> String {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        tokens.insert(token)
        return token
    }

    func contains(_ token: String?) -> Bool {
        guard let token else { return false }
        lock.lock()
        defer { lock.unlock() }
        return tokens.contains(token)
    }

    func invalidateAll() {
        lock.lock()
        tokens.removeAll()
        lock.unlock()
    }
}

}
