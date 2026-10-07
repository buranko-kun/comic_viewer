import Foundation

/// Owns per-comic persistence for the reader: central state files, legacy migration, atomic writes
/// and debounced saves. The reader remains responsible for interpreting page keys and state fields.
@MainActor
final class ReaderStateStore {
    struct LoadResult {
        let state: ComicState?
        let migratedFromLegacy: Bool
    }

    private var stateURL: URL?
    private var legacyStateURLs: [URL] = []
    private var saveTask: Task<Void, Never>?
    private var pendingState: ComicState?

    /// Flush the previous comic before switching destinations, so rapid navigation is not lost.
    func configure(comicKey: String?, legacyStateURLs: [URL]) {
        flush()
        stateURL = comicKey.map { CentralStore.stateURL(for: $0) }
        self.legacyStateURLs = legacyStateURLs
    }

    func load() -> LoadResult {
        guard let stateURL else {
            return LoadResult(state: nil, migratedFromLegacy: false)
        }

        var data = try? Data(contentsOf: stateURL)
        var migrated = false

        if data == nil {
            for legacy in legacyStateURLs {
                if let legacyData = try? Data(contentsOf: legacy) {
                    data = legacyData
                    migrated = true
                    break
                }
            }
        }

        guard let data,
              let state = try? JSONDecoder().decode(ComicState.self, from: data)
        else {
            return LoadResult(state: nil, migratedFromLegacy: false)
        }

        return LoadResult(state: state, migratedFromLegacy: migrated)
    }

    func scheduleSave(_ state: ComicState) {
        saveTask?.cancel()
        pendingState = state
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled, let self else { return }
            self.save(state)
        }
    }

    func save(_ input: ComicState) {
        cancelScheduledSave()
        pendingState = nil
        var state = input
        state.lastReadAt = Date()
        guard let stateURL else { return }

        if state.chapters.isEmpty && state.lastPage == nil {
            try? FileManager.default.removeItem(at: stateURL)
            return
        }

        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    func removeLegacyStateFiles() {
        for legacy in legacyStateURLs {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    func flush() {
        cancelScheduledSave()
        if let pendingState { save(pendingState) }
    }

    func cancel() { flush() }

    private func cancelScheduledSave() {
        saveTask?.cancel()
        saveTask = nil
    }
}
