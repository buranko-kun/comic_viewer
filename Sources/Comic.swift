import Foundation

/// A reading position within a comic, for the library's progress badge.
/// `count == 0` means "unknown total" (e.g. an archive we haven't opened yet).
struct ComicProgress: Hashable {
    var page: Int      // 1-based current page
    var count: Int     // total pages, 0 if unknown
    var fraction: Double { count > 0 ? Double(page) / Double(count) : 0 }
}

/// One comic in the library: a leaf folder that directly contains images, or an archive file.
/// `series` is the top-level folder under its library root (used to group the grid).
struct Comic: Identifiable, Hashable {
    let url: URL           // leaf image folder, or the archive file
    let series: String
    let isArchive: Bool
    let coverURL: URL?     // first page image (folders); nil for archives until opened
    let pageCount: Int     // direct image count (folders); 0 for archives
    let progress: ComicProgress?
    let chapterCount: Int  // chapters that resolve to pages: manual + ComicInfo bookmarks (folders)
    let metaTitle: String? // title from ComicInfo.xml, if any
    let tooltip: String?   // series/credits/summary from ComicInfo.xml, for a hover tooltip
    /// For a "web comic": the page image URLs, streamed on demand. nil for on-disk comics.
    var remotePages: [URL]? = nil
    /// For a "web series" issue whose length is unknown: a per-page URL template containing `{page}`.
    /// The reader probes it (page 1, 2, …) until a page 404s to discover the count. `remotePagePad`
    /// is the page-number zero-padding.
    var remotePageTemplate: String? = nil
    var remotePagePad: Int = 0
    /// Expected page count for a series issue — the probe starts here and adjusts, so a series where
    /// most issues are ~24 pages resolves in a couple of requests instead of ~24.
    var remotePageHint: Int = 24

    var isRemote: Bool { remotePages != nil || remotePageTemplate != nil }

    var id: String { url.path }

    /// Folder/file name (cleaned of scanner/scene tags), unless ComicInfo.xml gives a title.
    var title: String {
        if let m = metaTitle, !m.isEmpty { return m }
        let raw = isArchive ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        return TitleCleaner.clean(raw)
    }
}

/// Parses a `.webcomic.json` descriptor into ordered page URLs. Supports:
///   • `pages`: an explicit list of URLs, and/or
///   • a generated sequence: `template` (a URL containing `{n}`) **or** `base` (+ optional `ext`),
///     with `from`/`to` (inclusive), optional `pad` (zero-padding width; defaults to the digit
///     count of `to`, so 1…24 → `01`…`24`) and `step` (default 1), and/or
///   • `ranges`: an array of those sequence objects, for multi-chapter comics.
/// The final list is `pages`, then the top-level sequence, then each `ranges` entry, in order.
enum WebComic {
    struct Seq: Decodable {
        var template: String?; var base: String?; var ext: String?
        var from: Int?; var to: Int?; var pad: Int?; var step: Int?
    }
    struct Doc: Decodable {
        var title: String?
        var pages: [String]?
        var template: String?; var base: String?; var ext: String?
        var from: Int?; var to: Int?; var pad: Int?; var step: Int?
        var ranges: [Seq]?
    }

    static func load(_ file: URL) -> (title: String?, pages: [URL])? {
        guard let data = try? Data(contentsOf: file),
              let doc = try? JSONDecoder().decode(Doc.self, from: data) else { return nil }
        return (doc.title, expand(doc).compactMap { URL(string: $0) })
    }

    // MARK: - Series (one comic per issue; page counts auto-probed at read time)

    struct IntRange: Decodable { var from: Int; var to: Int }
    struct SeriesDoc: Decodable {
        var title: String?
        var base: String?; var ext: String?; var template: String?  // template may use {issue}/{page}
        var issues: IntRange?
        var issuePad: Int?; var pagePad: Int?
        var pageHint: Int?
        /// If set, every issue has exactly this many pages — the app skips probing and generates the
        /// page list directly. Leave unset to auto-detect each issue's length.
        var pagesPerIssue: Int?
    }
    /// One generated issue: display title, cover URL (page 1), the `{page}` template + padding, the
    /// probe hint, and — when the descriptor fixes it — the exact page count (`fixedCount`).
    struct Issue {
        let number: Int; let title: String; let cover: URL?
        let pageTemplate: String; let pagePad: Int; let pageHint: Int
        let fixedCount: Int?
    }

    /// Just the series title (cheap — no issue expansion), for display in headers.
    static func seriesTitle(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let doc = try? JSONDecoder().decode(SeriesDoc.self, from: data) else { return nil }
        return doc.title
    }

    static func loadSeries(_ file: URL) -> (series: String, issues: [Issue])? {
        guard let data = try? Data(contentsOf: file),
              let doc = try? JSONDecoder().decode(SeriesDoc.self, from: data),
              let range = doc.issues else { return nil }
        let series = doc.title ?? file.lastPathComponent
            .replacingOccurrences(of: ".webseries.json", with: "", options: .caseInsensitive)
        let issuePad = doc.issuePad ?? 0
        let pagePad = doc.pagePad ?? 0
        var out: [Issue] = []
        for i in range.from...max(range.from, range.to) {
            let iStr = String(format: "%0\(max(0, issuePad))d", i)
            // Per-page template with a `{page}` placeholder for this issue.
            let pageTemplate: String
            if let t = doc.template, t.contains("{page}") {
                pageTemplate = t.replacingOccurrences(of: "{issue}", with: iStr)
            } else if let base = doc.base {
                pageTemplate = base + iStr + "/{page}" + (doc.ext.map { "." + $0 } ?? "")
            } else { continue }
            let p1 = pageTemplate.replacingOccurrences(
                of: "{page}", with: String(format: "%0\(max(0, pagePad))d", 1))
            out.append(Issue(number: i, title: "\(series) #\(i)", cover: URL(string: p1),
                             pageTemplate: pageTemplate, pagePad: pagePad,
                             pageHint: doc.pageHint ?? 24, fixedCount: doc.pagesPerIssue))
        }
        return out.isEmpty ? nil : (series, out)
    }

    private static func expand(_ d: Doc) -> [String] {
        var out = d.pages ?? []
        out += sequence(Seq(template: d.template, base: d.base, ext: d.ext,
                            from: d.from, to: d.to, pad: d.pad, step: d.step))
        for r in d.ranges ?? [] { out += sequence(r) }
        return out
    }

    private static func sequence(_ s: Seq) -> [String] {
        guard let from = s.from, let to = s.to, to >= from else { return [] }
        let step = max(1, s.step ?? 1)
        let pad = s.pad ?? String(to).count
        return stride(from: from, through: to, by: step).compactMap { n in
            let num = String(format: "%0\(max(0, pad))d", n)
            if let t = s.template, t.contains("{n}") { return t.replacingOccurrences(of: "{n}", with: num) }
            if let base = s.base { return base + num + (s.ext.map { "." + $0 } ?? "") }
            return nil
        }
    }
}

/// Strips scene/scanner metadata from a comic file or folder name for display — bracketed
/// groups like `(2005)`, `(digital)`, `(Minutemen-Slayer)`, `[...]`, plus trailing site tags
/// such as `GetComics.INFO` — while keeping the human title (issue numbers, volumes) intact.
/// Convention-based (not a hardcoded list of groups), so new additions clean up automatically.
enum TitleCleaner {
    static func clean(_ raw: String) -> String {
        var s = raw
        // Any (…) / […] / {…} group → space. Scene tags (year, quality, group) all live in these.
        s = s.replacingOccurrences(
            of: #"[(\[{][^()\[\]{}]*[)\]}]"#, with: " ", options: .regularExpression)
        // Common non-bracketed trailing site tag.
        s = s.replacingOccurrences(
            of: #"(?i)\bGetComics\.INFO\b"#, with: " ", options: .regularExpression)
        // Collapse whitespace, then trim spaces and any dangling separators left behind.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-–—_ "))
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? raw : s
    }
}

/// A chapter of a folder comic, resolved to the page image it bookmarks — used by the
/// library's chapter level. `name` comes from a ComicInfo bookmark (nil for manual chapters).
struct ChapterRef: Identifiable, Hashable {
    let ordinal: Int   // 1-based chapter number in page order
    let page: Int      // 1-based page index in the comic
    let index: Int     // 0-based page index (for jumping)
    let url: URL       // the page image
    let name: String?  // user or ComicInfo-bookmark name, if any
    var key: String = ""  // stored page key (relative path) — identifies the chapter for rename/delete
    /// True for manual (user-created) chapters — renameable/deletable. ComicInfo bookmarks aren't.
    var isManual: Bool = false
    var id: String { url.path }

    /// What to show as the chapter's heading.
    var label: String { name ?? "Chapter \(ordinal)" }
}

/// A navigable folder in the library tree — a series or sub-series you drill into. Its name is
/// the folder name (never hardcoded); its cover is a representative issue from below it, and
/// `count` is how many comics it ultimately contains. `coverArchive` is set (when the cover
/// issue is an archive with no extracted page yet) so the card can lazily extract one.
struct LibraryGroup: Identifiable, Hashable {
    let url: URL
    let coverURL: URL?
    let coverArchive: URL?
    let count: Int
    /// An explicit display name (e.g. a web series' title from its descriptor); when nil, the group
    /// name is the cleaned folder name.
    var title: String? = nil
    var name: String { title ?? TitleCleaner.clean(url.lastPathComponent) }
    var id: String { url.path }
}
