import Foundation

/// Headless test: `ComicViewer --catalogtest <url>` fetches a catalog URL through the real
/// `CatalogClient`, normalizes it, and prints the comics/folders (with resolved cover/mirror
/// URLs and supported-format flags) so the fetch → normalize pipeline can be verified against a
/// live server without the GUI. Exits when done.
enum CatalogTest {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--catalogtest"), i + 1 < args.count,
              let url = CatalogSourceStore.makeURL(from: args[i + 1]) else { return }

        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let cat = try await CatalogClient.catalog(at: url)
                print("catalog: \(cat.name)   comics: \(cat.comics.count)   folders: \(cat.childCatalogs.count)\n")
                for f in cat.childCatalogs { print("  📁 \(f.name)  → \(f.url.absoluteString)") }
                for c in cat.comics {
                    let ok = c.isSupported ? "✓" : "✗(\(c.resolvedFormat ?? "?"))"
                    print("  \(ok) \(c.title)")
                    if let cover = c.coverURL { print("      cover: \(cover.absoluteString)") }
                    print("      mirrors: \(c.mirrors.map(\.absoluteString).joined(separator: ", "))")
                    if !c.metadata.isEmpty { print("      meta: \(c.metadata)") }
                }
            } catch {
                print("ERROR: \(error.localizedDescription)")
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 30)
        exit(0)
    }
}
