import Foundation

enum SourcePluginTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--sourceplugintest") else { return }

        let plugin = SourcePlugin(
            id: "test.source",
            name: "Test Source",
            version: "1.0.0",
            homepage: nil,
            description: "Headless test plugin",
            sourceURL: URL(string: "https://example.com/plugin.js")!,
            fileName: "test-source.js",
            installedAt: Date(),
            enabled: true
        )

        let script = """
        globalThis.ComicViewerSource = {
            manifest: {
                id: "test.source",
                name: "Test Source",
                version: "1.0.0"
            },
            browseURL: "about:blank",
            parseCatalog: () => ({
                name: "Test Source",
                comics: [{
                    id: "alpha",
                    title: "Alpha",
                    cover: "https://example.com/alpha.jpg",
                    link: "https://example.com/alpha",
                    mirrors: ["https://example.com/alpha.cbz"],
                    format: "cbz"
                }],
                catalogs: [{
                    name: "Nested",
                    url: "https://example.com/nested"
                }]
            })
        };
        """

        let semaphore = DispatchSemaphore(value: 0)

        Task { @MainActor in
            do {
                _ = try await SourcePluginRuntime.shared.manifest(for: script)
                let catalog = try await SourcePluginRuntime.shared.catalog(
                    plugin: plugin,
                    script: script,
                    at: URL(string: "about:blank")!
                )

                guard catalog.comics.count == 1,
                      catalog.comics[0].title == "Alpha",
                      catalog.comics[0].sourceID == "test.source",
                      catalog.childCatalogs.count == 1,
                      catalog.childCatalogs[0].sourceID == "test.source"
                else {
                    throw SourcePluginRuntime.PluginError.invalidResult
                }

                print("sourceplugintest: PASS")
            } catch {
                print("sourceplugintest: ERROR \(error.localizedDescription)")
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 30)
        exit(0)
    }
}
