import Foundation

/// Fetches and parses OPDS 1.2 (Atom XML) catalog feeds using Foundation's `XMLParser`
/// (no third-party dependencies). Relative links are resolved against the feed URL, and
/// `rel="search"` (OpenSearch) templates are resolved into a concrete query URL.
enum OPDSClient {
    enum OPDSError: LocalizedError {
        case badResponse(Int)
        case notXML
        var errorDescription: String? {
            switch self {
            case .badResponse(let c): return "Server returned HTTP \(c)."
            case .notXML:             return "That URL didn't return an OPDS (Atom XML) feed."
            }
        }
    }

    /// Load and parse the feed at `url`.
    static func feed(at url: URL) async throws -> OPDSFeed {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OPDSError.badResponse(http.statusCode)
        }
        return parse(data, feedURL: url)
    }

    /// Non-networked parse of feed XML — the testable core of `feed(at:)`.
    static func parse(_ data: Data, feedURL: URL) -> OPDSFeed {
        let parser = FeedParser(feedURL: feedURL)
        _ = parser.parse(data)
        return parser.feed()
    }

    /// Substitute `{searchTerms}` (and drop other OpenSearch `{…}` params) in a URL template.
    static func queryURL(template: String, query: String) -> URL? { fill(template: template, query: query) }

    /// Resolve a feed's search facility into a concrete query URL, or nil if it has none.
    /// Handles both a direct templated `rel="search"` link and an OpenSearch description doc.
    static func searchURL(for feed: OPDSFeed, query: String) async -> URL? {
        guard let link = feed.searchLink else { return nil }
        // Case 1: the link href is itself a template containing {searchTerms}.
        if link.href.absoluteString.contains("{searchTerms}") {
            return fill(template: link.href.absoluteString, query: query)
        }
        // Case 2: the link points to an OpenSearch description document — fetch it and pull the
        // <Url template="…{searchTerms}…"> out.
        if (link.type?.contains("opensearchdescription") ?? false) {
            if let (data, _) = try? await URLSession.shared.data(from: link.href),
               let template = OpenSearchParser.template(from: data, baseURL: link.href) {
                return fill(template: template, query: query)
            }
        }
        // Fallback: some feeds expose a plain search link; append the query as `?q=`.
        return URL(string: link.href.absoluteString + (link.href.query == nil ? "?" : "&")
                   + "q=" + encoded(query))
    }

    private static func fill(template: String, query: String) -> URL? {
        var s = template
        // Replace {searchTerms} and drop any other optional {…} OpenSearch params.
        s = s.replacingOccurrences(of: "{searchTerms}", with: encoded(query))
        s = s.replacingOccurrences(of: #"\{[^}]*\??\}"#, with: "", options: .regularExpression)
        return URL(string: s)
    }

    private static func encoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}

// MARK: - Atom / OPDS feed parser

private final class FeedParser: NSObject, XMLParserDelegate {
    private let feedURL: URL
    private var feedTitle: String?
    private var feedLinks: [OPDSLink] = []
    private var entries: [OPDSEntry] = []

    // Per-entry accumulation.
    private var inEntry = false
    private var entryTitle = "", entryId = "", entrySummary = ""
    private var entryLinks: [OPDSLink] = []
    private var text = ""       // current leaf text buffer

    init(feedURL: URL) { self.feedURL = feedURL }

    func parse(_ data: Data) -> Bool {
        let p = XMLParser(data: data)
        p.delegate = self
        return p.parse()
    }

    func feed() -> OPDSFeed {
        OPDSFeed(title: feedTitle, feedURL: feedURL, links: feedLinks, entries: entries)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        text = ""
        switch name {
        case "entry":
            inEntry = true
            entryTitle = ""; entryId = ""; entrySummary = ""; entryLinks = []
        case "link":
            if let link = makeLink(attrs) {
                if inEntry { entryLinks.append(link) } else { feedLinks.append(link) }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title":   if inEntry { entryTitle = value } else if feedTitle == nil { feedTitle = value }
        case "id":      if inEntry { entryId = value }
        case "summary", "content": if inEntry, !value.isEmpty { entrySummary = value }
        case "entry":
            let id = entryId.isEmpty ? (entryLinks.first?.href.absoluteString ?? UUID().uuidString) : entryId
            entries.append(OPDSEntry(id: id, title: entryTitle,
                                     summary: entrySummary.isEmpty ? nil : entrySummary,
                                     links: entryLinks))
            inEntry = false
        default:
            break
        }
        text = ""
    }

    /// Build a link from `<link>` attributes, resolving a relative href against the feed URL.
    private func makeLink(_ attrs: [String: String]) -> OPDSLink? {
        guard let hrefStr = attrs["href"],
              let href = URL(string: hrefStr, relativeTo: feedURL)?.absoluteURL else { return nil }
        return OPDSLink(href: href, rel: attrs["rel"], type: attrs["type"], title: attrs["title"])
    }
}

// MARK: - OpenSearch description parser (just the Url template)

private final class OpenSearchParser: NSObject, XMLParserDelegate {
    private var template: String?
    private let baseURL: URL
    init(baseURL: URL) { self.baseURL = baseURL }

    static func template(from data: Data, baseURL: URL) -> String? {
        let d = OpenSearchParser(baseURL: baseURL)
        let p = XMLParser(data: data); p.delegate = d; p.parse()
        return d.template
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        guard name == "Url", let t = attrs["template"] else { return }
        // Prefer an OPDS/Atom-typed Url; otherwise take the first template we see.
        let type = attrs["type"] ?? ""
        if template == nil || type.contains("atom") {
            template = URL(string: t, relativeTo: baseURL)?.absoluteString ?? t
        }
    }
}
