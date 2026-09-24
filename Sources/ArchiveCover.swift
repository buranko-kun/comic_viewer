import Foundation

/// Produces (and caches) a cover image for an archive comic without extracting the whole thing,
/// so the library can show real covers for `.cbz/.cbr/…` instead of a placeholder. Covers live
/// in `~/Library/Application Support/ComicViewer/covers/<sha(archivePath)>.<ext>`.
enum ArchiveCover {
    static var dir: URL { CentralStore.baseDir.appendingPathComponent("covers", isDirectory: true) }

    private static let imageExts: Set<String> = ["jpg", "jpeg", "png"]

    /// Async wrapper — runs the extraction off the main actor.
    static func make(for archive: URL) async -> URL? {
        await Task.detached(priority: .utility) { makeSync(for: archive) }.value
    }

    /// Return a cached cover if present, else extract the first image entry and cache it.
    static func makeSync(for archive: URL) -> URL? {
        let key = CentralStore.sha256(CentralStore.key(for: archive))
        let fm = FileManager.default
        if let hit = cached(key: key) { return hit }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Preferred: list with 7zz, extract only the first image entry (fast).
        if let sevenz = firstExecutable(["/opt/homebrew/bin/7zz", "/opt/homebrew/bin/7z",
                                         "/usr/local/bin/7zz"]),
           let entry = firstImageEntry(sevenz, archive),
           let cover = extractOne(sevenz, archive, entry, key: key) {
            return cover
        }
        // Fallback: full extract via the shared extractor, copy the first image.
        if let tmp = ArchiveExtractor.extract(archive) {
            defer { try? fm.removeItem(at: tmp) }
            let imgs = FileScanner.scanRecursive(tmp)
            if let first = imgs.first(where: isNonEmpty) {
                let dest = dir.appendingPathComponent(key + "." + first.pathExtension.lowercased())
                try? fm.removeItem(at: dest)
                if (try? fm.copyItem(at: first, to: dest)) != nil { return dest }
            }
        }
        return nil
    }

    // MARK: - helpers

    private static func cached(key: String) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { $0.deletingPathExtension().lastPathComponent == key && isNonEmpty($0) }
    }

    /// A real, decodable cover must have bytes. `7zz` can *list* a RAR3/4 entry but fail to
    /// decompress it, leaving a 0-byte file behind — which we must reject so the extraction
    /// falls back to `unar` (and so a stale empty cache entry regenerates).
    private static func isNonEmpty(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
    }

    /// First image entry (by natural name order) inside the archive, via `7zz l -slt`.
    private static func firstImageEntry(_ sevenz: String, _ archive: URL) -> String? {
        guard let out = run(sevenz, ["l", "-slt", "-ba", "--", archive.path]) else { return nil }
        var paths: [String] = []
        for block in out.components(separatedBy: "\n\n") {
            var path: String?
            var isDir = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("Path = ") { path = String(line.dropFirst(7)) }
                else if line.hasPrefix("Folder = ") && line.hasSuffix("+") { isDir = true }
                else if line.hasPrefix("Attributes = ") && line.contains("D") { isDir = true }
            }
            if let p = path, !isDir, imageExts.contains((p as NSString).pathExtension.lowercased()) {
                paths.append(p)
            }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first
    }

    /// Extract a single entry to the cover cache; returns the cached file.
    private static func extractOne(_ sevenz: String, _ archive: URL, _ entry: String, key: String) -> URL? {
        let fm = FileManager.default
        let work = dir.appendingPathComponent("tmp-" + key, isDirectory: true)
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        // `e` flattens paths → the file lands in `work` under its basename.
        _ = run(sevenz, ["e", "-y", "-o" + work.path, "--", archive.path, entry])
        guard let file = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?
            .first(where: { imageExts.contains($0.pathExtension.lowercased()) && isNonEmpty($0) })
        else { return nil }
        let dest = dir.appendingPathComponent(key + "." + file.pathExtension.lowercased())
        try? fm.removeItem(at: dest)
        try? fm.moveItem(at: file, to: dest)
        return fm.fileExists(atPath: dest.path) ? dest : nil
    }

    private static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
