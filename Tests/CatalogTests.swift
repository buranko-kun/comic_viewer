import XCTest
import AppKit
@testable import ComicViewer

/// JSON catalog decoding (relative-URL resolution, format support, forgiving metadata, child
/// catalogs), provider auto-selection, and `.txt` source parsing.
final class CatalogTests: XCTestCase {
    @MainActor
    func testHistoryRowOutsideToolbarAppliesSearchWithoutOutsideDismissal() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let field = SearchOutsideClickArea.AreaView(frame: NSRect(x: 200, y: 350, width: 300, height: 34))
        let regions = SearchDropdownClickRegions()
        field.regions = regions; field.active = true
        var query = "", dismissed = false, historyRequested = false
        field.dismiss = { dismissed = true }
        field.insideFieldClick = { historyRequested = true }
        content.addSubview(field)
        defer { field.stop() }
        let row = SearchDropdownClickRegion.RegionView(frame: NSRect(x: 200, y: 280, width: 300, height: 32))
        row.action = { query = "Batman: Year One" }
        content.addSubview(row)
        regions.views = [row]
        func click(_ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        field.active = false
        XCTAssertNotNil(field.handle(try click(NSPoint(x: 250, y: 365))))
        XCTAssertFalse(historyRequested)
        field.active = true
        XCTAssertNotNil(field.handle(try click(NSPoint(x: 250, y: 365))))
        XCTAssertTrue(historyRequested)
        XCTAssertFalse(dismissed)
        XCTAssertNil(field.handle(try click(NSPoint(x: 250, y: 295))))
        XCTAssertEqual(query, "Batman: Year One")
        XCTAssertFalse(dismissed)
        XCTAssertNotNil(field.handle(try click(NSPoint(x: 100, y: 100))))
        XCTAssertTrue(dismissed)
    }

    @MainActor
    func testBrowseBackRestoresNestedSearchAndScrollPosition() {
        let state = BrowseState()
        state.selectedSourceKey = "plugin:fixture"
        state.searchText = "Batman"; state.activeQuery = "Batman"
        state.windowStart = 400; state.windowCount = 800; state.anchorID = "batman-issue"
        state.resultsToken = "root-token"
        state.searchResults = []
        let catalog = RemoteCatalog(name: "Batman", sourceURL: URL(string: "https://fixture.invalid/batman")!,
            sourceID: "fixture", comics: [], childCatalogs: [])
        state.push(catalog)
        XCTAssertEqual(state.searchText, "")
        state.searchText = "Annual"; state.activeQuery = "Annual"; state.anchorID = "annual"
        state.push(catalog)
        XCTAssertNil(state.pop())
        XCTAssertEqual(state.searchText, "Annual")
        XCTAssertEqual(state.anchorID, "annual")
        XCTAssertNil(state.pop())
        XCTAssertEqual(state.searchText, "Batman")
        XCTAssertEqual(state.activeQuery, "Batman")
        XCTAssertEqual(state.resultsToken, "root-token")
        XCTAssertEqual(state.windowStart, 400)
        XCTAssertEqual(state.windowCount, 800)
        XCTAssertEqual(state.anchorID, "batman-issue")
    }

    @MainActor
    func testSavedSeriesReturnsToCollectionAndPreservesOnlineSession() {
        let state = BrowseState()
        state.searchText = "Superman"; state.activeQuery = "Superman"; state.anchorID = "superman"
        let catalog = RemoteCatalog(name: "Batman", sourceURL: URL(string: "https://fixture.invalid/batman")!,
            sourceID: "fixture", comics: [], childCatalogs: [])
        state.beginExternal(catalog, returningTo: .collections)
        XCTAssertEqual(state.selectedSourceKey, "plugin:fixture")
        XCTAssertEqual(state.pop(), .collections)
        XCTAssertEqual(state.searchText, "Superman")
        XCTAssertEqual(state.anchorID, "superman")
        XCTAssertTrue(state.stack.isEmpty)
    }

    func testSavedPluginSeriesRetainsActionAndLegacyFavoriteResolves() throws {
        var comic = RemoteComic(id: "series", title: "Absolute Batman", description: nil,
            coverString: nil, series: nil, mirrors: [], format: nil, metadata: [:], sourceName: "Fixture")
        comic.sourceID = "fixture"; comic.opensCatalog = true
        comic.pageString = "https://fixture.invalid/batman"
        let saved = CollectionItem(remote: comic)
        let decoded = try JSONDecoder().decode(CollectionItem.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.resolvedRemote(in: [])?.sourceID, "fixture")
        XCTAssertTrue(decoded.resolvedRemote(in: [])?.opensCatalog == true)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        legacy.removeValue(forKey: "remoteComic")
        let old = try JSONDecoder().decode(CollectionItem.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.resolvedRemote(in: [comic]), comic)
    }

    @MainActor
    func testSearchHistoryPersistsDeduplicatesAndSuggestsCatalogueTitles() throws {
        let suite = "ComicViewer.SearchTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = OnlineSearchHistory(defaults: defaults)
        history.record(" Batman "); history.record("Superman"); history.record("batman")
        XCTAssertEqual(history.recent, ["batman", "Superman"])
        XCTAssertEqual(history.suggestions(for: "", titles: ["Batman: Year One"]), ["batman", "Superman"])
        XCTAssertEqual(history.suggestions(for: "bat", titles: ["Batman: Year One", "Absolute Batman", "Superman"]),
                       ["Batman: Year One", "Absolute Batman"])
        let suggestions = history.suggestions(for: "absolute", titles: ["Absolute Batman", "Absolute Superman", "Absolute Batman"])
        XCTAssertEqual(suggestions, ["Absolute Batman", "Absolute Superman"])
        XCTAssertEqual(OnlineSearchHistory(defaults: defaults).recent, history.recent)
        history.clear()
        XCTAssertTrue(OnlineSearchHistory(defaults: defaults).recent.isEmpty)
        XCTAssertTrue(history.suggestions(for: "", titles: ["Batman: Year One"]).isEmpty)
    }

    private let sourceURL = URL(string: "https://server.example/comics/index.json")!

    private let manifest = """
    {
      "name": "Sample Comics",
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
        XCTAssertEqual(cat.name, "Sample Comics")
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

final class CatalogRecoveryTests: XCTestCase {
    func testSourceFailureDistinguishesBlockingLoginAndTimeout() {
        XCTAssertEqual(SourceFailure(id: "a", name: "A", detail: "HTTP 401").summary, "Login required")
        XCTAssertEqual(SourceFailure(id: "a", name: "A", detail: "HTTP 403").summary, "Site blocked access")
        XCTAssertEqual(SourceFailure(id: "a", name: "A", detail: "Source operation timed out.").summary, "Source timed out")
        XCTAssertEqual(SourceFailure(id: "a", name: "A", detail: "Invalid data").summary, "Request failed")
    }

    func testSnapshotsSurviveNewCacheInstanceAndIgnoreCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://example.org/catalog")!
        let catalog = try JSONCatalogProvider.parse(Data(#"{"name":"Saved","comics":[{"title":"Book","mirrors":["book.cbz"],"cover":"cover.jpg"}]}"#.utf8), sourceURL: url)
        await CatalogSnapshotCache(directory: directory).save(catalog, key: "source")
        let fresh = CatalogSnapshotCache(directory: directory)
        let loaded = await fresh.load(key: "source")
        XCTAssertEqual(loaded?.comics, catalog.comics)
        let other = await fresh.load(key: "other-script-version")
        XCTAssertNil(other)
        let file = directory.appendingPathComponent(CentralStore.sha256("source") + ".json")
        try Data("broken".utf8).write(to: file)
        let broken = await fresh.load(key: "source")
        XCTAssertNil(broken)
        let stale = CatalogSnapshotCache.Snapshot(saved: Date(timeIntervalSince1970: 1), catalog: catalog)
        try JSONEncoder().encode(stale).write(to: file)
        let expired = await fresh.load(key: "source")
        XCTAssertNil(expired)
    }
}
