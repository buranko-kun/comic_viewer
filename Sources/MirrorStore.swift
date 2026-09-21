import Foundation

/// Loads catalog mirror URLs on demand. The browse index (`catalog-index.json`) omits mirror URLs
/// to stay small and load fast; the real mirrors live in a sibling `catalog-mirrors.json`
/// (`{ "<page link>": ["url", …] }`, ~66 MB). That file is read and parsed **once, lazily** — the
/// first time a mirror is actually needed (a download started from the Online browser) — off the
/// main thread, then cached. Comics reached through Collections already carry their mirrors inline,
/// so they never touch this. Lookup is keyed by the comic's page link (`RemoteComic.pageURL`).
actor MirrorStore {
    static let shared = MirrorStore()

    private var map: [String: [String]]?
    private var loading: Task<[String: [String]], Never>?

    /// Mirror URL strings for a comic, by its page link. Empty if unknown or no mirrors file exists.
    func mirrors(forLink link: String?) async -> [String] {
        guard let link, !link.isEmpty else { return [] }
        return await ensureLoaded()[link] ?? []
    }

    private func ensureLoaded() async -> [String: [String]] {
        if let map { return map }
        if let loading { return await loading.value }

        let sources = await MainActor.run { CatalogSourceStore.shared.sources.map(\.url) }
        let task = Task.detached(priority: .userInitiated) { () -> [String: [String]] in
            for src in sources where src.isFileURL {
                let file = src.deletingLastPathComponent()
                    .appendingPathComponent("catalog-mirrors.json")
                if let data = try? Data(contentsOf: file) {
                    // The mirrors file is written encrypted (obfuscated links); decrypt it, or fall
                    // back to the raw bytes so a plaintext file still loads.
                    let json = LinkCipher.decryptCatalog(data) ?? data
                    if let dict = try? JSONDecoder().decode([String: [String]].self, from: json) {
                        return dict
                    }
                }
            }
            return [:]
        }
        loading = task
        let result = await task.value
        map = result
        loading = nil
        return result
    }
}
