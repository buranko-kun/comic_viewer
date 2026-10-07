import SwiftUI

@main
struct ComicViewerMobileApp: App {
    @State private var connection = ServerConnection()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(connection)
                .preferredColorScheme(.dark)
        }
    }
}

/// Shows the connect screen until we've reached a server, then the library.
private struct RootView: View {
    @Environment(ServerConnection.self) private var connection

    var body: some View {
        Group {
            if connection.isConnected {
                LibraryBrowseView(dir: nil, title: "Library")
            } else {
                ConnectView()
            }
        }
        .task {
            // Reconnect automatically if we already have a saved server + code.
            if !connection.isConnected, !connection.host.isEmpty, !connection.code.isEmpty {
                await connection.connect()
            }
        }
    }
}
