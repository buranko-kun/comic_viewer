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

@MainActor
final class DownloadRecoveryTests: XCTestCase {
    func testSignatureRejectsHTMLRegardlessOfSizeAndPreservesRealFormat() throws {
        XCTAssertEqual(try DownloadValidationError.archiveExtension(Data([0x50,0x4b,0x03,0x04] + Array(repeating: 0, count: 18))), "cbz")
        XCTAssertEqual(try DownloadValidationError.archiveExtension(Data([0x52,0x61,0x72,0x21,0x1a,0x07] + Array(repeating: 0, count: 8))), "cbr")
        XCTAssertEqual(try DownloadValidationError.archiveExtension(Data("%PDF-1.4".utf8)), "pdf")
        XCTAssertThrowsError(try DownloadValidationError.archiveExtension(Data(("<!doctype html>" + String(repeating: "x", count: 1_100_000)).utf8))) { error in
            XCTAssertTrue((error as? DownloadValidationError)?.needsBrowser == true)
        }
        XCTAssertThrowsError(try DownloadValidationError.archiveExtension(Data("not an archive".utf8)))
    }

    func testHTTPDownloadsRejectWebpageAndSaveSmallFileUsingDetectedExtension() async throws {
        let server = HttpServer()
        let pdf = Data("%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\n%%EOF".utf8)
        server["/book"] = { _ in .raw(200, "OK", ["Content-Type":"application/octet-stream"], { try $0.write(pdf) }) }
        server["/gate"] = { _ in .raw(200, "OK", ["Content-Type":"text/html"], { try $0.write(Data("<html>Log in</html>".utf8)) }) }
        server["/denied"] = { _ in .raw(403, "Forbidden", [:], nil) }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let base = "http://127.0.0.1:\(try server.port())"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = try await DownloadManager.perform(from: URL(string: base + "/book")!, title: "Small", destinationFolder: folder, referrer: nil, onProgress: { _ in })
        XCTAssertEqual(saved.pathExtension, "pdf")
        XCTAssertEqual(try Data(contentsOf: saved), pdf)
        for path in ["/gate", "/denied"] {
            do {
                _ = try await DownloadManager.perform(from: URL(string: base + path)!, title: "Bad", destinationFolder: folder, referrer: nil, onProgress: { _ in })
                XCTFail("Gate must not be saved")
            } catch let error as DownloadValidationError { XCTAssertTrue(error.needsBrowser) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
    }
}
