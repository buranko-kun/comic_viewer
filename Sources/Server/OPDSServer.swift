import Foundation
import Swifter

/// An OPDS 1.2 catalog over the same LAN server, so any OPDS reader (KOReader, Panels, Chunky, …)
/// can browse and download the library — no custom client needed. It mirrors the folder tree as
/// navigation feeds and comics as acquisition entries whose download link is a **CBZ**:
///   • an existing `.cbz`/`.zip` is streamed **raw** (chunked — safe even for multi-GB omnibuses),
///   • a folder-of-images or other archive (`.cbr`/`.rar`/`.7z`) is packed into a CBZ on demand
///     (cached), so readers always get a format they open cleanly.
/// Every generated href carries `?code=` so the whole catalog is self-authenticating; the auth
/// middleware also accepts HTTP Basic (password = code) for readers that prompt for credentials.
enum OPDSServer {
    private static let navType = "application/atom+xml;profile=opds-catalog;kind=navigation"
    private static let acqType = "application/atom+xml;profile=opds-catalog;kind=acquisition"
    private static let cbzType = "application/vnd.comicbook+zip"

    static func register(on s: HttpServer, code: String) {
        func q(_ path: String) -> String { path.contains("?") ? "\(path)&code=\(code)" : "\(path)?code=\(code)" }

        // Root: the library's top level.
        let root: (HttpRequest) -> HttpResponse = { _ in
            guard let level = onMainSync({ opdsLevel(dirToken: nil) }) else { return .raw(404, "Not Found", nil, nil) }
            return xml(feed(level, selfHref: q("/opds"), code: code))
        }
        s["/opds"] = root
        s["/opds/"] = root

        // A drilled-in folder level.
        s["/opds/library"] = { req in
            let dir = req.queryParams.first { $0.0 == "dir" }?.1
            guard let dir, let level = onMainSync({ opdsLevel(dirToken: dir) }) else { return .raw(404, "Not Found", nil, nil) }
            return xml(feed(level, selfHref: q("/opds/library?dir=\(dir)"), code: code))
        }

        // Download a comic as CBZ.
        s["/opds/comic/:id/file.cbz"] = { req in
            guard let id = req.params[":id"], let rc = resolveComic(id) else { return .raw(404, "Not Found", nil, nil) }
            guard let file = CBZBuilder.shared.cbz(forComicPath: rc.path, isArchive: rc.isArchive) else {
                return .raw(404, "Not Found", nil, nil)
            }
            return streamFile(file.url, downloadName: file.name)
        }

        // Cover thumbnail.
        s["/opds/comic/:id/cover"] = { req in
            guard let id = req.params[":id"], let rc = resolveComic(id) else { return .raw(404, "Not Found", nil, nil) }
            guard let cu = PageIndex.shared.coverFile(forComicPath: rc.path, isArchive: rc.isArchive),
                  let data = ServerImage.jpegData(from: cu, maxPixel: 500) else {
                return .raw(404, "Not Found", nil, nil)
            }
            return .ok(.data(data, contentType: "image/jpeg"))
        }
    }

    // MARK: - Feed XML

    private struct Level { let title: String; let groups: [(token: String, name: String)]; let comics: [(token: String, title: String)] }

    private static func feed(_ level: Level, selfHref: String, code: String) -> String {
        func q(_ path: String) -> String { path.contains("?") ? "\(path)&code=\(code)" : "\(path)?code=\(code)" }
        let updated = iso8601(Date())
        var body = ""
        // Navigation entries (sub-folders).
        for g in level.groups {
            body += """
            <entry>
              <title>\(esc(g.name))</title>
              <id>urn:folder:\(g.token)</id>
              <updated>\(updated)</updated>
              <link rel="subsection" href="\(attr(q("/opds/library?dir=\(g.token)")))" type="\(acqType)"/>
            </entry>

            """
        }
        // Acquisition entries (comics).
        for c in level.comics {
            body += """
            <entry>
              <title>\(esc(c.title))</title>
              <id>urn:comic:\(c.token)</id>
              <updated>\(updated)</updated>
              <link rel="http://opds-spec.org/image/thumbnail" href="\(attr(q("/opds/comic/\(c.token)/cover")))" type="image/jpeg"/>
              <link rel="http://opds-spec.org/acquisition" href="\(attr(q("/opds/comic/\(c.token)/file.cbz")))" type="\(cbzType)"/>
            </entry>

            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
          <id>urn:comicviewer:opds\(selfHref)</id>
          <title>\(esc(level.title))</title>
          <updated>\(updated)</updated>
          <link rel="self" href="\(attr(selfHref))" type="\(navType)"/>
          <link rel="start" href="\(attr(q("/opds")))" type="\(navType)"/>
        \(body)</feed>
        """
    }

    // MARK: - Main-actor snapshot

    @MainActor private static func opdsLevel(dirToken: String?) -> Level? {
        let library = LibraryModel.shared
        var dir: URL?
        var title = "Library"
        if let token = dirToken, let path = decodePath(token) {
            let u = URL(fileURLWithPath: path).standardizedFileURL
            guard library.folders.contains(where: { u.path.hasPrefix($0.standardizedFileURL.path) }) else { return nil }
            dir = u
            title = u.lastPathComponent
        }
        let entries = library.entries(at: dir)
        let groups = entries.groups.map { (token: encodePath($0.url.path), name: $0.name) }
        let comics = entries.comics.map { (token: encodePath($0.url.path), title: $0.title) }
        return Level(title: title, groups: groups, comics: comics)
    }

    private static func resolveComic(_ id: String) -> (path: String, isArchive: Bool)? {
        guard let path = decodePath(id) else { return nil }
        return onMainSync {
            guard let c = LibraryModel.shared.comics.first(where: { $0.url.path == path }) else { return nil }
            return (c.url.path, c.isArchive)
        }
    }

    // MARK: - Responses

    private static func xml(_ s: String) -> HttpResponse {
        .raw(200, "OK", ["Content-Type": "application/atom+xml;charset=utf-8"]) { writer in
            try writer.write(Data(s.utf8))
        }
    }

    /// Stream a file to the client in chunks, so a multi-GB CBZ never loads fully into memory.
    private static func streamFile(_ url: URL, downloadName: String) -> HttpResponse {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .raw(404, "Not Found", nil, nil) }
        let size = ArchiveExtractor.fileSize(url)
        let headers = [
            "Content-Type": cbzType,
            "Content-Length": String(size),
            "Content-Disposition": "attachment; filename=\"\(downloadName)\""
        ]
        return .raw(200, "OK", headers) { writer in
            defer { try? handle.close() }
            while true {
                let chunk = handle.readData(ofLength: 256 * 1024)
                if chunk.isEmpty { break }
                try writer.write(chunk)
            }
        }
    }

    // MARK: - XML escaping / dates

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    private static func attr(_ s: String) -> String {
        esc(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: d)
    }
}

/// Builds and caches a CBZ for a comic so OPDS readers always get a clean zip. Existing `.cbz`/`.zip`
/// files are returned as-is (streamed raw by the caller). Folders and other archives are packed once
/// into `…/opds-cbz/<sha>.cbz` and reused. Thread-safe (server handlers run off the main actor).
final class CBZBuilder {
    static let shared = CBZBuilder()
    private let lock = NSLock()
    private var built: [String: URL] = [:]

    private var dir: URL {
        let d = CentralStore.baseDir.appendingPathComponent("opds-cbz", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Returns a CBZ URL + download filename for a comic, building it if needed.
    func cbz(forComicPath path: String, isArchive: Bool) -> (url: URL, name: String)? {
        let comicURL = URL(fileURLWithPath: path)
        let baseName = comicURL.deletingPathExtension().lastPathComponent
        let ext = comicURL.pathExtension.lowercased()

        // Already a zip container — serve the original file directly.
        if isArchive, ext == "cbz" || ext == "zip" {
            return (comicURL, baseName + ".cbz")
        }

        let out = dir.appendingPathComponent(CentralStore.sha256(path) + ".cbz")
        lock.lock()
        if let u = built[path], FileManager.default.fileExists(atPath: u.path) { lock.unlock(); return (u, baseName + ".cbz") }
        lock.unlock()

        // Repacking needs every page as a real file — folders directly, archives fully extracted.
        let pages = PageIndex.shared.allPageFiles(forComicPath: path, isArchive: isArchive)
        guard !pages.isEmpty, Self.build(pages: pages, to: out) else { return nil }
        lock.lock(); built[path] = out; lock.unlock()
        return (out, baseName + ".cbz")
    }

    /// Pack `pages` (in order) into a stored (uncompressed — images already are) CBZ. Numbered
    /// symlinks give clean, collision-free, correctly-ordered entry names; `zip` follows the links
    /// and stores each page's content.
    private static func build(pages: [URL], to out: URL) -> Bool {
        guard let zip = firstExecutable(["/usr/bin/zip"]) else { return false }
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("opds-stage-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        var names: [String] = []
        for (i, p) in pages.enumerated() {
            let e = p.pathExtension.isEmpty ? "jpg" : p.pathExtension
            let name = String(format: "%05d.%@", i + 1, e)
            let link = stage.appendingPathComponent(name)
            try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: p)
            names.append(name)
        }
        guard !names.isEmpty else { return false }
        try? FileManager.default.removeItem(at: out)   // rebuild fresh

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: zip)
        proc.currentDirectoryURL = stage
        proc.arguments = ["-0", "-q", "-X", out.path] + names   // follows symlinks → stores content
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return false }
        return proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.path)
    }

    func clear() {
        lock.lock(); built.removeAll(); lock.unlock()
        try? FileManager.default.removeItem(at: dir)
    }

    private static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
