import AppKit

/// Routes Finder "Open With" and `open -a … file` (which arrive as
/// `application(_:open:)` on the main thread) into the shared model.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !SourcePluginTest.isRequested else { return }
        MainActor.assumeIsolated {
            AppRouter.shared.openExternal(urls)   // jump straight to the reader
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if SourcePluginTest.isRequested {
                // CLI arguments can suppress the initial SwiftUI window, so a
                // view's .task is not a reliable entry point for fixture tests.
                Task { @MainActor in await SourcePluginTest.runIfRequested() }
                return
            }
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
