import XCTest
import Swifter
@testable import ComicViewer

final class PluginResourceTests: XCTestCase {
    func testLegacyAndContextDecodeRoundTrip() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(PluginResourceRequest.self, from: Data("\"https://cdn.example/page.jpg\"".utf8))
        XCTAssertFalse(legacy.useBrowserCookies)
        let context = PluginResourceRequest(url: legacy.url, referrer: URL(string: "https://example/chapter")!, useBrowserCookies: true, pluginID: "sample")
        XCTAssertEqual(try decoder.decode(PluginResourceRequest.self, from: JSONEncoder().encode(context)), context)
        let minimal = try decoder.decode(PluginResourceRequest.self, from: Data("{\"url\":\"https://cdn.example/page.jpg\"}".utf8))
        XCTAssertEqual(minimal, legacy)
    }

    func testCacheIdentityIncludesSizeContextAndSession() {
        let url = URL(string: "https://cdn.example/page.jpg")!
        let publicRequest = PluginResourceRequest(url: url)
        var privateRequest = PluginResourceRequest(url: url, referrer: URL(string: "https://example/chapter"), useBrowserCookies: true, pluginID: "sample")
        XCTAssertNotEqual(publicRequest.cacheKey(maxPixel: 320), publicRequest.cacheKey(maxPixel: 640))
        XCTAssertNotEqual(publicRequest.cacheKey(maxPixel: 320), privateRequest.cacheKey(maxPixel: 320))
        let before = privateRequest.cacheKey(maxPixel: 320)
        XCTAssertEqual(before, privateRequest.cacheKey(maxPixel: 320))
        PluginResourceRegistry.shared.invalidateSession()
        XCTAssertNotEqual(before, privateRequest.cacheKey(maxPixel: 320))
        let publicBefore = publicRequest.cacheKey(maxPixel: 320)
        PluginResourceRegistry.shared.invalidateSession()
        XCTAssertEqual(publicBefore, publicRequest.cacheKey(maxPixel: 320))
        let firstPlugin = privateRequest.cacheKey(maxPixel: 320)
        privateRequest.pluginID = "other"
        XCTAssertNotEqual(firstPlugin, privateRequest.cacheKey(maxPixel: 320))
    }

    func testCookiesMatchDestinationDomainPathSecureAndExpiry() {
        let cookie = HTTPCookie(properties: [.name: "session", .value: "secret", .domain: ".example.com", .path: "/comic", .secure: "TRUE"])!
        XCTAssertTrue(PluginResourceTransport.cookieMatches(cookie, url: URL(string: "https://cdn.example.com/comic/1")!))
        XCTAssertFalse(PluginResourceTransport.cookieMatches(cookie, url: URL(string: "https://notexample.com/comic/1")!))
        XCTAssertFalse(PluginResourceTransport.cookieMatches(cookie, url: URL(string: "http://example.com/comic/1")!))
        XCTAssertFalse(PluginResourceTransport.cookieMatches(cookie, url: URL(string: "https://example.com/comics")!))
        let expired = HTTPCookie(properties: [.name: "old", .value: "secret", .domain: "example.com", .path: "/", .expires: Date(timeIntervalSince1970: 1)])!
        XCTAssertFalse(PluginResourceTransport.cookieMatches(expired, url: URL(string: "https://example.com/")!))
    }

    func testRequestRebuildNeverForwardsOriginCookieToUnrelatedHost() {
        let cookie = HTTPCookie(properties: [.name: "session", .value: "secret", .domain: "example.com", .path: "/"])!
        let resource = PluginResourceRequest(url: URL(string: "https://example.com/image")!, referrer: URL(string: "https://example.com/chapter?token=private#fragment"), useBrowserCookies: true)
        let transport = PluginResourceTransport(resource: resource, cookies: [cookie])
        XCTAssertNotNil(transport.request(for: resource.url).value(forHTTPHeaderField: "Cookie"))
        let redirect = transport.request(for: URL(string: "https://unrelated.com/image")!)
        XCTAssertNil(redirect.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(redirect.value(forHTTPHeaderField: "Referer"), "https://example.com/")
        XCTAssertNil(transport.request(for: URL(string: "http://example.com/image")!).value(forHTTPHeaderField: "Referer"))
    }

    func testHistoryDecodesOldRowsWithoutResourceContext() throws {
        let data = Data("[{\"key\":\"https://example/comic\",\"series\":\"A\",\"title\":\"B\",\"pages\":[\"https://example/page.jpg\"]}]".utf8)
        let issues = try JSONDecoder().decode([RemoteReadingHistory.ReadIssue].self, from: data)
        XCTAssertNil(issues[0].pageResources)
        XCTAssertEqual(issues[0].pages.count, 1)
    }
    func testRealHTTPImageAuthenticationRedirectAndDecode() async throws {
        let server = HttpServer()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=")!
        server["/image"] = { request in
            guard request.headers["cookie"]?.contains("fixture=allowed") == true,
                  request.headers["referer"]?.contains("/chapter") == true else { return .raw(403, "Forbidden", [:], nil) }
            return .raw(200, "OK", ["Content-Type": "image/png"], { try $0.write(png) })
        }
        server["/redirect"] = { _ in .movedTemporarily("/image") }
        server["/broken"] = { _ in .raw(200, "OK", ["Content-Type": "image/png"], { try $0.write(Data("broken".utf8)) }) }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let base = "http://127.0.0.1:\(try server.port())"
        let cookie = HTTPCookie(properties: [.name: "fixture", .value: "allowed", .domain: "127.0.0.1", .path: "/"])!
        let request = PluginResourceRequest(url: URL(string: base + "/redirect")!,
            referrer: URL(string: base + "/chapter"), useBrowserCookies: true, pluginID: "fixture")
        let data = try await PluginResourceTransport.data(for: request, cookies: [cookie])
        XCTAssertEqual(data, png)
        do {
            _ = try await PluginResourceTransport.data(for: request, cookies: [])
            XCTFail("Unauthenticated image should fail")
        } catch PluginResourceError.http(let status) { XCTAssertEqual(status, 403) }
        do {
            _ = try await PluginResourceTransport.data(for: PluginResourceRequest(url: URL(string: base + "/broken")!))
            XCTFail("Invalid image should fail")
        } catch PluginResourceError.decode {}
    }

    func testBoundURLsPreserveTwoContextsForSameImage() {
        let url = URL(string: "https://cdn.example/cover.jpg")!
        let a = PluginResourceRequest(url: url, referrer: URL(string: "https://a.example/"), pluginID: "a")
        let b = PluginResourceRequest(url: url, referrer: URL(string: "https://b.example/"), pluginID: "b")
        let aURL = PluginResourceRegistry.shared.boundURL(for: a)
        let bURL = PluginResourceRegistry.shared.boundURL(for: b)
        XCTAssertNotEqual(aURL, bURL)
        XCTAssertEqual(PluginResourceRegistry.shared.request(for: aURL), a)
        XCTAssertEqual(PluginResourceRegistry.shared.request(for: bURL), b)
    }

}
