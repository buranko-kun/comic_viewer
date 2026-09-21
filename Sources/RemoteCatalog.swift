import Foundation

/// A configured remote source: a name and the URL of its catalog manifest. Persisted by
/// `CatalogSourceStore`; imported from the user's `.txt` or added in Settings.
struct CatalogSource: Identifiable, Hashable, Codable {
    var name: String
    var url: URL
    var id: String { url.absoluteString }
}

/// A normalized comic from any source (JSON manifest today, OPDS via the fallback provider).
/// This is what the Online UI and the downloader speak — format details are already resolved.
struct RemoteComic: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String?
    let coverString: String?     // absolute cover URL as text; `URL` is built lazily (see below)
    let series: String?
    let mirrors: [URL]            // download links, tried in order (empty in the slim browse index)
    var hasMirrors: Bool = false // index flag: real mirrors exist, fetched on demand via MirrorStore
    let format: String?          // e.g. "cbz"; nil → inferred from a mirror's extension
    let metadata: [String: String]
    let sourceName: String
    var pageString: String? = nil // the source web page as text; `URL` built lazily on tap
    var mustRead: Bool = false   // curated "must read" essential
    var mustReadTitle: String? = nil  // canonical name of the essential work
    var size: String? = nil      // human-readable download size (e.g. "26 MB")

    /// Cover/page `URL`s are built on demand, not at parse time. With 72k+ comics, constructing a
    /// `URL` per cover and per page up front was a large share of the catalog's load cost and memory;
    /// deferring it means only the ~30 on-screen cells (and the tapped page) ever build one.
    var coverURL: URL? { coverString.flatMap { URL(string: $0) } }
    var pageURL: URL? { pageString.flatMap { URL(string: $0) } }

    /// The archive extension this comic downloads as: explicit `format`, else the first mirror
    /// that carries a reader-supported extension, else the first mirror's extension at all.
    var resolvedFormat: String? {
        if let f = format?.lowercased(), !f.isEmpty { return f }
        let exts = mirrors.map { $0.pathExtension.lowercased() }.filter { !$0.isEmpty }
        if let supported = exts.first(where: { ArchiveExtractor.extensions.contains($0) }) { return supported }
        return exts.first
    }
    /// True when the resolved format is one the reader can open.
    var isSupported: Bool { ArchiveExtractor.extensions.contains(resolvedFormat ?? "") }
    /// Metadata rows sorted for stable display.
    var metadataRows: [(key: String, value: String)] {
        metadata.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
    }
}

/// A normalized catalog level: the comics at this level plus child catalogs to drill into.
struct RemoteCatalog {
    let name: String
    let sourceURL: URL
    let comics: [RemoteComic]
    let childCatalogs: [ChildCatalog]

    struct ChildCatalog: Identifiable, Hashable {
        let name: String
        let url: URL
        var id: String { url.absoluteString }
    }
}
