import XCTest
import Swifter
@testable import ComicViewer

@MainActor
final class SourcePluginRuntimeTests: XCTestCase {
    func testContinuationPublishesFirstBatchAndRetainsItIfLaterFetchFails() async throws {
        for fails in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let aggregator = CatalogAggregator(cacheDirectory: directory)
            let next = URL(string: "https://fixture.invalid/catalog?page=2")!
            let first = try SourcePluginContract.catalog("""
                {"comics":[{"id":"one","title":"First"}],"continuationURL":"?page=2"}
                """, plugin: plugin(), baseURL: url).catalog
            XCTAssertEqual(first.continuationURL, next)
            XCTAssertTrue(first.childCatalogs.isEmpty)
            let second = try SourcePluginContract.catalog("""
                {"comics":[{"id":"one","title":"First"},{"id":"two","title":"Second"}]}
                """, plugin: plugin(), baseURL: next).catalog
            await aggregator.start(key: "fixture", name: "Fixture", cacheKey: "fixture", continuation: { target in
                XCTAssertEqual(target, next)
                XCTAssertEqual(aggregator.catalog(forSourceKey: "fixture")?.comics.count, 1)
                XCTAssertTrue(aggregator.isLoadingSource("fixture"))
                if fails { throw SourcePluginFixtureRunner.Failure("Later page unavailable") }
                return second
            }) { first }.value
            let visible = try XCTUnwrap(aggregator.catalog(forSourceKey: "fixture"))
            XCTAssertEqual(visible.comics.count, fails ? 1 : 2)
            XCTAssertEqual(visible.sourceURL, url)
            XCTAssertFalse(aggregator.isLoadingSource("fixture"))
            XCTAssertEqual(aggregator.sourceFailures.count, fails ? 1 : 0)
            let snapshot = await CatalogSnapshotCache(directory: directory).load(key: "fixture")
            XCTAssertEqual(snapshot?.comics.count, visible.comics.count)
        }
    }

    func testContinuationRejectsUnsafeURLsAndStopsRepeatedURLs() async throws {
        XCTAssertThrowsError(try SourcePluginContract.catalog("""
            {"comics":[],"continuationURL":"file:///tmp/untrusted"}
            """, plugin: plugin(), baseURL: url))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aggregator = CatalogAggregator(cacheDirectory: directory)
        let first = RemoteCatalog(name: "Fixture", sourceURL: url, comics: [], childCatalogs: [], continuationURL: url)
        await aggregator.start(key: "fixture", name: "Fixture", cacheKey: "fixture", continuation: { _ in
            XCTFail("Repeated URL must not be fetched")
            return first
        }) { first }.value
        XCTAssertEqual(aggregator.sourceFailures.count, 1)
        XCTAssertFalse(aggregator.isLoadingSource("fixture"))
    }

    private let url = URL(string: "https://fixture.invalid/catalog")!
    private func plugin(_ id: String = "fixture") -> SourcePlugin {
        SourcePlugin(id: id, name: "Fixture", version: "1", homepage: "https://fixture.invalid/",
                     description: nil, tags: nil, capabilities: ["browser-session"], settings: nil,
                     sourceURL: url, fileName: "fixture.js", installedAt: Date(), enabled: true)
    }
    private func script(_ body: String) -> String {
        """
        globalThis.ComicViewerSource = {
          manifest: { id:'fixture',name:'Fixture',version:'1' },
          browseURL:'https://fixture.invalid/catalog',
          parseCatalog: async context => { \(body) }
        };
        """
    }
    private func fixture(_ runtime: SourcePluginRuntime, id: String = "fixture") {
        runtime.setFixture(pluginID: id, html: "<h1>Real DOM</h1>", baseURL: url, responsesJSON: "{}")
    }
    func testHTTPRejectionIsNotAnEmptyCatalog() async throws {
        let server = HttpServer()
        server["/blocked"] = { _ in .raw(403, "Forbidden", ["Content-Type": "text/html"], { try $0.write(Data("<h1>Forbidden</h1>".utf8)) }) }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(try server.port())/blocked")!
        let source = SourcePlugin(id: "blocked", name: "Blocked", version: "1", homepage: target.absoluteString,
            description: nil, tags: nil, capabilities: [], settings: nil, sourceURL: target,
            fileName: "fixture.js", installedAt: Date(), enabled: true)
        do {
            _ = try await SourcePluginRuntime().catalog(plugin: source, script: script("return {comics:[]};"), at: target)
            XCTFail("HTTP 403 must surface a recovery error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("HTTP 403"), error.localizedDescription) }
    }

    func testRealDOMAndContext() async throws {
        let runtime = SourcePluginRuntime(); fixture(runtime)
        let catalog = try await runtime.catalog(plugin: plugin(), script: script("return {comics:[{id:'1',title:document.querySelector('h1').textContent,link:context.url,cover:'cover.jpg'}]};"), at: url)
        XCTAssertEqual(catalog.comics.first?.title, "Real DOM")
        XCTAssertEqual(catalog.comics.first?.coverURL?.absoluteString, "https://fixture.invalid/cover.jpg")
        XCTAssertEqual(catalog.comics.first?.pageURL, url)
    }
    func testTimeoutReleasesWorkerAndNextOperationSucceeds() async throws {
        let runtime = SourcePluginRuntime(); fixture(runtime)
        var source = plugin(); source.operationTimeoutSeconds = 1
        do {
            _ = try await runtime.catalog(plugin: source, script: script("await new Promise(() => {});"), at: url)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        let catalog = try await runtime.catalog(plugin: plugin(), script: script("return {comics:[{title:'Recovered'}]};"), at: url)
        XCTAssertEqual(catalog.comics.first?.title, "Recovered")
    }
    func testCancellationReleasesWorker() async throws {
        let runtime = SourcePluginRuntime(); fixture(runtime)
        let task = Task { try await runtime.catalog(plugin: plugin(), script: script("await new Promise(() => {});"), at: url) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let result = try await runtime.catalog(plugin: plugin(), script: script("return {comics:[]};"), at: url)
        XCTAssertTrue(result.comics.isEmpty)
    }
    func testUndeclaredFixtureNetworkFails() async throws {
        let runtime = SourcePluginRuntime(); fixture(runtime)
        do {
            _ = try await runtime.catalog(plugin: plugin(), script: script("await fetch('https://unmapped.invalid/');return {};"), at: url)
            XCTFail("Unexpected network success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("JavaScript")) }
    }
    func testDifferentPluginCanFinishWhileOneIsHung() async throws {
        let runtime = SourcePluginRuntime(); fixture(runtime); fixture(runtime, id: "second")
        let hanging = Task { try await runtime.catalog(plugin: plugin(), script: script("await new Promise(() => {});"), at: url) }
        defer { hanging.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        let catalog = try await runtime.catalog(plugin: plugin("second"), script: script("return {comics:[{title:'Second'}]};"), at: url)
        XCTAssertEqual(catalog.comics.first?.title, "Second")
        hanging.cancel()
        _ = try? await hanging.value
    }
    func testBrowserNavigationCannotChangeWorkerDOM() async throws {
        let runtime = SourcePluginRuntime(); fixture(runtime)
        let browser = runtime.sessionWebView(for: plugin())
        browser.loadHTMLString("<h1>Browser UI</h1>", baseURL: url)
        let catalog = try await runtime.catalog(plugin: plugin(), script: script("return {comics:[{title:document.querySelector('h1').textContent}]};"), at: url)
        XCTAssertEqual(catalog.comics.first?.title, "Real DOM")
    }
    func testReportExportExcludesPayloadsAndQueryValues() {
        let report = SourcePluginRunReport(id: UUID(), pluginID: "fixture", pluginVersion: "1", scriptHash: nil,
            operation: "catalog", targetURL: "https://example.com/?custom=private", startedAt: Date(), duration: 1,
            status: "completed", rawJSON: "secretpayload", normalizedJSON: "secretpayload", warnings: [], console: ["password"])
        XCTAssertFalse(report.prettyJSON.contains("private"))
        XCTAssertFalse(report.prettyJSON.contains("secretpayload"))
        XCTAssertFalse(report.prettyJSON.contains("password"))
    }
    func testManifestRejectsUnsupportedVersionAndInvalidSettings() throws {
        XCTAssertThrowsError(try SourcePluginContract.manifest(Data("{\"id\":\"a\",\"name\":\"A\",\"version\":\"1\",\"apiVersion\":2}".utf8)))
        XCTAssertThrowsError(try SourcePluginContract.manifest(Data("""
        {"id":"a","name":"A","version":"1","settings":[{"id":"flag","title":"Flag","type":"bool","defaultValue":"bad"}]}
        """.utf8)))
    }
    func testNormalizationWarningsAndResources() throws {
        let result = try SourcePluginContract.catalog("""
        {"comics":[{"id":1,"title":42,"cover":{"url":"cover.jpg","referrer":"/series","useBrowserCookies":true}},
          {"id":1,"title":"Duplicate","link":"file:///private/file","canRead":true}]}
        """, plugin: plugin(), baseURL: url)
        XCTAssertEqual(result.catalog.comics[0].title, "42")
        XCTAssertEqual(result.catalog.comics[0].coverResource?.referrer?.absoluteString, "https://fixture.invalid/series")
        XCTAssertTrue(result.catalog.comics[0].coverResource?.useBrowserCookies == true)
        XCTAssertNotEqual(result.catalog.comics[0].id, result.catalog.comics[1].id)
        XCTAssertNil(result.catalog.comics[1].pageURL)
        XCTAssertTrue(result.warnings.contains { $0.contains("duplicate") })
        XCTAssertTrue(result.warnings.contains { $0.contains("comics[1].link") })
    }
    func testDisplayRevisionInvalidatesSameCount() {
        let cache = DisplayCache()
        func comic(_ title: String) -> RemoteComic {
            RemoteComic(id: "1", title: title, description: nil, coverString: nil, series: nil,
                        mirrors: [], format: nil, metadata: [:], sourceName: "Fixture")
        }
        XCTAssertEqual(cache.compute(base: [comic("Old")], sort: .title, token: "1").comics[0].title, "Old")
        XCTAssertEqual(cache.compute(base: [comic("New")], sort: .title, token: "2").comics[0].title, "New")
    }

    func testIssueCoverCachePersistsProtectedResourcesAndSeparatesIssues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = PluginResourceRequest(url: URL(string: "https://cdn.example.com/issue2/1.jpg")!,
            referrer: URL(string: "https://example.com/issue2")!, useBrowserCookies: true, pluginID: "fixture")
        let cache = PluginIssueCoverCache(directory: directory)
        cache.save(resource, key: "fixture:hash:issue2")
        XCTAssertEqual(cache.remembered(key: "fixture:hash:issue2"), resource)
        XCTAssertNil(cache.remembered(key: "fixture:hash:issue3"))
        let reopened = PluginIssueCoverCache(directory: directory)
        XCTAssertNil(reopened.remembered(key: "fixture:hash:issue2"))
        let restored = reopened.load(key: "fixture:hash:issue2")
        XCTAssertEqual(restored, resource)
        XCTAssertEqual(reopened.remembered(key: "fixture:hash:issue2"), resource)
        let otherIssue = reopened.load(key: "fixture:hash:issue3")
        let updatedPlugin = reopened.load(key: "fixture:newhash:issue2")
        XCTAssertNil(otherIssue)
        XCTAssertNil(updatedPlugin)
    }

    func testBrowserRecoveryRetriesOnceAndCancellationPreventsStaleRetry() {
        let recovery = SourceSessionRecovery()
        var retries = 0
        recovery.prepare { retries += 1 }
        XCTAssertEqual(retries, 0)
        recovery.browserClosed()
        recovery.browserClosed()
        XCTAssertEqual(retries, 1)
        recovery.prepare { retries += 1 }
        recovery.cancel()
        recovery.browserClosed()
        XCTAssertEqual(retries, 1)
    }

    func testHTTPErrorPresentationKeepsDetailsBelowConciseStatus() {
        let detail = "Source JavaScript failed: Error: ReadComicsOnline returned HTTP 403 for https://example.com/comic (line 0)"
        let presentation = SourceErrorPresentation(detail)
        XCTAssertEqual(presentation.title, "Error 403")
        XCTAssertEqual(presentation.detail, detail)
        XCTAssertEqual(SourceErrorPresentation("HTTP 429 rate limited").title, "Error 429")
        XCTAssertEqual(SourceErrorPresentation("Failed at https://example.com/403").title, "Couldn’t connect to source")
    }
}
