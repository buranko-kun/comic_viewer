import XCTest
@testable import ComicViewer

/// Parser correctness for OPDS 1.2 (Atom): entry classification (navigation vs acquisition),
/// format filtering, cover selection, relative-link resolution, search detection, and the
/// OpenSearch template fill.
final class OPDSTests: XCTestCase {

    private let feedURL = URL(string: "https://example.org/opds/catalog.atom")!

    private let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Test Catalog</title>
      <link rel="self" href="/opds/catalog.atom" type="application/atom+xml;profile=opds-catalog"/>
      <link rel="search" type="application/opensearchdescription+xml" href="/opds/search.xml"/>
      <link rel="next" href="/opds/catalog.atom?page=2" type="application/atom+xml"/>
      <entry>
        <id>urn:sub:1</id>
        <title>By Series</title>
        <link rel="subsection" href="/opds/series.atom" type="application/atom+xml;profile=opds-catalog"/>
      </entry>
      <entry>
        <id>urn:book:1</id>
        <title>Amazing Comic 001 (2020) (digital)</title>
        <summary>An issue.</summary>
        <link rel="http://opds-spec.org/image/thumbnail" href="/covers/1-thumb.jpg" type="image/jpeg"/>
        <link rel="http://opds-spec.org/image" href="/covers/1.jpg" type="image/jpeg"/>
        <link rel="http://opds-spec.org/acquisition" href="/dl/1.cbz" type="application/x-cbz"/>
      </entry>
      <entry>
        <id>urn:book:2</id>
        <title>Old Novel</title>
        <link rel="http://opds-spec.org/acquisition/open-access" href="/dl/2.pdf" type="application/pdf"/>
      </entry>
    </feed>
    """

    private func parsed() -> OPDSFeed {
        OPDSClient.parse(Data(sample.utf8), feedURL: feedURL)
    }

    func testFeedMetadata() {
        let feed = parsed()
        XCTAssertEqual(feed.title, "Test Catalog")
        XCTAssertEqual(feed.entries.count, 3)
        XCTAssertNotNil(feed.searchLink)
        XCTAssertNotNil(feed.nextLink)
        // Relative feed link resolved against the feed URL.
        XCTAssertEqual(feed.nextLink?.href.absoluteString, "https://example.org/opds/catalog.atom?page=2")
    }

    func testNavigationEntry() {
        let nav = parsed().entries[0]
        XCTAssertTrue(nav.isNavigation)
        XCTAssertNil(nav.acquisition)
        XCTAssertEqual(nav.navigation?.href.absoluteString, "https://example.org/opds/series.atom")
    }

    func testSupportedAcquisitionAndCover() {
        let book = parsed().entries[1]
        XCTAssertFalse(book.isNavigation)
        XCTAssertTrue(book.isSupported)
        XCTAssertEqual(book.acquisition?.fileExtension, "cbz")
        XCTAssertEqual(book.acquisition?.href.absoluteString, "https://example.org/dl/1.cbz")
        // Full image preferred over the thumbnail.
        XCTAssertEqual(book.image?.href.absoluteString, "https://example.org/covers/1.jpg")
        XCTAssertFalse(book.image?.isThumbnail ?? true)
    }

    func testUnsupportedFormat() {
        let pdf = parsed().entries[2]
        XCTAssertNotNil(pdf.acquisition)              // it has an acquisition…
        XCTAssertFalse(pdf.isSupported)               // …but PDF isn't readable here.
        XCTAssertEqual(pdf.acquisition?.fileExtension, "pdf")
    }

    func testOpenSearchTemplateFill() {
        let url = OPDSClient.queryURL(
            template: "https://example.org/search?q={searchTerms}&page={startPage?}",
            query: "batman year one")
        XCTAssertEqual(url?.absoluteString, "https://example.org/search?q=batman%20year%20one&page=")
    }
}
