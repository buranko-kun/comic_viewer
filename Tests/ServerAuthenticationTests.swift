import XCTest

@testable import ComicViewer

@MainActor
final class ServerAuthenticationTests: XCTestCase {
    func testPairingCodeIssuesUniqueSessionToken() {
        let server = ComicServer()
        let wrong = server.issueSessionToken(for: "000000")
        XCTAssertNil(wrong)

        let first = server.issueSessionToken(for: server.pairingCode)
        let second = server.issueSessionToken(for: server.pairingCode)

        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second)
    }

    func testRegeneratePairingCodeInvalidatesPreviousTokens() {
        let server = ComicServer()
        let oldCode = server.pairingCode
        let token = server.issueSessionToken(for: oldCode)
        defer { UserDefaults.standard.set(oldCode, forKey: "ComicServer.code") }

        XCTAssertNotNil(token)
        server.regeneratePairingCode()

        XCTAssertNotEqual(server.pairingCode, oldCode)
        XCTAssertNil(server.issueSessionToken(for: oldCode))
    }

    func testBasicAuthPasswordParsingRemainsSupported() {
        let credentials = Data("ComicViewer:123456".utf8).base64EncodedString()
        XCTAssertEqual(
            ComicServer.basicAuthPassword("Basic \(credentials)"),
            "123456"
        )
        XCTAssertNil(ComicServer.basicAuthPassword("Bearer 123456"))
    }
}
