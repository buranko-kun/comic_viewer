import SwiftUI
import Foundation

@MainActor
@Observable
final class CatalogAggregator {
    static let shared = CatalogAggregator()

    private(set) var loading = false
    private(set) var comics: [RemoteComic] = []
    private(set) var folders: [RemoteCatalog.ChildCatalog] = []
    private(set) var errors: [String] = []
    private(set) var loadedOnce = false

    func loadRoots() async {
        loading = true
        let sources = CatalogSourceStore.shared.sources
        let plugins = SourcePluginStore.shared.enabledPlugins

        var comicsBySource: [String: [RemoteComic]] = [:]
        var foldersBySource: [String: [RemoteCatalog.ChildCatalog]] = [:]
        var errs: [String] = []

        await withTaskGroup(of: (CatalogSource, Result<RemoteCatalog, Error>).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        return (source, .success(try await CatalogClient.catalog(at: source.url)))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }

            for await (source, result) in group {
                switch result {
                case .success(let catalog):
                    comicsBySource[source.id] = catalog.comics
                    foldersBySource[source.id] = catalog.childCatalogs
                case .failure(let error):
                    errs.append("(source.name): (error.localizedDescription)")
                }
            }
        }

        for plugin in plugins {
            do {
                let catalog = try await SourcePluginRuntime.shared.catalog(plugin: plugin)
                comicsBySource["plugin:(plugin.id)"] = catalog.comics
                foldersBySource["plugin:(plugin.id)"] = catalog.childCatalogs
            } catch {
                errs.append("(plugin.name): (error.localizedDescription)")
            }
        }

        comics = sources.flatMap { comicsBySource[$0.id] ?? [] }
            + plugins.flatMap { comicsBySource["plugin:($0.id)"] ?? [] }

        folders = sources.flatMap { foldersBySource[$0.id] ?? [] }
            + plugins.flatMap { foldersBySource["plugin:($0.id)"] ?? [] }

        errors = errs
        loading = false
        loadedOnce = true

        writeSkippedLog(for: comics)
    }

    static let skippedLogURL: URL = {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ComicViewer", isDirectory: true)
        return dir.appendingPathComponent("skipped-items.log")
    }()

    private func writeSkippedLog(for comics: [RemoteComic]) {
        let broken = comics.filter { !$0.hasMirrors }
        var lines = [
            "Catalog entries with no download links",
            "Generated: (ISO8601DateFormatter().string(from: Date()))",
            "Total: (broken.count) of (comics.count)",
            ""
        ]

        for comic in broken {
            lines.append("(comic.title)  [(comic.sourceName)]")
        }

        let url = Self.skippedLogURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try lines.joined(separator: "
").write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            errors.append("Couldn't write skipped-items log: (error.localizedDescription)")
        }
    }
}
