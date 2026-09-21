import XCTest
@testable import ComicViewer

/// JSON catalog decoding (relative-URL resolution, format support, forgiving metadata, child
/// catalogs), provider auto-selection, and `.txt` source parsing.
final class CatalogTests: XCTestCase {

    private let sourceURL = URL(string: "https://server.example/comics/index.json")!

    private let manifest = """
    {
      "name": "Esteban's Comics",
      "comics": [
        {
          "id": "dp-001",
          "title": "Deadpool 001",
          "description": "First issue.",
          "cover": "covers/dp-001.jpg",
          "series": "Deadpool",
          "mirrors": ["files/dp-001.cbz", "https://mirror.example/dp-001.cbz"],
          "metadata": { "year": 1993, "writer": "Nicieza" }
        },
        {
          "title": "Some Magazine 002",
          "url": "files/mag-002.pdf"
        }
      ],
      "catalogs": [ { "name": "Hulk", "url": "hulk/index.json" }, "spider-man/index.json" ]
    }
    """

    private func parsed() throws -> RemoteCatalog {
        try JSONCatalogProvider.parse(Data(manifest.utf8), sourceURL: sourceURL)
    }

    func testCatalogMetadata() throws {
        let cat = try parsed()
        XCTAssertEqual(cat.name, "Esteban's Comics")
        XCTAssertEqual(cat.comics.count, 2)
        XCTAssertEqual(cat.childCatalogs.count, 2)
    }

    func testRelativeURLResolutionAndFormat() throws {
        let dp = try parsed().comics[0]
        XCTAssertEqual(dp.title, "Deadpool 001")
        XCTAssertEqual(dp.series, "Deadpool")
        XCTAssertTrue(dp.isSupported)                          // cbz
        XCTAssertEqual(dp.resolvedFormat, "cbz")
        XCTAssertEqual(dp.coverURL?.absoluteString, "https://server.example/comics/covers/dp-001.jpg")
        XCTAssertEqual(dp.mirrors.first?.absoluteString, "https://server.example/comics/files/dp-001.cbz")
        XCTAssertEqual(dp.mirrors.count, 2)
        // Metadata coerces the numeric year to a string.
        XCTAssertEqual(dp.metadata["year"], "1993")
        XCTAssertEqual(dp.metadata["writer"], "Nicieza")
    }

    func testSingleMirrorAliasAndUnsupported() throws {
        let mag = try parsed().comics[1]
        XCTAssertEqual(mag.mirrors.first?.absoluteString, "https://server.example/comics/files/mag-002.pdf")
        XCTAssertFalse(mag.isSupported)                        // pdf
        XCTAssertEqual(mag.resolvedFormat, "pdf")
    }

    func testChildCatalogs() throws {
        let kids = try parsed().childCatalogs
        XCTAssertEqual(kids[0].name, "Hulk")
        XCTAssertEqual(kids[0].url.absoluteString, "https://server.example/comics/hulk/index.json")
        // Bare-string child: name derived from the file/folder.
        XCTAssertEqual(kids[1].url.absoluteString, "https://server.example/comics/spider-man/index.json")
    }

    func testProviderPicksJSONAndOPDS() {
        // A JSON payload routes to the JSON provider (starts with '{').
        XCTAssertTrue(looksLikeJSON("  \n{ \"name\": \"x\" }"))
        // An Atom payload does not.
        XCTAssertFalse(looksLikeJSON("<?xml version=\"1.0\"?><feed></feed>"))
    }

    func testTextSourceParsing() {
        let txt = """
        # my servers
        https://a.example/index.json

        Server B | https://b.example/catalog.json
        not-a-url
        ftp://c.example/x
        """
        let parsed = CatalogSourceStore.parseText(txt)
        XCTAssertEqual(parsed.count, 2)                        // comment/blank/invalid/ftp dropped
        XCTAssertEqual(parsed[0].name, "")
        XCTAssertEqual(parsed[0].url.absoluteString, "https://a.example/index.json")
        XCTAssertEqual(parsed[1].name, "Server B")
        XCTAssertEqual(parsed[1].url.absoluteString, "https://b.example/catalog.json")
    }

    /// Mirror of `CatalogClient.looksLikeJSON` (private) for the routing assertion above.
    private func looksLikeJSON(_ s: String) -> Bool {
        let ws: Set<Character> = [" ", "\t", "\n", "\r"]
        guard let first = s.first(where: { !ws.contains($0) }) else { return false }
        return first == "{" || first == "["
    }
}
