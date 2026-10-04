import Foundation

/// Creates a safe trimmed copy of a local chapter archive.
/// CBZ files are replaced only after a verified ZIP has been built, then the source is removed.
/// CBR files produce a sibling trimmed CBZ, then the source CBR is removed.
enum ArchiveChapterEditor {
    struct Result: Sendable {
        let archiveURL: URL
        let retainedOriginalURL: URL?
        let removedPageCount: Int
        let remainingPageCount: Int
    }

    enum EditError: LocalizedError {
        case unsupportedArchive
        case noPagesSelected
        case invalidEntryPath
        case couldNotExtract
        case missingPage(String)
        case noPagesRemain
        case couldNotBuildArchive
        case verificationFailed
        case couldNotReplaceOriginal

        var errorDescription: String? {
            switch self {
            case .unsupportedArchive:
                return "Only local CBZ and CBR archives can be trimmed."
            case .noPagesSelected:
                return "There are no earlier chapter pages to delete."
            case .invalidEntryPath:
                return "The archive contains an unsafe page path, so it was left unchanged."
            case .couldNotExtract:
                return "The archive could not be extracted. The original was left unchanged."
            case .missingPage(let name):
                return "Could not find \(name) in the extracted archive. The original was left unchanged."
            case .noPagesRemain:
                return "This operation would remove every page. The archive was left unchanged."
            case .couldNotBuildArchive:
                return "Could not build the trimmed archive. The original was left unchanged."
            case .verificationFailed:
                return "The trimmed archive did not pass verification. The original was left unchanged."
            case .couldNotReplaceOriginal:
                return "Could not replace the CBZ. The original has been restored if needed."
            }
        }
    }

    static func trim(
        archive: URL,
        removing entries: Set<String>
    ) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            try trimSynchronously(archive: archive, removing: entries)
        }.value
    }

    private static func trimSynchronously(
        archive: URL,
        removing requestedEntries: Set<String>
    ) throws -> Result {
        let fileType = archive.pathExtension.lowercased()
        guard fileType == "cbz" || fileType == "cbr" else {
            throw EditError.unsupportedArchive
        }
        guard !requestedEntries.isEmpty else { throw EditError.noPagesSelected }
        guard let listing = ArchiveExtractor.list(archive) else { throw EditError.couldNotExtract }

        let isImage: (String) -> Bool = {
            SupportedTypes.extensions.contains(($0 as NSString).pathExtension.lowercased())
        }
        let imageEntries = listing.entries.filter(isImage).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let imageSet = Set(imageEntries)
        guard requestedEntries.isSubset(of: imageSet) else {
            throw EditError.missingPage(requestedEntries.subtracting(imageSet).first ?? "page")
        }
        let remainingCount = imageEntries.count - requestedEntries.count
        guard remainingCount > 0 else { throw EditError.noPagesRemain }

        let fm = FileManager.default
        guard let extracted = ArchiveExtractor.extract(archive) else { throw EditError.couldNotExtract }
        defer { try? fm.removeItem(at: extracted) }
        let root = extracted.standardizedFileURL

        var removedIndices = Set<Int>()
        for (index, entry) in imageEntries.enumerated() where requestedEntries.contains(entry) {
            guard let file = safeURL(for: entry, under: root) else { throw EditError.invalidEntryPath }
            guard fm.fileExists(atPath: file.path) else { throw EditError.missingPage(entry) }
            try fm.removeItem(at: file)
            removedIndices.insert(index)
        }

        if let infoEntry = listing.entries.first(where: {
            ($0 as NSString).lastPathComponent.caseInsensitiveCompare(ComicInfo.fileName) == .orderedSame
        }), let infoURL = safeURL(for: infoEntry, under: root) {
            updateComicInfo(at: infoURL, removingImageIndices: removedIndices, pageCount: remainingCount)
        }

        guard let sevenz = ArchiveExtractor.sevenz else { throw EditError.couldNotBuildArchive }
        let staging = archive.deletingLastPathComponent()
            .appendingPathComponent(".ComicViewer-trim-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: staging) }

        guard run(sevenz, ["a", "-tzip", "-mx=0", "--", staging.path, "."], in: root),
              let verified = ArchiveExtractor.list(staging),
              verified.type.caseInsensitiveCompare("zip") == .orderedSame else {
            throw EditError.couldNotBuildArchive
        }
        let verifiedImages = verified.entries.filter(isImage)
        guard verifiedImages.count == remainingCount,
              requestedEntries.isDisjoint(with: Set(verifiedImages)) else {
            throw EditError.verificationFailed
        }

        if fileType == "cbr" {
            let destination = uniqueTrimmedCBZURL(for: archive)
            do { try fm.moveItem(at: staging, to: destination) }
            catch { throw EditError.couldNotReplaceOriginal }
            let retainedOriginalURL: URL?
            do {
                try fm.removeItem(at: archive)
                retainedOriginalURL = nil
            } catch {
                retainedOriginalURL = archive
            }
            return Result(
                archiveURL: destination,
                retainedOriginalURL: retainedOriginalURL,
                removedPageCount: requestedEntries.count,
                remainingPageCount: remainingCount
            )
        }

        let backup = uniqueBackupURL(for: archive)
        do {
            try fm.moveItem(at: archive, to: backup)
            try fm.moveItem(at: staging, to: archive)
        } catch {
            if !fm.fileExists(atPath: archive.path), fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: archive)
            }
            throw EditError.couldNotReplaceOriginal
        }
        let retainedOriginalURL: URL?
        do {
            try fm.removeItem(at: backup)
            retainedOriginalURL = nil
        } catch {
            retainedOriginalURL = backup
        }
        return Result(
            archiveURL: archive,
            retainedOriginalURL: retainedOriginalURL,
            removedPageCount: requestedEntries.count,
            remainingPageCount: remainingCount
        )
    }

    private static func safeURL(for entry: String, under root: URL) -> URL? {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let url = root.appendingPathComponent(entry).standardizedFileURL
        return url.path.hasPrefix(prefix) ? url : nil
    }

    private static func updateComicInfo(
        at url: URL,
        removingImageIndices removed: Set<Int>,
        pageCount: Int
    ) {
        guard let document = try? XMLDocument(contentsOf: url, options: [.nodePreserveAll]),
              let root = document.rootElement() else { return }

        let pageNodes = (try? root.nodes(forXPath: ".//Page"))?.compactMap { $0 as? XMLElement } ?? []
        for page in pageNodes {
            guard let attr = page.attribute(forName: "Image"),
                  let oldIndex = Int(attr.stringValue ?? "") else { continue }
            if removed.contains(oldIndex) {
                if let parent = page.parent as? XMLElement,
                   let siblings = parent.children,
                   let index = siblings.firstIndex(of: page) {
                    parent.removeChild(at: index)
                }
            } else {
                attr.stringValue = String(oldIndex - removed.filter { $0 < oldIndex }.count)
            }
        }
        root.elements(forName: "PageCount").first?.stringValue = String(pageCount)
        let data = document.xmlData(options: [.nodePreserveAll])
        try? data.write(to: url, options: .atomic)
    }

    private static func uniqueBackupURL(for archive: URL) -> URL {
        let first = archive.appendingPathExtension("backup")
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        for suffix in 2...999 {
            let candidate = archive.appendingPathExtension("backup-\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return archive.appendingPathExtension("backup-\(UUID().uuidString)")
    }

    private static func uniqueTrimmedCBZURL(for archive: URL) -> URL {
        let directory = archive.deletingLastPathComponent()
        let base = archive.deletingPathExtension().lastPathComponent
        for suffix in 1...999 {
            let label = suffix == 1 ? "trimmed" : "trimmed \(suffix)"
            let candidate = directory.appendingPathComponent("\(base) (\(label)).cbz")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(base) (trimmed \(UUID().uuidString)).cbz")
    }

    private static func run(_ tool: String, _ args: [String], in directory: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
