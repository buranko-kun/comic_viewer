import Foundation

/// Headless test: `ComicViewer --librarytest <root>` scans a library root and prints the
/// detected comics grouped by series, so leaf-folder + archive detection can be verified
/// without the GUI. Exits when done.
enum LibraryTest {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--librarytest"), i + 1 < args.count else { return }
        let root = URL(fileURLWithPath: args[i + 1]).standardizedFileURL

        let comics = LibraryModel.scanRoots([root])
        let bySeries = Dictionary(grouping: comics, by: \.series)
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

        print("root: \(root.path)")
        print("comics: \(comics.count)   series: \(bySeries.count)\n")
        for (series, list) in bySeries {
            print("• \(series)  (\(list.count))")
            for c in list.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
                let kind = c.isArchive ? "archive" : "\(c.pageCount)p"
                let prog = c.progress.map { $0.count > 0 ? "  ▸ p.\($0.page)/\($0.count)" : "  ▸ started" } ?? ""
                let chap = c.chapterCount > 0 ? "  ✦ \(c.chapterCount) ch" : ""
                print("    - \(c.title)  [\(kind)]\(chap)\(prog)")
            }
        }
        exit(0)
    }
}
