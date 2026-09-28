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
            tags: nil,
            capabilities: nil,
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
                    format: "cbz",
                    opensCatalog: true
                }, {
                    id: "readable",
                    title: "Readable",
                    link: "https://example.com/readable",
                    canRead: true
                }],
                catalogs: [{
                    name: "Nested",
                    url: "https://example.com/nested"
                }]
            }),
            parsePages: () => ({
                pages: ["https://example.com/readable/001.jpg"]
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

                guard catalog.comics.count == 2,
                      catalog.comics[0].title == "Alpha",
                      catalog.comics[0].opensCatalog,
                      catalog.comics[1].title == "Readable",
                      catalog.comics[1].canRead,
                      catalog.comics[1].sourceID == "test.source",
                      catalog.childCatalogs.count == 1,
                      catalog.childCatalogs[0].sourceID == "test.source"
                else {
                    throw SourcePluginRuntime.PluginError.invalidResult
                }

                let pages = try await SourcePluginRuntime.shared.pages(
                    plugin: plugin,
                    script: script,
                    at: URL(string: "about:blank")!
                )
                guard pages == [URL(string: "https://example.com/readable/001.jpg")!] else {
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
