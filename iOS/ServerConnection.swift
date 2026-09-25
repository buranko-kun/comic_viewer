import Foundation
import SwiftUI

/// The current connection to a desktop comic server: host, port, pairing code — persisted so the
/// app reconnects on launch. Owns the shared `ServerClient` used by the rest of the app.
@MainActor
@Observable
final class ServerConnection {
    var host: String { didSet { save(); invalidateConnection() } }
    var port: Int { didSet { save(); invalidateConnection() } }
    var code: String { didSet { save(); invalidateConnection() } }
    private var token: String { didSet { save() } }
    /// True once we've had a successful authenticated connection with the current settings.
    private(set) var isConnected = false
    private(set) var lastError: String?

    private static let hostKey = "conn.host"
    private static let portKey = "conn.port"
    private static let codeKey = "conn.code"
    private static let tokenKey = "conn.token"

    init() {
        let d = UserDefaults.standard
        host = d.string(forKey: Self.hostKey) ?? ""
        port = d.integer(forKey: Self.portKey) == 0 ? 8080 : d.integer(forKey: Self.portKey)
        code = d.string(forKey: Self.codeKey) ?? ""
        token = d.string(forKey: Self.tokenKey) ?? ""
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(host, forKey: Self.hostKey)
        d.set(port, forKey: Self.portKey)
        d.set(code, forKey: Self.codeKey)
        d.set(token, forKey: Self.tokenKey)
    }

    private func invalidateConnection() {
        token = ""
        isConnected = false
    }

    var baseURL: URL? {
        guard !host.isEmpty else { return nil }
        return URL(string: "http://\(host):\(port)")
    }

    var client: ServerClient? { baseURL.map { ServerClient(baseURL: $0, code: code, token: token.isEmpty ? nil : token) } }

    /// Verify reachability, then authenticate. A saved session token is tried first; if the
    /// desktop restarted and discarded it, the code is exchanged for a fresh token automatically.
    func connect() async {
        lastError = nil
        isConnected = false
        guard !host.isEmpty else { lastError = "Enter a server address."; return }
        guard !code.isEmpty else { lastError = "Enter the pairing code."; return }
        guard let baseURL else { lastError = "Enter a server address."; return }

        let probe = ServerClient(baseURL: baseURL, code: code)
        guard await probe.ping() != nil else {
            lastError = "Couldn't reach the server."
            return
        }

        if !token.isEmpty {
            let savedClient = ServerClient(baseURL: baseURL, code: code, token: token)
            do {
                _ = try await savedClient.library(dir: nil)
                isConnected = true
                return
            } catch ServerClient.ClientError.unauthorized {
                token = ""
            } catch {
                // The server may have restarted or briefly failed. Re-pair below if possible.
            }
        }

        do {
            let response = try await probe.pair()
            token = response.token
            let authed = ServerClient(baseURL: baseURL, code: code, token: token)
            _ = try await authed.library(dir: nil)
            isConnected = true
        } catch ServerClient.ClientError.unauthorized {
            token = ""
            lastError = "Wrong pairing code."
        } catch {
            token = ""
            lastError = "Couldn't load the library."
        }
    }

    func disconnect() { isConnected = false }
}
