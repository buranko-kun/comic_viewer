import Foundation
import AppKit

/// CLI fixture/live entry point, started by the app delegate after AppKit launches.
/// Fixtures are isolated; --plugin-live uses the browser session and plugin cache.
enum SourcePluginTest {
    static var isRequested: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--sourceplugintest") || args.contains("--plugin-fixtures") || args.contains("--plugin-live")
    }

    @MainActor static func runIfRequested() async {
        guard isRequested else { return }
        setbuf(stdout, nil) // Keep fixture progress visible when output is piped.
        print("plugin tests: starting")
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "--plugin-live"), args.count > index + 2 {
                let scriptURL = URL(fileURLWithPath: args[index + 1])
                let script = try String(contentsOf: scriptURL, encoding: .utf8)
                try await SourcePluginFixtureRunner.runCase(["url": args[index + 2]], script: script, sourceURL: scriptURL, directory: scriptURL.deletingLastPathComponent(), live: true)
            } else if let index = args.firstIndex(of: "--plugin-fixtures"), args.count > index + 2 {
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
            print("RUN \(name)")
            do { try await runCase(fixture, script: script, sourceURL: scriptURL, directory: directory) }
            catch { throw Failure("\(name): \(error.localizedDescription)") }
            print("PASS \(name)")
        }
    }

    static func runCase(_ fixture: [String: Any], script: String, sourceURL: URL, directory: URL, live: Bool = false) async throws {
        let runtime = SourcePluginRuntime()
        let manifest = try await runtime.manifest(for: script)
        var plugin = SourcePlugin(id: manifest.id, name: manifest.name, version: manifest.version,
                                  homepage: manifest.homepage, description: manifest.description,
                                  tags: manifest.tags, capabilities: manifest.capabilities, settings: manifest.settings,
                                  sourceURL: sourceURL, fileName: "fixture.js", installedAt: Date(), enabled: true)
        plugin.apiVersion = manifest.apiVersion
        plugin.scriptHash = CentralStore.sha256(script)
        plugin.operationTimeoutSeconds = live ? manifest.operationTimeoutSeconds : 5
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
        if !live { runtime.setFixture(pluginID: plugin.id, html: html, baseURL: url, responsesJSON: responsesJSON, settingsJSON: settingsJSON) }
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
                    var catalog = try await runtime.catalog(plugin: plugin, script: script, at: url, refresh: live)
                    var visited = Set([url])
                    while !live, let next = catalog.continuationURL {
                        guard visited.insert(next).inserted else { throw Failure("Repeated continuation URL") }
                        catalog = catalog.merging(try await runtime.catalog(plugin: plugin, script: script, at: next))
                    }
                    if live { print("Live catalog: \(catalog.comics.count) comics, \(catalog.comics.filter { $0.coverURL != nil }.count) covers, \(catalog.comics.reduce(0) { $0 + $1.mirrors.count }) mirrors") }
                    output = ["name": catalog.name, "comics": catalog.comics.map { comic -> [String: Any] in
                        ["title": comic.title, "cover": comic.coverURL?.absoluteString as Any? ?? NSNull(),
                         "link": comic.pageURL?.absoluteString as Any? ?? NSNull(),
                         "canRead": comic.canRead, "opensCatalog": comic.opensCatalog,
                         "mirrors": comic.mirrors.map(\.absoluteString), "hasMirrors": comic.hasMirrors,
                         "size": comic.size as Any? ?? NSNull(), "format": comic.format as Any? ?? NSNull()]
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
