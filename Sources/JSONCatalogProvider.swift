import Foundation

/// Decodes the app's JSON catalog schema into a normalized `RemoteCatalog`. Forgiving by
/// design so hand-authored manifests work: metadata values may be strings/numbers/bools,
/// child `catalogs` entries may be a bare URL string or a `{name,url}` object, and all
/// `cover`/`mirrors`/`catalogs` URLs may be relative to the manifest URL.
enum JSONCatalogProvider {
    static func parse(_ data: Data, sourceURL: URL) throws -> RemoteCatalog {
        let root = try JSONDecoder().decode(Manifest.self, from: data)
        let sourceName = nonEmpty(root.name) ?? sourceURL.host ?? "Catalog"
        let src = sourceURL.absoluteString + "#"

        // The compact index factors out the shared URL parts (`coverPre`/`coverSuf`/`linkPre`) and
        // stores only the varying middle, so full URLs are rebuilt by string concatenation — no `URL`
        // parsing at load. Without those bases (hand-authored catalogs) values are whole URLs, which
        // may be relative and are resolved against the manifest URL as before.
        let coverPre = root.coverPre, coverSuf = root.coverSuf ?? "", linkPre = root.linkPre
        func expand(_ v: String?, prefix: String?, suffix: String = "") -> String? {
            guard let v, !v.isEmpty else { return nil }
            if let prefix { return prefix + v + suffix }
            return URL(string: v, relativeTo: sourceURL)?.absoluteURL.absoluteString ?? v
        }

        // Derive a stable identity per comic. Manifests often omit `id` and can carry entries
        // with identical titles (e.g. two "52 Vol. 1 – 4" editions); those would collide into
        // one ID and leave a blank cell in the grid, so collisions are disambiguated by index.
        var seenIDs = Set<String>()
        let comics: [RemoteComic] = (root.comics ?? []).enumerated().map { index, c in
            let mirrorStrings = (c.mirrors ?? []) + [c.url, c.download].compactMap { $0 }
            let mirrors = mirrorStrings.compactMap { URL(string: $0, relativeTo: sourceURL)?.absoluteURL }
            let base = nonEmpty(c.id) ?? nonEmpty(c.title) ?? mirrors.first?.absoluteString ?? "comic"
            let localID = seenIDs.insert(base).inserted ? base : "\(base)#\(index)"
            return RemoteComic(
                id: src + localID,
                title: nonEmpty(c.title) ?? "Untitled",
                description: nonEmpty(c.description),
                coverString: expand(c.cover, prefix: coverPre, suffix: coverSuf),
                series: nonEmpty(c.series),
                mirrors: mirrors,
                hasMirrors: c.hasMirrors ?? !mirrors.isEmpty,
                format: nonEmpty(c.format),
                metadata: (c.metadata ?? [:]).mapValues(\.string),
                sourceName: sourceName,
                pageString: expand(c.link, prefix: linkPre),
                mustRead: c.mustRead ?? false,
                mustReadTitle: nonEmpty(c.mustReadTitle),
                size: nonEmpty(c.size))
        }

        let children: [RemoteCatalog.ChildCatalog] = (root.catalogs ?? []).compactMap { ref in
            guard let u = URL(string: ref.url, relativeTo: sourceURL)?.absoluteURL else { return nil }
            return .init(name: nonEmpty(ref.name) ?? folderName(for: u), url: u)
        }

        return RemoteCatalog(name: sourceName, sourceURL: sourceURL, comics: comics, childCatalogs: children)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// A readable folder name for a child manifest URL: the filename, or the parent directory
    /// when the file is an `index.*` (so `…/spider-man/index.json` reads as "spider-man").
    private static func folderName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if base.isEmpty || base.lowercased() == "index" {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return base
    }

    // MARK: - Wire types

    private struct Manifest: Decodable {
        let name: String?
        let comics: [Comic]?
        let catalogs: [ChildRef]?
        // Shared URL parts factored out of the compact index; prepended/appended to each comic's
        // `cover`/`link` to rebuild full URLs without per-comic `URL` parsing.
        let coverPre: String?
        let coverSuf: String?
        let linkPre: String?
    }

    /// A catalog comic. Decodes both the verbose schema (`title`, `cover`, `link`, …) and the
    /// compact index's short keys (`t`, `c`, `l`, `s`, `m`, `r`, `rt`) so both file styles load.
    private struct Comic: Decodable {
        let id: String?
        let title: String?
        let description: String?
        let cover: String?
        let series: String?
        let format: String?
        let mirrors: [String]?
        let hasMirrors: Bool?   // slim-index flag: real mirrors live in the mirrors lookup file
        let link: String?       // the comic's source web page
        let size: String?       // human-readable download size
        let mustRead: Bool?     // curated essential flag
        let mustReadTitle: String?
        let url: String?        // single-mirror aliases, folded into `mirrors`
        let download: String?
        let metadata: [String: Stringy]?

        enum CodingKeys: String, CodingKey {
            case id, title, description, cover, series, format, mirrors, hasMirrors
            case link, size, mustRead, mustReadTitle, url, download, metadata
            case t, c, l, s, m, r, rt   // compact aliases
        }

        init(from decoder: Decoder) throws {
            let k = try decoder.container(keyedBy: CodingKeys.self)
            func str(_ a: CodingKeys, _ b: CodingKeys) throws -> String? {
                try k.decodeIfPresent(String.self, forKey: a) ?? k.decodeIfPresent(String.self, forKey: b)
            }
            id = try k.decodeIfPresent(String.self, forKey: .id)
            title = try str(.title, .t)
            cover = try str(.cover, .c)
            link = try str(.link, .l)
            size = try str(.size, .s)
            mustReadTitle = try str(.mustReadTitle, .rt)
            description = try k.decodeIfPresent(String.self, forKey: .description)
            series = try k.decodeIfPresent(String.self, forKey: .series)
            format = try k.decodeIfPresent(String.self, forKey: .format)
            mirrors = try k.decodeIfPresent([String].self, forKey: .mirrors)
            url = try k.decodeIfPresent(String.self, forKey: .url)
            download = try k.decodeIfPresent(String.self, forKey: .download)
            metadata = try k.decodeIfPresent([String: Stringy].self, forKey: .metadata)
            // Bool flags accept a real bool or the compact `1`. `try?` per attempt so a type
            // mismatch (e.g. a JSON number where a Bool was tried) falls through instead of throwing.
            func flag(_ a: CodingKeys, _ b: CodingKeys) -> Bool? {
                for key in [a, b] {
                    if let v = try? k.decodeIfPresent(Bool.self, forKey: key) { return v }
                    if let v = try? k.decodeIfPresent(Int.self, forKey: key) { return v != 0 }
                }
                return nil
            }
            hasMirrors = flag(.hasMirrors, .m)
            mustRead = flag(.mustRead, .r)
        }
    }

    /// A child catalog reference: a bare URL string or a `{name, url}` object.
    private struct ChildRef: Decodable {
        let name: String?
        let url: String
        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                url = s; name = nil
            } else {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                url = try c.decode(String.self, forKey: .url)
                name = try c.decodeIfPresent(String.self, forKey: .name)
            }
        }
        enum CodingKeys: String, CodingKey { case name, url }
    }

    /// A metadata value that may arrive as a string, number, or bool — always read as a string.
    private struct Stringy: Decodable {
        let string: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { string = s }
            else if let i = try? c.decode(Int.self) { string = String(i) }
            else if let d = try? c.decode(Double.self) { string = String(d) }
            else if let b = try? c.decode(Bool.self) { string = String(b) }
            else { string = "" }
        }
    }
}
