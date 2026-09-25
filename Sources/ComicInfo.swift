import Foundation

/// Metadata parsed from a `ComicInfo.xml` (the ComicRack de-facto standard) sitting in a
/// comic folder (or an extracted archive). Book-level fields drive nicer titles/tooltips in
/// the library; `bookmarks` (from `<Page Bookmark="…">`) become **named chapters**.
struct ComicInfo: Hashable, Codable {
    var title: String?
    var series: String?
    var number: String?
    var count: Int?          // total issues in the series
    var volume: String?
    var summary: String?
    var year: String?
    var month: String?
    var day: String?
    // Creators (each may be a comma-separated list of names).
    var writer: String?
    var penciller: String?
    var inker: String?
    var colorist: String?
    var letterer: String?
    var coverArtist: String?
    var editor: String?
    var publisher: String?
    var imprint: String?
    var genre: String?
    var web: String?
    var languageISO: String?
    var ageRating: String?
    var characters: String?
    var teams: String?
    var manga: String?       // "Yes"/"YesAndRightToLeft" → RTL reading
    var pageCount: Int?
    /// ComicVine volume ID used to refresh metadata without requiring another search.
    var comicVineVolumeID: Int?
    var bookmarks: [Bookmark] = []

    struct Bookmark: Hashable, Codable { let imageIndex: Int; let name: String }

    /// A human title for the library cell, best-effort from the available fields.
    var displayTitle: String? {
        if let t = title, !t.isEmpty { return t }
        guard let s = series, !s.isEmpty else { return nil }
        if let n = number, !n.isEmpty { return "\(s) #\(n)" }
        return s
    }

    /// Reading direction hint from the `Manga` field.
    var isRightToLeft: Bool { (manga ?? "").localizedCaseInsensitiveContains("RightToLeft") }

    /// All creators, deduped in role order, as a single "Name, Name" string.
    var authors: String? {
        var seen = Set<String>(); var out: [String] = []
        for field in [writer, penciller, inker, colorist, letterer, coverArtist, editor] {
            for name in (field ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) })
            where !name.isEmpty && seen.insert(name).inserted { out.append(name) }
        }
        return out.isEmpty ? nil : out.joined(separator: ", ")
    }

    /// Release date as a display string (year, or year-month, or full date).
    var dateString: String? {
        guard let y = year, !y.isEmpty else { return nil }
        if let m = month, !m.isEmpty {
            let mm = String(format: "%02d", Int(m) ?? 0)
            if let d = day, !d.isEmpty { return "\(y)-\(mm)-\(String(format: "%02d", Int(d) ?? 0))" }
            return "\(y)-\(mm)"
        }
        return y
    }

    /// Labeled metadata rows for a detail view (only the fields that are present).
    var metadataRows: [(key: String, value: String)] {
        var rows: [(String, String)] = []
        func add(_ k: String, _ v: String?) { if let v, !v.isEmpty { rows.append((k, v)) } }
        add("Series", series)
        if let n = number, !n.isEmpty { add("Issue", count.map { "#\(n) of \($0)" } ?? "#\(n)") }
        add("Date", dateString)
        add("Writer", writer)
        add("Art", [penciller, inker, colorist].compactMap { $0 }.joined(separator: ", ").nilIfEmpty)
        add("Cover", coverArtist)
        add("Publisher", [publisher, imprint].compactMap { $0 }.joined(separator: " / ").nilIfEmpty)
        add("Genre", genre)
        add("Characters", characters)
        add("Rating", ageRating)
        return rows
    }

    /// A short credits/date line for compact display.
    var creditLine: String? {
        let parts = [writer ?? authors, dateString].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A multi-line tooltip: title/series/credits/publisher/genre + summary.
    var tooltip: String? {
        var lines: [String] = []
        if let s = series, !s.isEmpty { lines.append(s) }
        if let c = creditLine { lines.append(c) }
        if let p = publisher, !p.isEmpty { lines.append(p) }
        if let g = genre, !g.isEmpty { lines.append(g) }
        if let sum = summary, !sum.isEmpty { lines.append("\n" + sum) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Loading

    static let fileName = "ComicInfo.xml"

    /// Parse `<folder>/ComicInfo.xml` if present (case-insensitive), else nil.
    static func load(fromFolder dir: URL) -> ComicInfo? {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(fileName)
        if !fm.fileExists(atPath: url.path) {
            let match = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .first { $0.lastPathComponent.caseInsensitiveCompare(fileName) == .orderedSame }
            guard let match else { return nil }
            url = match
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    private static func parse(_ data: Data) -> ComicInfo? {
        let parser = XMLParser(data: data)
        let delegate = ComicInfoParser()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        var info = delegate.info
        info.bookmarks.sort { $0.imageIndex < $1.imageIndex }
        return info
    }

    // Archive `ComicInfo.xml` is read on demand (extracting just that one small entry) and memoized,
    // so library scans stay fast — metadata is only pulled when a comic's details are viewed.
    private static let cacheLock = NSLock()
    private static var archiveCache: [String: ComicInfo?] = [:]

    /// Where a written-back sidecar lives for an archive (we can't write inside an existing archive):
    /// `<archive>.comicinfo.xml` right next to it.
    static func sidecarURL(forArchive archive: URL) -> URL {
        URL(fileURLWithPath: archive.path + ".comicinfo.xml")
    }

    /// Parse the `ComicInfo.xml` for an archive — a written sidecar takes priority, else the one
    /// stored inside the archive. Memoized by path + size.
    static func load(fromArchive archive: URL) -> ComicInfo? {
        let key = archive.path + "|" + String(ArchiveExtractor.fileSize(archive))
        cacheLock.lock()
        if let cached = archiveCache[key] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        // A sidecar we wrote (from an online fetch) wins over embedded metadata.
        let sidecar = sidecarURL(forArchive: archive)
        if let data = try? Data(contentsOf: sidecar), let info = parse(data) {
            cacheLock.lock(); archiveCache[key] = info; cacheLock.unlock()
            return info
        }

        var result: ComicInfo?
        if let listing = ArchiveExtractor.list(archive),
           let entry = listing.entries.first(where: {
               ($0 as NSString).lastPathComponent.caseInsensitiveCompare(fileName) == .orderedSame }) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("comicinfo-" + UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            ArchiveExtractor.extractEntries(archive, [entry], into: tmp)
            if let data = try? Data(contentsOf: tmp.appendingPathComponent(entry)) {
                result = parse(data)
            }
        }
        cacheLock.lock(); archiveCache[key] = result; cacheLock.unlock()
        return result
    }

    /// Load metadata for any comic — folder or archive — on demand.
    static func load(forComic url: URL, isArchive: Bool) -> ComicInfo? {
        isArchive ? load(fromArchive: url) : load(fromFolder: url)
    }

    /// Forget memoized archive metadata (call after writing a sidecar so it's re-read).
    static func clearCache() { cacheLock.lock(); archiveCache.removeAll(); cacheLock.unlock() }

    // MARK: Writing

    /// A minimal ComicInfo.xml document from the populated fields.
    func xmlString() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var el = ""
        func add(_ tag: String, _ v: String?) { if let v, !v.isEmpty { el += "  <\(tag)>\(esc(v))</\(tag)>\n" } }
        func addInt(_ tag: String, _ v: Int?) { if let v { el += "  <\(tag)>\(v)</\(tag)>\n" } }
        add("Title", title); add("Series", series); add("Number", number); addInt("Count", count)
        add("Volume", volume); add("Summary", summary)
        add("Year", year); add("Month", month); add("Day", day)
        add("Writer", writer); add("Penciller", penciller); add("Inker", inker)
        add("Colorist", colorist); add("Letterer", letterer); add("CoverArtist", coverArtist)
        add("Editor", editor); add("Publisher", publisher); add("Imprint", imprint)
        add("Genre", genre); add("Web", web); add("LanguageISO", languageISO)
        add("AgeRating", ageRating); add("Characters", characters); add("Teams", teams)
        addInt("PageCount", pageCount)
        addInt("ComicViewerVolumeID", comicVineVolumeID)
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<ComicInfo>\n\(el)</ComicInfo>\n"
    }

    /// Write `ComicInfo.xml` for a comic: into the folder (standard, portable) or as a sidecar next
    /// to an archive. Invalidates the archive metadata cache so it's re-read. Returns success.
    @discardableResult
    func write(forComic url: URL, isArchive: Bool) -> Bool {
        let dest = isArchive
            ? ComicInfo.sidecarURL(forArchive: url)
            : url.appendingPathComponent(ComicInfo.fileName)
        do {
            try xmlString().data(using: .utf8)?.write(to: dest, options: .atomic)
            ComicInfo.clearCache()
            return true
        } catch { return false }
    }
}

/// XMLParser delegate that fills a `ComicInfo`.
private final class ComicInfoParser: NSObject, XMLParserDelegate {
    var info = ComicInfo()
    private var element = ""
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String] = [:]) {
        element = name
        text = ""
        if name == "Page", let img = attrs["Image"], let idx = Int(img),
           let bm = attrs["Bookmark"], !bm.isEmpty {
            info.bookmarks.append(.init(imageIndex: idx, name: bm))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        switch name {
        case "Title":       info.title = v
        case "Series":      info.series = v
        case "Number":      info.number = v
        case "Count":       info.count = Int(v)
        case "Volume":      info.volume = v
        case "Summary":     info.summary = v
        case "Year":        info.year = v
        case "Month":       info.month = v
        case "Day":         info.day = v
        case "Writer":      info.writer = v
        case "Penciller":   info.penciller = v
        case "Inker":       info.inker = v
        case "Colorist":    info.colorist = v
        case "Letterer":    info.letterer = v
        case "CoverArtist": info.coverArtist = v
        case "Editor":      info.editor = v
        case "Publisher":   info.publisher = v
        case "Imprint":     info.imprint = v
        case "Genre":       info.genre = v
        case "Web":         info.web = v
        case "LanguageISO": info.languageISO = v
        case "AgeRating":   info.ageRating = v
        case "Characters":  info.characters = v
        case "Teams":       info.teams = v
        case "Manga":       info.manga = v
        case "PageCount":   info.pageCount = Int(v)
        case "ComicViewerVolumeID": info.comicVineVolumeID = Int(v)
        default: break
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
