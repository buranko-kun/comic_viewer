import Foundation

/// Headless test: `ComicViewer --chaptertest <file>` opens the folder, sets a
/// couple of chapters, reloads in a fresh model to prove JSON persistence, then
/// exercises next/prev chapter jumps (including wrap). Cleans nothing — the caller
/// removes the .landscape-chapters.json afterwards.
enum ChapterTest {
    @MainActor
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--chaptertest"), i + 1 < args.count else { return }
        let file = URL(fileURLWithPath: args[i + 1])

        let m = AppModel()
        m.open(urls: [file])
        print("items: \(m.items.map(\.lastPathComponent))")

        m.first()
        print("toggle @\(m.index) (\(m.currentName ?? "")): \(m.toggleChapter())")
        m.first(); m.next(); m.next()
        print("toggle @\(m.index) (\(m.currentName ?? "")): \(m.toggleChapter())")
        print("chapters (this model): \(m.chapters.sorted())")

        // Fresh model → must load the same chapters from disk.
        let m2 = AppModel()
        m2.open(urls: [file])
        print("chapters (reloaded from JSON): \(m2.chapters.sorted())")

        m2.first()
        print("start @\(m2.index) (\(m2.currentName ?? ""))")
        print("nextChapter → \(m2.nextChapter()); now @\(m2.index) (\(m2.currentName ?? ""))")
        print("nextChapter → \(m2.nextChapter()); now @\(m2.index) (\(m2.currentName ?? "")) [wrap]")
        print("prevChapter → \(m2.prevChapter()); now @\(m2.index) (\(m2.currentName ?? ""))")
        exit(0)
    }
}
