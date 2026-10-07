import Foundation
import Observation

/// Stores reading state for streamed remote comics independently of any particular source.
/// Remote source plugins register an opened issue here so the Home screen can restore in-progress
/// reads without knowing which plugin provided them.
@Observable
final class RemoteReadingHistory {
    static let shared = RemoteReadingHistory()

    struct ReadIssue: Codable {
        let key: String
        let series: String
        let title: String
        let cover: String?
        let pages: [String]
        var coverResource: PluginResourceRequest? = nil
        var pageResources: [PluginResourceRequest]? = nil
    }

    private(set) var issues: [ReadIssue] = []
    private let fileURL: URL

    init(fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ComicViewer/remote-reading-history.json")) {
        self.fileURL = fileURL
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let rows = try? JSONDecoder().decode([ReadIssue].self, from: data) else { return }
        issues = rows
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(issues) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Record (or refresh) an opened remote issue, keeping the most-recent entries first.
    func record(_ comic: Comic) {
        guard comic.isRemote else { return }
        let issue = ReadIssue(
            key: comic.url.absoluteString,
            series: comic.series,
            title: comic.title,
            cover: comic.coverURL?.absoluteString,
            pages: (comic.remotePages ?? []).map(\.absoluteString),
            coverResource: comic.coverURL.map { PluginResourceRegistry.shared.request(for: $0) },
            pageResources: comic.remotePages?.map { PluginResourceRegistry.shared.request(for: $0) }
        )
        issues.removeAll { $0.key == issue.key }
        issues.insert(issue, at: 0)
        if issues.count > 60 {
            issues.removeLast(issues.count - 60)
        }
        save()
    }

    /// Reset entries disappear immediately; reading the issue again records it anew.
    func remove(_ url: URL) {
        issues.removeAll { $0.key == url.absoluteString }
        save()
    }

    /// Rebuild all remote issues with reading activity, including completed issues.
    func recentlyReadComics() -> [Comic] {
        issues.compactMap { issue -> Comic? in
            guard let url = URL(string: issue.key),
                  let state = CentralStore.loadState(forKey: CentralStore.key(for: url)),
                  let count = state.pageCount,
                  count > 0,
                  let index = state.lastIndex else { return nil }

            let page = index + 1
            guard page >= 1 else { return nil }

            for request in issue.pageResources ?? [] { PluginResourceRegistry.shared.register(request) }
            if let request = issue.coverResource { PluginResourceRegistry.shared.register(request) }
            let pages = issue.pageResources?.map { PluginResourceRegistry.shared.boundURL(for: $0) } ?? issue.pages.compactMap(URL.init(string:))
            let cover = issue.coverResource.map { PluginResourceRegistry.shared.boundURL(for: $0) } ?? issue.cover.flatMap(URL.init(string:)) ?? pages.first

            return Comic(
                url: url,
                series: issue.series,
                isArchive: false,
                coverURL: cover,
                pageCount: count,
                progress: ComicProgress(page: page, count: count),
                chapterCount: 0,
                metaTitle: issue.title,
                tooltip: nil,
                remotePages: pages
            )
        }
    }

    /// Apply the same progress threshold used for local Continue Reading entries.
    func continueComics() -> [Comic] {
        recentlyReadComics().filter {
            guard let progress = $0.progress else { return false }
            return progress.page >= 3 && progress.page < progress.count
        }
    }
}
