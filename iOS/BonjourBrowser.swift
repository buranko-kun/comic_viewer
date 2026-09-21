import Foundation
import SwiftUI

struct DiscoveredServer: Identifiable, Hashable {
    let name: String
    let host: String
    let port: Int
    var id: String { "\(host):\(port)" }
}

/// Discovers desktop comic servers advertised on the LAN (`_comicviewer._tcp`) and resolves each
/// to a host name + port, so the connect screen can offer them as one-tap options.
@MainActor
@Observable
final class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private(set) var servers: [DiscoveredServer] = []
    private let browser = NetServiceBrowser()
    private var resolving: Set<NetService> = []

    func start() {
        servers = []
        browser.delegate = self
        browser.searchForServices(ofType: "_comicviewer._tcp.", inDomain: "local.")
    }

    func stop() { browser.stop() }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            service.delegate = self
            resolving.insert(service)   // retain during resolve
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            resolving.remove(sender)
            guard let host = sender.hostName else { return }
            let clean = host.hasSuffix(".") ? String(host.dropLast()) : host
            let server = DiscoveredServer(name: sender.name, host: clean, port: sender.port)
            if !servers.contains(server) { servers.append(server) }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated { resolving.remove(sender) }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated { servers.removeAll { $0.name == service.name } }
    }
}
