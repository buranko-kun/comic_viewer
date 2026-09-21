import Foundation

/// An OPDS catalog the user has registered (name + root feed URL). Persisted by
/// `OPDSCatalogStore`; presets seed a few public-domain sources.
struct OPDSCatalog: Identifiable, Hashable, Codable {
    var name: String
    var url: URL
    var id: String { url.absoluteString }
}

/// A single `<link>` in an OPDS feed/entry, classified by its `rel`/`type`.
struct OPDSLink: Hashable {
    let href: URL
    let rel: String?
    let type: String?          // MIME type, e.g. "application/x-cbz", "application/atom+xml;profile=opds-catalog"
    let title: String?

    /// A link that leads to another feed (a sub-catalog to drill into).
    var isNavigation: Bool {
        (type?.contains("application/atom+xml") ?? false) &&
        !(rel?.contains("opds-spec.org/acquisition") ?? false)
    }
    /// A link that downloads the actual publication file.
    var isAcquisition: Bool { rel?.contains("opds-spec.org/acquisition") ?? false }
    /// A cover / thumbnail image link.
    var isImage: Bool {
        (rel?.contains("opds-spec.org/image") ?? false)
            || rel == "http://opds-spec.org/cover"
            || (type?.hasPrefix("image/") ?? false)
    }
    var isThumbnail: Bool { rel?.contains("thumbnail") ?? false }

    /// File extension implied by the acquisition MIME type (for format filtering / naming).
    var fileExtension: String? {
        switch type {
        case let t? where t.contains("cbz") || t == "application/vnd.comicbook+zip": return "cbz"
        case let t? where t.contains("cbr") || t == "application/vnd.comicbook-rar":  return "cbr"
        case "application/zip":                                                       return "zip"
        case "application/pdf":                                                       return "pdf"
        case "application/epub+zip":                                                  return "epub"
        default:
            // Fall back to the URL's own extension.
            let ext = href.pathExtension.lowercased()
            return ext.isEmpty ? nil : ext
        }
    }
}

/// One `<entry>`: either a sub-catalog (navigation) or a downloadable publication.
struct OPDSEntry: Identifiable, Hashable {
    let id: String            // atom:id, or a synthesized fallback
    let title: String
    let summary: String?
    let links: [OPDSLink]

    /// The best acquisition link (a supported archive format preferred over others).
    var acquisition: OPDSLink? {
        let acqs = links.filter(\.isAcquisition)
        return acqs.first { ArchiveExtractor.extensions.contains($0.fileExtension ?? "") }
            ?? acqs.first
    }
    /// Where drilling into this entry leads, if it's a sub-catalog.
    var navigation: OPDSLink? { links.first(where: \.isNavigation) }
    /// Cover art (prefers a full image over a thumbnail).
    var image: OPDSLink? {
        links.first { $0.isImage && !$0.isThumbnail } ?? links.first(where: \.isImage)
    }

    /// True when this entry is a folder to browse rather than a book to download.
    var isNavigation: Bool { acquisition == nil && navigation != nil }
    /// True when the (best) acquisition is a format the reader can open.
    var isSupported: Bool { ArchiveExtractor.extensions.contains(acquisition?.fileExtension ?? "") }
}

/// A parsed OPDS feed: its own links (self/next/search) plus its entries.
struct OPDSFeed {
    let title: String?
    let feedURL: URL
    let links: [OPDSLink]
    let entries: [OPDSEntry]

    /// OpenSearch / `rel="search"` description or template link, if the feed advertises one.
    var searchLink: OPDSLink? {
        links.first { $0.rel == "search" }
    }
    /// `rel="next"` pagination link.
    var nextLink: OPDSLink? { links.first { $0.rel == "next" } }
}
