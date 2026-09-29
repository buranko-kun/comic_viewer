import Foundation
import AppKit

/// CLI fixture entry point. Runs the actual WebKit runtime while keeping its main run loop alive.
/// No installed plugin, settings, or session storage is modified.
enum SourcePluginTest {
    @MainActor static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--sourceplugintest") || args.contains("--plugin-fixtures") else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                if let index = args.firstIndex(of: "--plugin-fixtures"), args.count > index + 2 {
                    try await SourcePluginFixtureRunner.run(
                        scriptURL: URL(fileURLWithPath: args[index + 1]),
                        suiteURL: URL(fileURLWithPath: args[index + 2]))
                } else if args.contains("--sourceplugintest") {
                    try await SourcePluginFixtureRunner.smoke()
                } else {
                    throw SourcePluginFixtureRunner.Failure("Usage: --plugin-fixtures <plugin.js> <suite.json>")
                }
                print("plugin tests: PASS")
                exit(0)
            } catch {
                fputs("plugin tests: FAIL: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        // The previous semaphore blocked the MainActor and always returned exit(0).
        RunLoop.main.run()
        exit(1)
    }
}

@MainActor
enum SourcePluginFixtureRunner {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func run(scriptURL: URL, suiteURL: URL) async throws {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        guard let suite = try JSONSerialization.jsonObject(with: Data(contentsOf: suiteURL)) as? [String: Any],
              let cases = suite["cases"] as? [[String: Any]], !cases.isEmpty else {
            throw Failure("Fixture suite requires a nonempty cases array")
        }
        let directory = suiteURL.deletingLastPathComponent()
        for fixture in cases {
            let name = fixture["name"] as? String ?? "Unnamed fixture"
            do { try await runCase(fixture, script: script, sourceURL: scriptURL, directory: directory) }
            catch { throw Failure("\(name): \(error.localizedDescription)") }
            print("PASS \(name)")
        }
    }

    static func runCase(_ fixture: [String: Any], script: String, sourceURL: URL, directory: URL) async throws {
        let runtime = SourcePluginRuntime()
        let manifest = try await runtime.manifest(for: script)
        var plugin = SourcePlugin(id: manifest.id, name: manifest.name, version: manifest.version,
                                  homepage: manifest.homepage, description: manifest.description,
                                  tags: manifest.tags, capabilities: manifest.capabilities, settings: manifest.settings,
                                  sourceURL: sourceURL, fileName: "fixture.js", installedAt: Date(), enabled: true)
        plugin.apiVersion = manifest.apiVersion
        plugin.scriptHash = CentralStore.sha256(script)
        plugin.operationTimeoutSeconds = 5
        guard let target = fixture["url"] as? String, let url = URL(string: target) else {
            throw Failure("Fixture requires url")
        }
        var responses = fixture["responses"] as? [String: [String: Any]] ?? [:]
        for (url, var response) in responses {
            if let file = response.removeValue(forKey: "file") as? String {
                response["body"] = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            }
            responses[url] = response
        }
        let html: String
        if let file = fixture["htmlFile"] as? String {
            html = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
        } else { html = fixture["html"] as? String ?? "<!doctype html><html><body></body></html>" }
        let responsesJSON = String(data: try JSONSerialization.data(withJSONObject: responses), encoding: .utf8)!
        let settingsJSON = String(data: try JSONSerialization.data(withJSONObject: fixture["settings"] as? [String: Any] ?? [:]), encoding: .utf8)!
        runtime.setFixture(pluginID: plugin.id, html: html, baseURL: url, responsesJSON: responsesJSON, settingsJSON: settingsJSON)
        defer { runtime.clearFixture(pluginID: plugin.id) }
        let repeats = max(1, fixture["repeat"] as? Int ?? 1)
        for _ in 0..<repeats {
            let output: [String: Any]
            do {
                switch fixture["operation"] as? String ?? "catalog" {
                case "pages":
                    let pages = try await runtime.pages(plugin: plugin, script: script, at: url)
                    output = ["pages": pages.map(\.absoluteString)]
                case "catalog":
                    let catalog = try await runtime.catalog(plugin: plugin, script: script, at: url)
                    output = ["name": catalog.name, "comics": catalog.comics.map { comic -> [String: Any] in
                        ["title": comic.title, "cover": comic.coverURL?.absoluteString as Any? ?? NSNull(),
                         "link": comic.pageURL?.absoluteString as Any? ?? NSNull(),
                         "canRead": comic.canRead, "opensCatalog": comic.opensCatalog]
                    }, "catalogs": catalog.childCatalogs.map { ["name": $0.name, "url": $0.url.absoluteString] }]
                default: throw Failure("Unknown fixture operation")
                }
            } catch {
                if let expectedError = fixture["expectedError"] as? String,
                   error.localizedDescription.contains(expectedError) { return }
                throw error
            }
            if fixture["expectedError"] != nil { throw Failure("Expected operation to fail") }
            if let expected = fixture["expected"] { try match(expected, output, path: "$result") }
        }
        if let expected = fixture["requestCount"] as? Int {
            let requests = await runtime.fixtureRequestURLs(pluginID: plugin.id)
            guard requests.count == expected else { throw Failure("Expected \(expected) requests, got \(requests.count): \(requests)") }
        }
    }

    /// Object expectations are subsets; array expectations assert exact length and order.
    static func match(_ expected: Any, _ actual: Any, path: String) throws {
        if let object = expected as? [String: Any] {
            guard let actual = actual as? [String: Any] else { throw Failure("\(path): expected object") }
            for (key, value) in object {
                guard let found = actual[key] else { throw Failure("\(path).\(key): missing") }
                try match(value, found, path: path + "." + key)
            }
        } else if let array = expected as? [Any] {
            guard let actual = actual as? [Any], actual.count == array.count else { throw Failure("\(path): array length differs") }
            for index in array.indices { try match(array[index], actual[index], path: "\(path)[\(index)]") }
        } else {
            guard let lhs = expected as? NSObject, let rhs = actual as? NSObject, lhs == rhs else {
                throw Failure("\(path): expected \(expected), got \(actual)")
            }
        }
    }

    static func smoke() async throws {
        let script = """
        globalThis.ComicViewerSource = {
            manifest: {id:'fixture.smoke', name:'Smoke', version:'1'}, browseURL:'https://fixture.invalid/catalog',
            parseCatalog(context) { return {comics: [{id:'one', title:document.querySelector('h1').textContent,
                cover:'cover.jpg', link:'issue', canRead:true}], catalogs:[]}; },
            parsePages() { return {pages:['one.jpg','two.jpg','one.jpg']}; }
        };
        """
        try await runCase(["url": "https://fixture.invalid/catalog", "html": "<h1>Fixture comic</h1>",
                           "expected": ["comics": [["title": "Fixture comic", "cover": "https://fixture.invalid/cover.jpg"]]]],
                          script: script, sourceURL: URL(fileURLWithPath: "/fixture.js"), directory: URL(fileURLWithPath: "/tmp"))
    }
}
