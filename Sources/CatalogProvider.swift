import Foundation

/// Fetches a source URL and normalizes whatever it serves into a `RemoteCatalog`. JSON (the
/// app schema) is the primary format; anything else is tried as OPDS via the existing
/// `OPDSClient`, so both work with zero UI changes. New formats plug in here without touching
/// the Online UI or the downloader.
enum CatalogClient {
    enum CatalogError: LocalizedError {
        case badResponse(Int)
        case unrecognized
        var errorDescription: String? {
            switch self {
            case .badResponse(let c): return "Server returned HTTP \(c)."
            case .unrecognized:       return "That URL didn't return a JSON catalog or OPDS feed."
            }
        }
    }

    static func catalog(at url: URL) async throws -> RemoteCatalog {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CatalogError.badResponse(http.statusCode)
        }
        if looksLikeJSON(data) {
            return try JSONCatalogProvider.parse(data, sourceURL: url)
        }
        // Fallback: OPDS (Atom XML). Reuses the tested OPDS parser.
        let feed = OPDSClient.parse(data, feedURL: url)
        guard !feed.entries.isEmpty || feed.title != nil else { throw CatalogError.unrecognized }
        return adapt(feed)
    }

    /// True when the payload is a JSON object/array (first non-whitespace byte is `{` or `[`).
    private static func looksLikeJSON(_ data: Data) -> Bool {
        let ws: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]     // space, tab, LF, CR
        guard let first = data.first(where: { !ws.contains($0) }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    /// Adapt an OPDS feed into the normalized catalog model.
    private static func adapt(_ feed: OPDSFeed) -> RemoteCatalog {
        let name = feed.title ?? feed.feedURL.host ?? "Catalog"
        let comics: [RemoteComic] = feed.entries.filter { !$0.isNavigation }.map { e in
            // All acquisition links are mirrors, supported formats first.
            let acqs = e.links.filter(\.isAcquisition)
                .sorted { (ArchiveExtractor.extensions.contains($0.fileExtension ?? "") ? 0 : 1)
                          < (ArchiveExtractor.extensions.contains($1.fileExtension ?? "") ? 0 : 1) }
            return RemoteComic(
                id: feed.feedURL.absoluteString + "#" + e.id,
                title: e.title, description: e.summary, coverString: e.image?.href.absoluteString, series: nil,
                mirrors: acqs.map(\.href), hasMirrors: !acqs.isEmpty, format: e.acquisition?.fileExtension,
                metadata: [:], sourceName: name)
        }
        let children: [RemoteCatalog.ChildCatalog] = feed.entries.filter(\.isNavigation).map {
            .init(name: $0.title, url: $0.navigation!.href)
        }
        return RemoteCatalog(name: name, sourceURL: feed.feedURL, comics: comics, childCatalogs: children)
    }
}
