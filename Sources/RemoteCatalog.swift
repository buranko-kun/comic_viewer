import Foundation

struct CatalogSource: Identifiable, Hashable, Codable {
    var name: String
    var url: URL
    var id: String { url.absoluteString }
}

struct RemoteComic: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String?
    let coverString: String?
    let series: String?
    let mirrors: [URL]
    var hasMirrors: Bool = false
    let format: String?
    let metadata: [String: String]
    let sourceName: String
    var sourceID: String? = nil
    var pageString: String? = nil
    var mustRead: Bool = false
    var mustReadTitle: String? = nil
    var size: String? = nil

    var coverURL: URL? { coverString.flatMap { URL(string: $0) } }
    var pageURL: URL? { pageString.flatMap { URL(string: $0) } }

    var resolvedFormat: String? {
        if let f = format?.lowercased(), !f.isEmpty { return f }
        let exts = mirrors.map { $0.pathExtension.lowercased() }.filter { !$0.isEmpty }
        if let supported = exts.first(where: { ArchiveExtractor.extensions.contains($0) }) { return supported }
        return exts.first
    }

    var isSupported: Bool {
        ArchiveExtractor.extensions.contains(resolvedFormat ?? "")
    }

    var metadataRows: [(key: String, value: String)] {
        metadata.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
    }
}

struct RemoteCatalog {
    let name: String
    let sourceURL: URL
    var sourceID: String? = nil
    let comics: [RemoteComic]
    let childCatalogs: [ChildCatalog]

    struct ChildCatalog: Identifiable, Hashable {
        let name: String
        let url: URL
        var sourceID: String? = nil
        var id: String { (sourceID ?? "catalog") + ":" + url.absoluteString }
    }
}
