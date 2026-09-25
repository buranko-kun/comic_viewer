import Foundation
import Observation

/// A disk-usage snapshot for one library comic. Folder comics include their files, but nested
/// comic entries are excluded so the same bytes are never counted twice.
struct StorageComic: Identifiable, Hashable {
    let id: String
    let url: URL
    let title: String
    let series: String
    let bytes: Int64
    let isArchive: Bool

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Disk usage for the configured library. The total is computed from unique comic filesystem paths,
/// so overlapping library roots cannot double-count the same comic.
struct StorageReport {
    let comics: [StorageComic]
    let totalBytes: Int64
    let scannedAt: Date
    let freeBytes: Int64?
    let totalDiskBytes: Int64?

    var series: [String: Int64] {
        var result: [String: Int64] = [:]
        for comic in comics {
            result[comic.series, default: 0] += comic.bytes
        }
        return result
    }
}

/// Background disk scanner + destructive storage action for the Library → Storage utility.
@MainActor
@Observable
final class StorageUtility {
    static let shared = StorageUtility()

    private(set) var report: StorageReport?
    private(set) var isScanning = false
    private(set) var errorMessage: String?

    func scan() {
        guard !isScanning else { return }

        let comics = LibraryModel.shared.comics.filter { !$0.isRemote }
        let roots = LibraryModel.shared.folders
        isScanning = true
        errorMessage = nil

        Task {
            let snapshot = await Task.detached(priority: .utility) {
                StorageScanner.scan(comics: comics, roots: roots)
            }.value

            guard !Task.isCancelled else {
                isScanning = false
                return
            }

            report = snapshot
            isScanning = false
        }
    }

    /// Move a library comic and its generated archive metadata sidecar to the Trash.
    /// Reading state is removed after the filesystem move succeeds.
    @discardableResult
    func delete(_ item: StorageComic) -> Bool {
        let fm = FileManager.default

        do {
            try fm.trashItem(at: item.url, resultingItemURL: nil)

            if item.isArchive {
                let sidecar = ComicInfo.sidecarURL(forArchive: item.url)
                if fm.fileExists(atPath: sidecar.path) {
                    try? fm.trashItem(at: sidecar, resultingItemURL: nil)
                }
            }

            let key = CentralStore.key(for: item.url)
            try? fm.removeItem(at: CentralStore.stateURL(for: key))

            if let current = report {
                report = StorageReport(
                    comics: current.comics.filter { $0.id != item.id },
                    totalBytes: max(0, current.totalBytes - item.bytes),
                    scannedAt: current.scannedAt,
                    freeBytes: current.freeBytes,
                    totalDiskBytes: current.totalDiskBytes
                )
            }
            LibraryModel.shared.rescan()
            return true
        } catch {
            errorMessage = "Couldn't move \(item.title) to the Trash: \(error.localizedDescription)"
            return false
        }
    }
}

enum StorageScanner {
    static func scan(comics: [Comic], roots: [URL]) -> StorageReport {
        let uniqueComics = deduplicatedComics(comics)
        let comicPaths = Set(uniqueComics.map { $0.url.standardizedFileURL.path })

        let items = uniqueComics.map { comic in
            StorageComic(
                id: comic.id,
                url: comic.url.standardizedFileURL,
                title: comic.title,
                series: comic.series,
                bytes: bytes(for: comic, knownComicPaths: comicPaths),
                isArchive: comic.isArchive
            )
        }

        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        let capacity = filesystemCapacity(for: roots.first)

        return StorageReport(
            comics: items.sorted { $0.bytes > $1.bytes },
            totalBytes: total,
            scannedAt: Date(),
            freeBytes: capacity.free,
            totalDiskBytes: capacity.total
        )
    }

    static func deduplicatedComics(_ comics: [Comic]) -> [Comic] {
        var seen = Set<String>()
        var result: [Comic] = []
        for comic in comics {
            let path = comic.url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            result.append(comic)
        }
        return result
    }

    private static func bytes(for comic: Comic, knownComicPaths: Set<String>) -> Int64 {
        let url = comic.url.standardizedFileURL
        if comic.isArchive {
            var total = fileAllocatedSize(url)
            let sidecar = ComicInfo.sidecarURL(forArchive: url)
            total += fileAllocatedSize(sidecar)
            return total
        }

        return folderAllocatedSize(url, knownComicPaths: knownComicPaths)
    }

    /// Count files belonging to this folder comic, but stop at any nested comic folder. This keeps
    /// nested library entries from charging their bytes to both the parent and child.
    private static func folderAllocatedSize(_ folder: URL, knownComicPaths: Set<String>) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        while let next = enumerator.nextObject() as? URL {
            let path = next.standardizedFileURL.path

            if next != folder,
               knownComicPaths.contains(path),
               path != folder.path {
                enumerator.skipDescendants()
                continue
            }

            if (try? next.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                if (try? next.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try? next.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .fileAllocatedSizeKey]
            )
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileAllocatedSize ?? 0)
        }

        return total
    }

    private static func fileAllocatedSize(_ url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return Int64((try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0)
    }

    private static func filesystemCapacity(for root: URL?) -> (free: Int64?, total: Int64?) {
        guard let root else { return (nil, nil) }

        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: root.path)
        let free = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        let total = (attributes?[.systemSize] as? NSNumber)?.int64Value
        return (free, total)
    }
}
