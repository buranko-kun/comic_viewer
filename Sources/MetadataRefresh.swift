import Foundation
import Observation

/// Refreshes metadata already linked to a ComicVine volume ID. A refresh never guesses a match:
/// comics without a stored volume ID stay available for the existing manual search flow.
enum MetadataRefresh {
    enum RefreshError: LocalizedError {
        case noComicVineID

        var errorDescription: String? {
            switch self {
            case .noComicVineID:
                return "This comic is not linked to a ComicVine volume yet."
            }
        }
    }

    /// Refresh one comic using its stored ComicVine volume ID.
    @discardableResult
    static func refresh(_ comic: Comic) async throws -> ComicInfo {
        let url = comic.url
        let isArchive = comic.isArchive
        let existing = await Task.detached {
            ComicInfo.load(forComic: url, isArchive: isArchive)
        }.value

        guard let id = existing?.comicVineVolumeID else {
            throw RefreshError.noComicVineID
        }

        let updated = try await ComicVine.comicInfo(forVolume: id)
        guard updated.write(forComic: url, isArchive: isArchive) else {
            throw NSError(
                domain: "ComicViewer.MetadataRefresh",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't save ComicInfo.xml (check write permissions)."]
            )
        }
        return updated
    }
}

/// Observable state for the Settings → Library bulk refresh action.
@MainActor
@Observable
final class MetadataRefreshCoordinator {
    static let shared = MetadataRefreshCoordinator()

    private(set) var isRunning = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var refreshed = 0
    private(set) var skipped = 0
    private(set) var failed = 0
    private(set) var currentTitle: String?

    var summary: String {
        if isRunning {
            return "Refreshing \(completed) / \(total) · \(refreshed) updated"
        }
        if total == 0 { return "" }
        return "(refreshed) updated · (skipped) not linked · (failed) failed"
    }

    /// Refresh all local comics that already have a ComicVine volume ID.
    /// Comics without a stored ID are intentionally skipped rather than guessing a match.
    func refreshKnownMetadata() {
        guard !isRunning else { return }

        // The metadata load above is asynchronous, so start from the full local set and resolve
        // eligibility inside the worker. This also avoids blocking the settings window during archive reads.
        let local = LibraryModel.shared.comics.filter { !$0.isRemote }
        total = local.count
        completed = 0
        refreshed = 0
        skipped = 0
        failed = 0
        currentTitle = nil
        isRunning = true

        Task {
            for comic in local {
                if Task.isCancelled { break }
                currentTitle = comic.title

                let hasID = await Task.detached {
                    ComicInfo.load(forComic: comic.url, isArchive: comic.isArchive)?.comicVineVolumeID != nil
                }.value

                if hasID {
                    do {
                        _ = try await MetadataRefresh.refresh(comic)
                        refreshed += 1
                    } catch {
                        failed += 1
                    }
                } else {
                    skipped += 1
                }

                completed += 1
            }

            currentTitle = nil
            isRunning = false
            LibraryModel.shared.rescan()
        }

    }
}
