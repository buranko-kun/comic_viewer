import Foundation

/// Headless test: `ComicViewer --archivetest <archive>` extracts the archive and lists the
/// images the viewer would show (covers the nested-subfolder case via scanRecursive).
enum ArchiveTest {
    @MainActor
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--archivetest"), i + 1 < args.count else { return }
        let archive = URL(fileURLWithPath: args[i + 1])
        print("isArchive: \(ArchiveExtractor.isArchive(archive))")
        guard let dir = ArchiveExtractor.extract(archive) else {
            print("EXTRACT FAILED"); exit(2)
        }
        let images = AppModel.scanRecursive(dir)
        print("extracted → \(dir.lastPathComponent)")
        print("images: \(images.count)")
        for u in images.prefix(3) { print("  \(u.lastPathComponent)") }
        try? FileManager.default.removeItem(at: dir)
        print(images.isEmpty ? "FAIL" : "PASS")
        exit(0)
    }
}
