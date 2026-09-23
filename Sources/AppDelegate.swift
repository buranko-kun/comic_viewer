import AppKit

/// Routes Finder "Open With" and `open -a … file` (which arrive as
/// `application(_:open:)` on the main thread) into the shared model.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppRouter.shared.openExternal(urls)   // jump straight to the reader
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            ComicServer.shared.startIfEnabled()   // resume Wi-Fi sharing if left on
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.cleanupTempDirs()     // remove shared archive temp extractions
            ComicServer.shared.stop()             // stop sharing + clean server temp dirs
        }
    }
}
