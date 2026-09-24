import Foundation

/// Headless test: `ComicViewer --metadatatest <folder>` parses the folder's ComicInfo.xml and
/// prints the metadata + any bookmark chapters (resolved to page filenames). Exits when done.
enum MetadataTest {
    @MainActor
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--metadatatest"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])

        guard let info = ComicInfo.load(fromFolder: dir) else {
            print("no ComicInfo.xml in \(dir.path)"); exit(1)
        }
        print("displayTitle: \(info.displayTitle ?? "-")")
        print("series:       \(info.series ?? "-")")
        print("number:       \(info.number ?? "-")   volume: \(info.volume ?? "-")   year: \(info.year ?? "-")")
        print("writer:       \(info.writer ?? "-")")
        print("pageCount:    \(info.pageCount.map(String.init) ?? "-")")
        print("summary:      \((info.summary ?? "-").prefix(120))…")
        print("bookmarks:    \(info.bookmarks.count)")

        if !info.bookmarks.isEmpty {
            let images = FileScanner.scan(dir)
            for b in info.bookmarks {
                let file = images.indices.contains(b.imageIndex)
                    ? images[b.imageIndex].lastPathComponent : "<index \(b.imageIndex) out of range>"
                print("   • [img \(b.imageIndex)] \(b.name)  ->  \(file)")
            }
        }
        exit(0)
    }
}
