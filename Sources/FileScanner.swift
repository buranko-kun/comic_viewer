import Foundation

/// Filesystem helpers shared by the reader, source opener and local server.
enum FileScanner {
    static func scan(_ folder: URL) -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return sorted(urls.filter(SupportedTypes.isSupported).map(\.standardizedFileURL))
    }

    static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// All supported images anywhere under a directory, ordered by full path.
    static func scanRecursive(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        if let e = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let u as URL in e where SupportedTypes.isSupported(u) {
                out.append(u.standardizedFileURL)
            }
        }
        return out.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}
