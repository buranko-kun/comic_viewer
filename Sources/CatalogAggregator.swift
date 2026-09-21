import SwiftUI
import Foundation

/// Queries every configured `CatalogSource` concurrently and merges their root catalogs into
/// one Online view — comics from all servers, plus each server's sub-catalogs as folders.
/// Per-source failures are surfaced without failing the whole load. Drilling into a folder is
/// handled by the view via `CatalogClient.catalog(at:)`.
@MainActor
@Observable
final class CatalogAggregator {
    static let shared = CatalogAggregator()

    private(set) var loading = false
    private(set) var comics: [RemoteComic] = []
    private(set) var folders: [RemoteCatalog.ChildCatalog] = []
    private(set) var errors: [String] = []
    private(set) var loadedOnce = false

    /// Fetch and merge every source's root catalog (preserving source order).
    func loadRoots() async {
        loading = true
        let sources = CatalogSourceStore.shared.sources
        var comicsBySource: [String: [RemoteComic]] = [:]
        var foldersBySource: [String: [RemoteCatalog.ChildCatalog]] = [:]
        var errs: [String] = []

        await withTaskGroup(of: (CatalogSource, Result<RemoteCatalog, Error>).self) { group in
            for source in sources {
                group.addTask {
                    do { return (source, .success(try await CatalogClient.catalog(at: source.url))) }
                    catch { return (source, .failure(error)) }
                }
            }
            for await (source, result) in group {
                switch result {
                case .success(let cat):
                    comicsBySource[source.id] = cat.comics
                    foldersBySource[source.id] = cat.childCatalogs
                case .failure(let error):
                    errs.append("\(source.name): \(error.localizedDescription)")
                }
            }
        }

        comics = sources.flatMap { comicsBySource[$0.id] ?? [] }
        folders = sources.flatMap { foldersBySource[$0.id] ?? [] }
        errors = errs
        loading = false
        loadedOnce = true

        writeSkippedLog(for: comics)
    }

    /// Where the skipped-items report is written.
    static let skippedLogURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ComicViewer", isDirectory: true)
        return dir.appendingPathComponent("skipped-items.log")
    }()

    /// Writes a report of entries that have no download links (still shown in the grid) so the
    /// user can fix them at the source later. These have no mirrors, so only titles are listed.
    private func writeSkippedLog(for comics: [RemoteComic]) {
        let broken = comics.filter { !$0.hasMirrors }
        var lines = [
            "Catalog entries with no download links",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "Total: \(broken.count) of \(comics.count)",
            ""
        ]
        for c in broken { lines.append("\(c.title)  [\(c.sourceName)]") }

        let url = Self.skippedLogURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errors.append("Couldn't write skipped-items log: \(error.localizedDescription)")
        }
    }
}
