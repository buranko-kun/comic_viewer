import Foundation

/// Extracts a comic archive (.cbz/.cbr/.zip/.rar/.7z) into a temporary directory so the
/// rest of the app can treat it like a normal folder. Uses `unar` (primary; handles the
/// RAR methods 7-Zip can't) with a `7zz` fallback — the same tools the automation uses.
enum ArchiveExtractor {
    static let extensions: Set<String> = ["cbz", "cbr", "zip", "rar", "7z"]

    static func isArchive(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Extract synchronously (call off the main thread). Returns the temp dir, or nil.
    static func extract(_ archive: URL) -> URL? {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicViewer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let unar = firstExecutable(["/opt/homebrew/bin/unar", "/usr/local/bin/unar"])
        let sevenz = firstExecutable(["/opt/homebrew/bin/7zz", "/opt/homebrew/bin/7z",
                                      "/usr/local/bin/7zz"])
        let ok =
            (unar.map { run($0, ["-q", "-f", "-D", "-o", dest.path, archive.path]) } ?? false)
            || (sevenz.map { run($0, ["x", "-y", "-o" + dest.path, archive.path]) } ?? false)

        if ok, containsImage(dest) { return dest }
        try? FileManager.default.removeItem(at: dest)
        return nil
    }

    /// True if the archive holds page images at any level (so the reader can open it directly).
    /// False for a bundle of nested archives (e.g. a .zip of .cbz files) — those need extracting.
    /// If no inspector tool is available, assumes true (don't touch the file).
    static func hasImageEntries(_ archive: URL) -> Bool {
        guard let z = firstExecutable(["/opt/homebrew/bin/7zz", "/opt/homebrew/bin/7z",
                                       "/usr/local/bin/7zz"]) else { return true }
        let out = runCapture(z, ["l", "-slt", "-ba", archive.path])
        for line in out.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.lowercased().hasPrefix("path = ") else { continue }
            let ext = (String(l.dropFirst(7)) as NSString).pathExtension.lowercased()
            if SupportedTypes.extensions.contains(ext) { return true }
        }
        return false
    }

    /// Extract `archive` into a folder named after it (beside the archive), so its contents —
    /// nested comics or loose images — become part of the library. Returns the folder, or nil.
    static func extractInto(_ archive: URL, preferred folder: URL) -> URL? {
        let fm = FileManager.default
        var dest = folder
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = folder.deletingLastPathComponent()
                .appendingPathComponent(folder.lastPathComponent + " (\(n))", isDirectory: true)
            n += 1
        }
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let unar = firstExecutable(["/opt/homebrew/bin/unar", "/usr/local/bin/unar"])
        let sevenz = firstExecutable(["/opt/homebrew/bin/7zz", "/opt/homebrew/bin/7z", "/usr/local/bin/7zz"])
        let ok =
            (unar.map { run($0, ["-q", "-f", "-D", "-o", dest.path, archive.path]) } ?? false)
            || (sevenz.map { run($0, ["x", "-y", "-o" + dest.path, archive.path]) } ?? false)

        if ok, let items = try? fm.contentsOfDirectory(atPath: dest.path), !items.isEmpty { return dest }
        try? fm.removeItem(at: dest)
        return nil
    }

    // MARK: - On-demand streaming (extract specific entries instead of the whole archive)

    static var sevenz: String? {
        firstExecutable(["/opt/homebrew/bin/7zz", "/opt/homebrew/bin/7z", "/usr/local/bin/7zz"])
    }
    static var unar: String? {
        firstExecutable(["/opt/homebrew/bin/unar", "/usr/local/bin/unar"])
    }

    /// Archive `type` (e.g. "zip", "Rar", "7z") plus its non-directory entry paths in stored
    /// order, via `7zz l -slt`. Returns nil when no `7zz` is available. The type lets the caller
    /// stream only formats with cheap, reliable random access (ZIP) and full-extract the rest —
    /// per-entry `7zz` extraction of RAR/solid archives is slow or unsupported.
    static func list(_ archive: URL) -> (type: String, entries: [String])? {
        guard let z = sevenz else { return nil }
        // No `-ba`: keep the header block so we can read its `Type =`.
        let out = runCapture(z, ["l", "-slt", "--", archive.path])
        var type = ""
        var entries: [String] = []
        for block in out.components(separatedBy: "\n\n") {
            var path: String?
            var isDir = false
            var blockType: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("Type = ") { blockType = String(line.dropFirst(7)) }
                else if line.hasPrefix("Path = ") { path = String(line.dropFirst(7)) }
                else if line.hasPrefix("Folder = ") && line.hasSuffix("+") { isDir = true }
                else if line.hasPrefix("Attributes = ") && line.contains("D") { isDir = true }
            }
            if let t = blockType {           // the archive-info header block, not an entry
                if type.isEmpty { type = t }
                continue
            }
            if let p = path, !isDir { entries.append(p) }
        }
        return type.isEmpty ? nil : (type, entries)
    }

    /// Extract just `entries` (archive-internal paths, tree preserved) into `dir`, skipping any
    /// already present. Returns false if `7zz` is missing or the command fails — the caller then
    /// decides whether every needed file actually landed. RAR3/solid archives may report success
    /// yet produce nothing, so callers must verify the files they need exist.
    @discardableResult
    static func extractEntries(_ archive: URL, _ entries: [String], into dir: URL) -> Bool {
        guard !entries.isEmpty else { return true }
        guard let z = sevenz else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ok = run(z, ["x", "-y", "-aos", "-o" + dir.path, "--", archive.path] + entries)
        // A RAR using a method `7zz` can't decompress *lists* fine but extracts a 0-byte stub and
        // errors out. Delete those stubs so `-aos` won't later skip them and the caller sees the
        // page as missing (→ falls back to a full `unar` extract that can read it).
        for entry in entries {
            let u = dir.appendingPathComponent(entry)
            if fm.fileExists(atPath: u.path), fileSize(u) == 0 { try? fm.removeItem(at: u) }
        }
        return ok
    }

    /// Size in bytes of a file, or 0 if it's missing/empty/unreadable.
    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    /// Repackage a non-ZIP comic (e.g. a RAR-backed `.cbr`/`.cbz`) into a ZIP **in place** so it
    /// streams page-by-page. Lossless — the page images are copied verbatim (stored, not
    /// recompressed); only the container format changes. The original filename is kept (streaming
    /// keys off the real archive type, not the extension), so the library path and its saved
    /// chapters/resume stay valid. Returns true when the file is (now) a streamable ZIP, false on
    /// failure — in which case the original is left untouched. Runs synchronously; call off-main.
    @discardableResult
    static func normalizeToZip(_ archive: URL) -> Bool {
        guard let z = sevenz, let listing = list(archive) else { return false }
        if listing.type.caseInsensitiveCompare("zip") == .orderedSame { return true }
        let isImage: (String) -> Bool = {
            SupportedTypes.extensions.contains(($0 as NSString).pathExtension.lowercased())
        }
        let srcImages = listing.entries.filter(isImage).count
        guard srcImages > 0 else { return false }

        let fm = FileManager.default
        guard let extracted = extract(archive) else { return false }
        defer { try? fm.removeItem(at: extracted) }

        // Build the ZIP beside the original (same volume → atomic rename later). `-mx=0` stores
        // the already-compressed images; running in `extracted` keeps entry paths relative.
        let zipTmp = archive.deletingLastPathComponent()
            .appendingPathComponent(".repack-\(UUID().uuidString).zip")
        try? fm.removeItem(at: zipTmp)
        guard run(z, ["a", "-tzip", "-mx=0", "--", zipTmp.path, "."], inDir: extracted),
              let newListing = list(zipTmp),
              newListing.type.caseInsensitiveCompare("zip") == .orderedSame,
              newListing.entries.filter(isImage).count == srcImages   // no pages dropped
        else { try? fm.removeItem(at: zipTmp); return false }

        // Swap in place, keeping the original aside until the new file is safely in position.
        let backup = archive.appendingPathExtension("repack-bak")
        try? fm.removeItem(at: backup)
        do {
            try fm.moveItem(at: archive, to: backup)
            try fm.moveItem(at: zipTmp, to: archive)
            try? fm.removeItem(at: backup)
            return true
        } catch {
            if !fm.fileExists(atPath: archive.path) { try? fm.moveItem(at: backup, to: archive) }
            try? fm.removeItem(at: zipTmp)
            return false
        }
    }

    /// Fill `dir` with the archive's full contents (skipping files already extracted on-demand),
    /// so pages the reader hasn't jumped to yet are ready. Best-effort: `7zz` first, `unar` fallback.
    @discardableResult
    static func extractAllInto(_ archive: URL, dir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let z = sevenz, run(z, ["x", "-y", "-aos", "-o" + dir.path, "--", archive.path]) { return true }
        if let u = unar { return run(u, ["-q", "-f", "-D", "-o", dir.path, archive.path]) }
        return false
    }

    // MARK: - helpers

    private static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runCapture(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func run(_ tool: String, _ args: [String], inDir: URL? = nil) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = inDir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func containsImage(_ dir: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let u as URL in e where SupportedTypes.isSupported(u) { return true }
        return false
    }
}
