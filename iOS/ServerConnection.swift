import Foundation
import SwiftUI

/// The current connection to a desktop comic server: host, port, pairing code — persisted so the
/// app reconnects on launch. Owns the shared `ServerClient` used by the rest of the app.
@MainActor
@Observable
final class ServerConnection {
    var host: String { didSet { save() } }
    var port: Int { didSet { save() } }
    var code: String { didSet { save() } }
    /// True once we've had a successful ping with the current settings.
    private(set) var isConnected = false
    private(set) var lastError: String?

    private static let hostKey = "conn.host"
    private static let portKey = "conn.port"
    private static let codeKey = "conn.code"

    init() {
        let d = UserDefaults.standard
        host = d.string(forKey: Self.hostKey) ?? ""
        port = d.integer(forKey: Self.portKey) == 0 ? 8080 : d.integer(forKey: Self.portKey)
        code = d.string(forKey: Self.codeKey) ?? ""
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(host, forKey: Self.hostKey)
        d.set(port, forKey: Self.portKey)
        d.set(code, forKey: Self.codeKey)
    }

    var baseURL: URL? {
        guard !host.isEmpty else { return nil }
        return URL(string: "http://\(host):\(port)")
    }

    var client: ServerClient? { baseURL.map { ServerClient(baseURL: $0, code: code) } }

    /// Verify the server is reachable and the pairing code is accepted.
    func connect() async {
        lastError = nil
        guard let client else { lastError = "Enter a server address."; return }
        guard await client.ping() != nil else {
            isConnected = false; lastError = "Couldn't reach the server."; return
        }
        // Ping needs no auth; confirm the code by hitting an authed endpoint.
        do {
            _ = try await client.library(dir: nil)
            isConnected = true
        } catch ServerClient.ClientError.unauthorized {
            isConnected = false; lastError = "Wrong pairing code."
        } catch {
            isConnected = false; lastError = "Couldn't load the library."
        }
    }

    func disconnect() { isConnected = false }
}
