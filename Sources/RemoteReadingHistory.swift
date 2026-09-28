import Foundation

/// Stores reading state for streamed remote comics independently of any particular source.
/// Remote source plugins register an opened issue here so the Home screen can restore in-progress
/// reads without knowing which plugin provided them.
final class RemoteReadingHistory {
    static let shared = RemoteReadingHistory()

    struct ReadIssue: Codable {
        let key: String
        let series: String
        let title: String
        let cover: String?
        let pages: [String]
    }

    private(set) var issues: [ReadIssue] = []

    private var fileURL: URL {
        FileManager.default.urls(in: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ComicViewer/remote-reading-history.json")
    }

    init() {
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
            pages: (comic.remotePages ?? []).map(\.absoluteString)
        )
        issues.removeAll { $0.key == issue.key }
        issues.insert(issue, at: 0)
        if issues.count > 60 {
            issues.removeLast(issues.count - 60)
        }
        save()
    }

    /// Rebuild in-progress remote issues for the Home "Continue Reading" shelf.
    func continueComics() -> [Comic] {
        issues.compactMap { issue -> Comic? in
            guard let url = URL(string: issue.key),
                  let state = CentralStore.loadState(forKey: CentralStore.key(for: url)),
                  let count = state.pageCount,
                  count > 0,
                  let index = state.lastIndex else { return nil }

            let page = index + 1
            guard page >= 3, page < count else { return nil }

            let pages = issue.pages.compactMap(URL.init(string:))
            let cover = issue.cover.flatMap(URL.init(string:)) ?? pages.first

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
}
