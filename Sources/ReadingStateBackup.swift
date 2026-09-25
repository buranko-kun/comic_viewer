import Foundation

/// Portable backup of the reader's per-comic state.
///
/// The backup contains no comic files. It stores the state currently kept in Application Support
/// plus the library roots that were configured at export time, allowing an import to remap entries
/// when the same library has moved to a different root on another Mac.
struct ReadingStateBackup: Codable {
    static let format = "ComicViewer Reading State"
    static let currentVersion = 1

    var format: String = ReadingStateBackup.format
    var version: Int = ReadingStateBackup.currentVersion
    var exportedAt: Date = Date()
    var libraryRoots: [String]
    var entries: [Entry]

    struct Entry: Codable {
        /// Canonical comic path at export time.
        var path: String
        /// Paths relative to each export-time library root that contained the comic.
        /// This is what makes a moved library root importable without losing page/chapter keys.
        var relativePaths: [String]
        var state: ComicState
    }

    enum BackupError: LocalizedError {
        case invalidFormat
        case unsupportedVersion(Int)
        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "This file is not a ComicViewer reading-state backup."
            case .unsupportedVersion(let version):
                return "This backup uses reading-state format version \(version), which this version of ComicViewer cannot import."
            }
        }
    }

    struct ImportPlan {
        struct Item {
            let entry: Entry
            let destinationPath: String
            let remapped: Bool
        }

        let items: [Item]
        let ambiguous: [Entry]
        let duplicateDestinations: Int

        var remappedCount: Int {
            items.filter { $0.remapped }.count
        }

        var unresolvedCount: Int {
            ambiguous.count
        }
    }

    struct ImportResult {
        let imported: Int
        let remapped: Int
        let skippedAmbiguous: Int

        var message: String {
            var parts = [
                "Imported \(imported) reading-state entr\(imported == 1 ? "y" : "ies")"
            ]
            if remapped > 0 {
                parts.append("\(remapped) remapped to the current library roots")
            }
            if skippedAmbiguous > 0 {
                parts.append("\(skippedAmbiguous) skipped because their paths matched multiple comics")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Build a backup from all readable central state files.
    static func makeExport() -> ReadingStateBackup {
        CentralStore.ensureDirs()

        let roots = CentralStore.loadLibraryFolders()
            .map(\.standardizedFileURL.path)
            .sorted()

        let files = ((try? FileManager.default.contentsOfDirectory(
            at: CentralStore.stateDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension.caseInsensitiveCompare("json") == .orderedSame }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var entries: [Entry] = []
        entries.reserveCapacity(files.count)

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let state = try? JSONDecoder().decode(ComicState.self, from: data),
                  let path = state.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty
            else {
                continue
            }

            let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
            let relatives = relativePaths(for: canonicalPath, roots: roots)

            entries.append(
                Entry(
                    path: canonicalPath,
                    relativePaths: relatives,
                    state: state
                )
            )
        }

        return ReadingStateBackup(
            format: Self.format,
            version: Self.currentVersion,
            exportedAt: Date(),
            libraryRoots: roots,
            entries: entries
        )
    }

    /// Encode with stable key ordering and human-readable formatting.
    static func encode(_ backup: ReadingStateBackup) throws -> Data {
        var encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    /// Decode and validate an exported backup.
    static func decode(_ data: Data) throws -> ReadingStateBackup {
        let backup = try JSONDecoder().decode(Self.self, from: data)

        guard backup.format == Self.format else {
            throw BackupError.invalidFormat
        }
        guard backup.version <= Self.currentVersion else {
            throw BackupError.unsupportedVersion(backup.version)
        }
        guard backup.entries.allSatisfy({
            !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw BackupError.invalidFormat
        }
        return backup
    }

    /// Prepare an import without writing anything. Exact existing paths win; otherwise a unique
    /// existing path under a current library root is selected from the stored relative paths.
    static func makeImportPlan(
        backup: ReadingStateBackup,
        currentLibraryRoots: [URL]
    ) -> ImportPlan {
        let roots = currentLibraryRoots.map(\.standardizedFileURL.path)
        var occupied = Set<String>()
        var items: [ImportPlan.Item] = []
        var ambiguous: [Entry] = []
        var duplicateDestinations = 0

        for entry in backup.entries {
            let original = URL(fileURLWithPath: entry.path).standardizedFileURL.path

            if FileManager.default.fileExists(atPath: original) {
                if occupied.insert(original).inserted {
                    items.append(.init(entry: entry, destinationPath: original, remapped: false))
                } else {
                    duplicateDestinations += 1
                }
                continue
            }

            var candidates = Set<String>()
            for relative in entry.relativePaths {
                for root in roots {
                    let rootURL = URL(fileURLWithPath: root).standardizedFileURL
                    let candidateURL = rootURL
                        .appendingPathComponent(relative)
                        .standardizedFileURL
                    let candidate = candidateURL.path
                    let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
                    guard candidate == rootURL.path || candidate.hasPrefix(rootPrefix) else { continue }
                    if FileManager.default.fileExists(atPath: candidate) {
                        candidates.insert(candidate)
                    }
                }
            }

            if candidates.count == 1, let destination = candidates.first {
                if occupied.insert(destination).inserted {
                    items.append(.init(entry: entry, destinationPath: destination, remapped: destination != original))
                } else {
                    duplicateDestinations += 1
                }
            } else if candidates.count > 1 {
                ambiguous.append(entry)
            } else {
                // Keep state for an offline/disconnected library too. A later scan of the original
                // path can pick it up, while visible-library moves are remapped above.
                if occupied.insert(original).inserted {
                    items.append(.init(entry: entry, destinationPath: original, remapped: false))
                } else {
                    duplicateDestinations += 1
                }
            }
        }

        return ImportPlan(
            items: items,
            ambiguous: ambiguous,
            duplicateDestinations: duplicateDestinations
        )
    }

    /// Apply an approved import plan, preserving the exported timestamp and all state fields.
    static func apply(_ plan: ImportPlan) -> ImportResult {
        CentralStore.ensureDirs()

        var imported = 0
        var remapped = 0

        for item in plan.items {
            var state = item.entry.state
            state.path = item.destinationPath

            guard let data = try? JSONEncoder().encode(state) else { continue }
            let key = CentralStore.key(for: URL(fileURLWithPath: item.destinationPath))
            let destination = CentralStore.stateURL(for: key)
            do {
                try data.write(to: destination, options: .atomic)
                imported += 1
                if item.remapped { remapped += 1 }
            } catch {
                continue
            }
        }

        return ImportResult(
            imported: imported,
            remapped: remapped,
            skippedAmbiguous: plan.ambiguous.count + plan.duplicateDestinations
        )
    }

    /// Relative comic paths captured against library roots at export time.
    static func relativePaths(for path: String, roots: [String]) -> [String] {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        var result: [String] = []

        for root in roots {
            let canonicalRoot = URL(fileURLWithPath: root).standardizedFileURL.path
            let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
            guard canonical.hasPrefix(prefix) else { continue }

            let relative = String(canonical.dropFirst(prefix.count))
            guard !relative.isEmpty, relative != "." else { continue }
            if !result.contains(relative) {
                result.append(relative)
            }
        }

        return result.sorted()
    }
}
