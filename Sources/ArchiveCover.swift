import Foundation
import CoreGraphics
import ImageIO

/// Produces (and caches) a cover image for an archive comic without extracting the whole thing,
/// so the library can show real covers for `.cbz/.cbr/…` instead of a placeholder. Covers live
/// in `~/Library/Application Support/ComicViewer/covers/<sha(archivePath)>.<ext>`.
enum ArchiveCover {
    static var dir: URL { CentralStore.baseDir.appendingPathComponent("covers", isDirectory: true) }

    private static let imageExts = SupportedTypes.extensions

    /// Async wrapper — runs the extraction off the main actor.
    static func make(for archive: URL) async -> URL? {
        await Task.detached(priority: .utility) { makeSync(for: archive) }.value
    }

    /// Preserve a compact cover keyed by the comic's stable path. This survives page trimming,
    /// where the original first image may be removed from the archive.
    static func preserveThumbnail(for archive: URL, cacheDirectory: URL = dir) async -> Bool {
        await Task.detached(priority: .utility) { preserveThumbnailSync(for: archive, cacheDirectory: cacheDirectory) }.value
    }

    /// A CBR trim may create a sibling CBZ, so carry its saved cover to the replacement path.
    static func copyPreservedThumbnail(from source: URL, to destination: URL) {
        let from = preservedURL(for: source)
        let to = preservedURL(for: destination)
        guard from != to, FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.removeItem(at: to)
        try? FileManager.default.copyItem(at: from, to: to)
    }

    /// Return a cached cover if present, else extract the first image entry and cache it.
    static func makeSync(for archive: URL, cacheDirectory: URL = dir) -> URL? {
        let key = CentralStore.sha256(CentralStore.key(for: archive))
        let fm = FileManager.default
        let thumb = preservedURL(for: archive, cacheDirectory: cacheDirectory)
        if isNonEmpty(thumb) { return thumb }
        if let hit = cached(key: key, cacheDirectory: cacheDirectory) { return hit }
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Preferred: list with 7zz, extract only the first image entry (fast).
        if let sevenz = firstExecutable(["/opt/homebrew/bin/7zz", "/opt/homebrew/bin/7z",
                                         "/usr/local/bin/7zz"]),
           let entry = firstImageEntry(sevenz, archive),
           let cover = extractOne(sevenz, archive, entry, key: key, cacheDirectory: cacheDirectory) {
            return cover
        }
        // Fallback: full extract via the shared extractor, copy the first image.
        if let tmp = ArchiveExtractor.extract(archive) {
            defer { try? fm.removeItem(at: tmp) }
            let imgs = FileScanner.scanRecursive(tmp)
            if let first = imgs.first(where: isNonEmpty) {
                let dest = cacheDirectory.appendingPathComponent(key + "." + first.pathExtension.lowercased())
                try? fm.removeItem(at: dest)
                if (try? fm.copyItem(at: first, to: dest)) != nil { return dest }
            }
        }
        return nil
    }

    /// Explicit refresh only: ordinary reads retain covers saved before page trimming.
    static func refresh(for archive: URL) async -> URL? {
        await Task.detached(priority: .utility) { refreshSync(for: archive) }.value
    }

    static func cachedURLs(for archive: URL, cacheDirectory: URL = dir) -> [URL] {
        let key = CentralStore.sha256(CentralStore.key(for: archive))
        return ((try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                              includingPropertiesForKeys: nil)) ?? []).filter {
            let name = $0.deletingPathExtension().lastPathComponent
            return name == key || name == key + "-preserved"
        }.map { cacheDirectory.appendingPathComponent($0.lastPathComponent) }
    }

    static func refreshSync(for archive: URL, cacheDirectory: URL = dir) -> URL? {
        let fm = FileManager.default
        let staging = cacheDirectory.appendingPathComponent("refresh-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        guard let fresh = makeSync(for: archive, cacheDirectory: staging),
              let source = CGImageSourceCreateWithURL(fresh as CFURL, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let data = try? Data(contentsOf: fresh) else { return nil }
        let preserved = preservedURL(for: archive, cacheDirectory: cacheDirectory)
        let hadPreserved = isNonEmpty(preserved)
        var preservedData: Data?
        if hadPreserved {
            guard preserveThumbnailSync(for: archive, cacheDirectory: staging),
                  let bytes = try? Data(contentsOf: preservedURL(for: archive, cacheDirectory: staging))
            else { return nil }
            preservedData = bytes
        }
        let destination = cacheDirectory.appendingPathComponent(fresh.lastPathComponent)
        let old = cachedURLs(for: archive, cacheDirectory: cacheDirectory)
        do {
            if let preservedData { try preservedData.write(to: preserved, options: .atomic) }
            try data.write(to: destination, options: .atomic)
        } catch { return nil }
        for url in old where url.lastPathComponent != destination.lastPathComponent
            && url.lastPathComponent != preserved.lastPathComponent {
            try? fm.removeItem(at: url)
        }
        return hadPreserved ? preserved : destination
    }

    private static func preserveThumbnailSync(for archive: URL, cacheDirectory: URL = dir) -> Bool {
        let destination = preservedURL(for: archive, cacheDirectory: cacheDirectory)
        if isNonEmpty(destination) { return true }
        guard let source = makeSync(for: archive, cacheDirectory: cacheDirectory),
              let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 420,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return false }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(output) && isNonEmpty(destination)
    }

    private static func preservedURL(for archive: URL, cacheDirectory: URL = dir) -> URL {
        let key = CentralStore.sha256(CentralStore.key(for: archive))
        return cacheDirectory.appendingPathComponent(key + "-preserved.jpg")
    }

    // MARK: - helpers

    private static func cached(key: String, cacheDirectory: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil))?
            .first { $0.deletingPathExtension().lastPathComponent == key && isNonEmpty($0) }
            .map { cacheDirectory.appendingPathComponent($0.lastPathComponent) }
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
    private static func extractOne(_ sevenz: String, _ archive: URL, _ entry: String, key: String, cacheDirectory: URL) -> URL? {
        let fm = FileManager.default
        let work = cacheDirectory.appendingPathComponent("tmp-" + key, isDirectory: true)
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        // `e` flattens paths → the file lands in `work` under its basename.
        _ = run(sevenz, ["e", "-y", "-o" + work.path, "--", archive.path, entry])
        guard let file = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?
            .first(where: { imageExts.contains($0.pathExtension.lowercased()) && isNonEmpty($0) })
        else { return nil }
        let dest = cacheDirectory.appendingPathComponent(key + "." + file.pathExtension.lowercased())
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
