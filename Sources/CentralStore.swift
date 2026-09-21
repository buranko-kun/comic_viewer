import Foundation
import CryptoKit

/// Central on-disk location for the app's data, under
/// `~/Library/Application Support/ComicViewer/`:
///   • `state/<sha256(comicKey)>.json` — one `ComicState` per comic (chapters, resume, rotation)
///   • `library.json`                  — the configured library folders
///
/// A comic's **key** is its canonical filesystem path (the leaf image folder, or the archive
/// file). Hashing it keeps filenames flat and safe; the `path` inside each `ComicState` keeps
/// the file human-readable.
enum CentralStore {
    static let appName = "ComicViewer"

    static var baseDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appName, isDirectory: true)
    }
    static var stateDir: URL { baseDir.appendingPathComponent("state", isDirectory: true) }
    static var libraryConfigURL: URL { baseDir.appendingPathComponent("library.json") }

    /// Create the base/state directories if needed (cheap, idempotent).
    static func ensureDirs() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    /// The canonical key for a comic: its standardized path.
    static func key(for url: URL) -> String { url.standardizedFileURL.path }

    /// Where a comic's state file lives, given its key.
    static func stateURL(for comicKey: String) -> URL {
        ensureDirs()
        return stateDir.appendingPathComponent(sha256(comicKey) + ".json")
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Per-comic state

    /// Read a comic's saved state (chapters/resume/rotation), or nil if none.
    static func loadState(forKey comicKey: String) -> ComicState? {
        guard let data = try? Data(contentsOf: stateURL(for: comicKey)) else { return nil }
        return try? JSONDecoder().decode(ComicState.self, from: data)
    }

    /// When a comic was last read — the state file's modification time (nil if never opened).
    /// Used to order the library's "Continue Reading" shelf by recency.
    static func lastReadDate(forKey comicKey: String) -> Date? {
        let url = stateDir.appendingPathComponent(sha256(comicKey) + ".json")
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - Library config

    private struct LibraryConfig: Codable { var folders: [String] }

    static func loadLibraryFolders() -> [URL] {
        guard let data = try? Data(contentsOf: libraryConfigURL),
              let cfg = try? JSONDecoder().decode(LibraryConfig.self, from: data) else { return [] }
        return cfg.folders.map { URL(fileURLWithPath: $0) }
    }

    static func saveLibraryFolders(_ urls: [URL]) {
        ensureDirs()
        let cfg = LibraryConfig(folders: urls.map { $0.standardizedFileURL.path })
        if let data = try? JSONEncoder().encode(cfg) {
            try? data.write(to: libraryConfigURL, options: .atomic)
        }
    }

    // MARK: - Hidden comics (removed from the library but left on disk)

    static var hiddenConfigURL: URL { baseDir.appendingPathComponent("hidden.json") }

    /// Standardized paths the user removed from the library — filtered out of every scan so they
    /// stay gone even though their files remain in a scanned folder.
    static func loadHiddenPaths() -> Set<String> {
        guard let data = try? Data(contentsOf: hiddenConfigURL),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    static func saveHiddenPaths(_ paths: Set<String>) {
        ensureDirs()
        if let data = try? JSONEncoder().encode(Array(paths).sorted()) {
            try? data.write(to: hiddenConfigURL, options: .atomic)
        }
    }
}
