import SwiftUI
import AppKit

/// The Online section: switches between configured catalog sources in one browsable view —
/// covers, titles, descriptions, metadata, and mirror downloads — and lets you drill into a
/// source's sub-catalogs (folders). Downloads land in the local library. Styled to match the
/// library (black bars, white text, red accents). Keeps its own folder back stack; the visible
/// back control pops it, then returns to the library.
struct BrowseView: View {
    @Environment(AppRouter.self) private var router
    private let sources = CatalogSourceStore.shared
    private let plugins = SourcePluginStore.shared
    private let aggregator = CatalogAggregator.shared

    /// Persistent Online state (search, drilled folders, sort/filter, scroll window + anchor). Lives
    /// in a singleton so leaving Online for the Library and coming back restores where you were —
    /// same search, same comics, same scroll position. `RootView` recreates this view on every route
    /// change, so anything that must survive that can't be plain `@State`.
    @State private var browseState = BrowseState.shared
    @State private var loadingChild = false
    @State private var childError: String?
    @State private var recoveryPlugin: SourcePlugin?
    @State private var sessionRecovery = SourceSessionRecovery()
    @State private var childRecoveryPlugin: SourcePlugin?
    @State private var childTask: Task<Void, Never>?
    @State private var childGeneration = UUID()
    @State private var retryChild: (() -> Void)?
    /// Pending debounce; cancelled and restarted on each keystroke.
    @State private var searchDebounce: Task<Void, Never>?
    /// True while a debounce is pending or a background filter is running (drives the "Searching…"
    /// feedback so the grid never just freezes).
    @State private var isFiltering = false
    @State private var keyMonitor = KeyMonitor()
    /// Multi-select mode: tapping toggles selection instead of opening the page.
    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []
    /// Memoizes the sorted list + letter index so the 18k-comic grid isn't re-sorted per render.
    @State private var displayCache = DisplayCache()
    @State private var shelf = RandomShelf.online
    static let pageSize = 400
    // Set when the user picks "New Collection…" from a card, to present the naming sheet.
    @State private var pendingNewCollectionItem: CollectionItem?
    // Presents the Downloads queue panel.
    @State private var showDownloads = false
    private let downloadManager = DownloadManager.shared

    private struct CatalogOption: Identifiable {
        let id: String
        let name: String
    }
    private var catalogOptions: [CatalogOption] {
        sources.sources.map { CatalogOption(id: $0.id, name: $0.name) }
            + plugins.enabledPlugins.map { CatalogOption(id: "plugin:" + $0.id, name: $0.name) }
    }
    private var selectedCatalog: CatalogOption? {
        let key = browseState.selectedSourceKey
            ?? browseState.stack.first?.sourceID.map { "plugin:" + $0 }
        return catalogOptions.first { $0.id == key } ?? catalogOptions.first
    }
    private var rootCatalog: RemoteCatalog? {
        selectedCatalog.flatMap { aggregator.catalog(forSourceKey: $0.id) }
    }
    private var levelComics: [RemoteComic] { browseState.stack.last?.comics ?? rootCatalog?.comics ?? [] }
    private var allLevelFolders: [RemoteCatalog.ChildCatalog] { browseState.stack.last?.childCatalogs ?? rootCatalog?.childCatalogs ?? [] }
    private func isPagination(_ folder: RemoteCatalog.ChildCatalog) -> Bool {
        folder.name.lowercased().hasPrefix("next page")
    }
    private var levelFolders: [RemoteCatalog.ChildCatalog] { allLevelFolders.filter { !isPagination($0) } }
    private var nextPage: RemoteCatalog.ChildCatalog? { allLevelFolders.first(where: isPagination) }
    private var sourceFailures: [SourceFailure] { aggregator.sourceFailures.filter { $0.id == selectedCatalog?.id } }
    private var showingCachedSource: Bool { selectedCatalog.map { aggregator.cachedSources.contains($0.id) } ?? false }
    private var levelTitle: String { browseState.stack.last?.name ?? "Online" }

    /// "1000 comics · 22 without mirror" — reflects what's currently shown (respects search).
    /// In select mode, shows how many are selected instead.
    private var countSummary: String {
        if selecting { return "\(selectedIDs.count) selected · tap covers to choose" }
        if isFiltering { return "Searching…" }
        if shuffling { return "Random \(min(200, filteredComics.count)) of \(filteredComics.count)" }
        let shown = filteredComics.count
        let noun = shown == 1 ? "comic" : "comics"
        if browseState.mustReadOnly { return "\(shown) must-read \(noun)" }
        let noMirror = filteredComics.lazy.filter { !$0.hasMirrors && !$0.opensCatalog && !$0.canRead }.count
        return "\(shown) \(noun) · \(noMirror) without mirror"
    }

    /// A key that changes whenever the displayed set changes (level, search, filter, sort) —
    /// used to memoize sorting and to reset the scroll window.
    private var displayToken: String {
        "\(levelKey)|\(aggregator.revision)|\(browseState.revision)|\(browseState.activeQuery)|\(browseState.mustReadOnly)|\(browseState.sortMode.rawValue)"
    }

    /// Identifies the current browse level (home or a drilled-in folder).
    private var levelKey: String {
        "\(selectedCatalog?.id ?? "")|\(browseState.stack.count)|\(browseState.stack.last?.sourceURL.absoluteString ?? "home")"
    }

    /// Re-run the background filter whenever the level, must-read toggle, or debounced query change.
    private var searchFilterToken: String { "\(levelKey)|\(aggregator.revision)|\(browseState.revision)|\(browseState.mustReadOnly)|\(browseState.activeQuery)" }

    /// The base set for the grid, then sorted + letter-indexed (memoized). The expensive text
    /// filter runs off the main thread (see `runSearchFilter`) and lands in `searchResults`; the
    /// cheap must-read Bool scan stays here.
    private var display: DisplayResult {
        if !browseState.activeQuery.isEmpty {
            // Search results arrive pre-ranked by relevance (see runSearchFilter); keep that order
            // and drop the A–Z rail, which only makes sense for an alphabetical list.
            return DisplayResult(comics: browseState.searchResults ?? [], letters: [])
        }
        let base = browseState.mustReadOnly ? levelComics.filter(\.mustRead) : levelComics
        return displayCache.compute(base: base, sort: browseState.sortMode, token: displayToken)
    }

    private var filteredComics: [RemoteComic] { display.comics }

    var body: some View {
        @Bindable var browseState = browseState
        return ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar.zIndex(2)
                Divider().overlay(.white.opacity(0.12))
                content
                    .id(levelKey)
                    .transition(.asymmetric(insertion: .move(edge: .leading),
                                            removal: .move(edge: .trailing)))
                    .clipped()
            }
        }
        .tint(.white)
        .sheet(item: $recoveryPlugin, onDismiss: { sessionRecovery.browserClosed() }) {
            SourcePluginSessionSheet(plugin: $0)
        }
        .sheet(item: $pendingNewCollectionItem) { NewCollectionSheet(item: $0) }
        .onAppear {
            if browseState.selectedSourceKey == nil { browseState.selectedSourceKey = selectedCatalog?.id }
            else if browseState.selectedSourceKey != selectedCatalog?.id { selectCatalog(selectedCatalog?.id) }
            keyMonitor.start(key: handleKey)
            if !aggregator.loadedOnce { Task { await aggregator.loadRoots() } }
        }
        .onDisappear { keyMonitor.stop(); searchDebounce?.cancel(); cancelChild(); sessionRecovery.cancel() }
        .onChange(of: catalogOptions.map(\.id)) { _, _ in
            if browseState.selectedSourceKey != selectedCatalog?.id { selectCatalog(selectedCatalog?.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browseBack)) { _ in back() }
        .onChange(of: browseState.invalidationRevision) { _, _ in cancelChild(); childError = nil }
        // Debounce typing: the field updates instantly, but filtering waits until you pause so a
        // large catalog isn't rescanned per keystroke. Clearing the field applies immediately.
        .onChange(of: browseState.searchText) { _, newValue in
            searchDebounce?.cancel()
            let q = newValue.trimmingCharacters(in: .whitespaces)
            if q == browseState.activeQuery, browseState.searchResults != nil {
                isFiltering = false
                return
            }
            if q.isEmpty {
                browseState.activeQuery = ""; browseState.searchResults = nil
                browseState.resultsToken = ""; isFiltering = false
                return
            }
            isFiltering = true    // immediate feedback while we wait + filter
            searchDebounce = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                browseState.activeQuery = q   // triggers the filter task below
            }
        }
        // Run the (potentially 70k-item) text filter off the main thread; SwiftUI cancels the
        // previous run when the query/level/toggle changes, so only the latest search lands. On
        // re-entering Online, skip the recompute when we already hold fresh results for this query.
        .task(id: searchFilterToken) {
            let token = searchFilterToken
            guard !browseState.activeQuery.isEmpty else {
                browseState.searchResults = nil; browseState.resultsToken = ""; isFiltering = false; return
            }
            if browseState.resultsToken == token, browseState.searchResults != nil { isFiltering = false; return }
            isFiltering = true
            let matches = await Self.runSearchFilter(levelComics, query: browseState.activeQuery,
                                                     mustReadOnly: browseState.mustReadOnly)
            if Task.isCancelled { return }
            browseState.searchResults = matches
            browseState.resultsToken = token
            isFiltering = false
        }
    }

    /// Filters the catalog for `query` on a background thread, then ranks the matches by relevance
    /// so the strongest title hits come first (see `relevance`). Searching "thor" puts every comic
    /// with *thor* as a word ("Thor", "The Mighty Thor") above ones that merely contain the letters
    /// ("Authority"). Matching uses `.caseInsensitive` range checks (not the locale-aware variant,
    /// which is far slower over tens of thousands of items) across title, series, description, and
    /// metadata. Must-read is folded in here so the caller gets a ready-to-display set.
    private static func runSearchFilter(_ comics: [RemoteComic], query: String,
                                        mustReadOnly: Bool) async -> [RemoteComic] {
        await Task.detached(priority: .userInitiated) {
            // Title/series match is separator-insensitive (shared `SearchRank`), so "avengers
            // armageddon" finds "Avengers: Armageddon". Description/metadata stay a raw substring.
            let nq = SearchRank.normalize(query)
            guard !nq.isEmpty else { return [] }
            let matches = comics.filter { c in
                if mustReadOnly && !c.mustRead { return false }
                if SearchRank.matches(c.title, normalizedQuery: nq) { return true }
                if let s = c.series, SearchRank.matches(s, normalizedQuery: nq) { return true }
                if let d = c.description, d.range(of: query, options: .caseInsensitive) != nil { return true }
                return c.metadata.values.contains { $0.range(of: query, options: .caseInsensitive) != nil }
            }
            // Rank matches by relevance, then shortest title, then alphabetically. Scoring runs
            // over the (already small) matched set, so it's cheap even off a 70k-item catalog.
            return matches
                .map { (comic: $0, score: Self.relevance($0, nq: nq)) }
                .sorted { a, b in
                    if a.score != b.score { return a.score > b.score }
                    if a.comic.title.count != b.comic.title.count { return a.comic.title.count < b.comic.title.count }
                    return a.comic.title.localizedStandardCompare(b.comic.title) == .orderedAscending
                }
                .map(\.comic)
        }.value
    }

    /// Relevance for a matched comic against the already-normalized query. Scores the title with the
    /// shared `SearchRank`; a series-only match ranks just above a description/metadata-only one.
    private nonisolated static func relevance(_ c: RemoteComic, nq: String) -> Int {
        let s = SearchRank.score(c.title, normalizedQuery: nq)
        if s > 10 { return s }
        if let series = c.series, SearchRank.score(series, normalizedQuery: nq) >= 60 { return 20 }
        return 10
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if sources.sources.isEmpty && plugins.enabledPlugins.isEmpty {
            emptyNoSources
        } else if loadingChild {
            centered {
                VStack { ProgressView().controlSize(.large); Button("Cancel") { cancelChild() } }
            }
        } else if browseState.stack.isEmpty && selectedCatalog.map({ aggregator.isLoadingSource($0.id) }) == true && levelComics.isEmpty && levelFolders.isEmpty {
            centered { ProgressView().controlSize(.large) }
        } else if let childError {
            errorView(childError) { self.childError = nil; retryChild?() }
        } else {
            grid
        }
    }

    private var emptyNoSources: some View {
        centered {
            VStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.plus").font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.5))
                Text("No online sources yet").font(.title2.bold())
                Text("Add a catalog URL or install a source plugin in Settings.")
                    .foregroundStyle(.white.opacity(0.6))
                SettingsLink { Label("Open Settings", systemImage: "gearshape") }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
            .padding(40)
        }
    }

    /// Random landing applies only at the home level with no search / must-read / select mode.
    private var canShuffle: Bool {
        browseState.stack.isEmpty && browseState.activeQuery.isEmpty
            && !browseState.mustReadOnly && !selecting
    }
    private var shuffling: Bool { canShuffle && shelf.active }

    private var grid: some View {
        @Bindable var bs = browseState
        let d = display
        let items = shuffling ? shelf.sample(d.comics) : d.comics
        return WindowedCoverGrid(
            items: items,
            letters: d.letters,
            windowStart: $bs.windowStart,
            windowCount: $bs.windowCount,
            resetKey: displayToken,
            pageSize: Self.pageSize,
            showRail: !selecting,
            restoreID: shuffling ? nil : browseState.anchorID,
            onActiveIndex: { idx in
                // Remember the top-visible comic (so returning to Online lands here) and warm the
                // next ~12 rows of covers ahead. In shuffle mode the order is random, so skip the
                // A–Z anchor and just prefetch.
                if !shuffling, d.comics.indices.contains(idx) { browseState.anchorID = d.comics[idx].id }
                let base = max(0, idx - 8), end = min(items.count, idx + 60)
                guard base < end, idx >= 0, idx < end else { return }
                let ordered = Array(items[idx..<end]) + Array(items[base..<idx])
                let urls = Array(ordered.compactMap { $0.coverRequest.map { PluginResourceRegistry.shared.boundURL(for: $0) } })
                Task { await RemoteImageCache.shared.setPrefetchTarget(urls, maxPixel: 320) }
            },
            onReset: { browseState.anchorID = nil },
            shuffleActive: shuffling,
            onShuffle: canShuffle
                ? { shelf.reshuffle(); bs.windowStart = 0; bs.windowCount = Self.pageSize } : nil,
            onBeforeLetterJump: { shelf.active = false },
            header: {
                if browseState.stack.isEmpty, let selectedCatalog,
                   aggregator.isLoadingSource(selectedCatalog.id), !levelComics.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading more comics… \(levelComics.count) loaded")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, GridStyle.hPadding).padding(.top, 12)
                }
                if (!sourceFailures.isEmpty || showingCachedSource) && browseState.stack.isEmpty { errorBanner }
                if d.comics.isEmpty && levelFolders.isEmpty {
                    if isFiltering {
                        ProgressView().controlSize(.small).padding(.top, 60)
                    } else {
                        Text(browseState.searchText.isEmpty ? "Nothing here." : "No matches.")
                            .foregroundStyle(.white.opacity(0.5)).padding(.top, 60)
                    }
                }
            },
            leading: {
                ForEach(levelFolders) { folder in
                    FolderCard(name: folder.name) { open(folder) }
                }
            },
            cell: { comic in
                ComicCard(comic: comic, selecting: selecting,
                          selected: selectedIDs.contains(comic.id),
                          onTap: { tapComic(comic) })
                .contextMenu {
                    AddToCollectionMenu(item: CollectionItem(remote: comic),
                                        pendingNew: $pendingNewCollectionItem)
                }
            }
        )
    }

    private var errorBanner: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sourceFailures) { failure in
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(failure.name): \(failure.summary)").font(.caption.bold())
                        Text(failure.detail).font(.caption2).textSelection(.enabled)
                    }
                    Spacer()
                    if failure.id.hasPrefix("plugin:"), let plugin = plugins.plugin(id: String(failure.id.dropFirst(7))) {
                        Button("Open source browser") {
                            recover(plugin) { Task { await aggregator.retrySource(failure.id) } }
                        }
                    } else if let url = URL(string: failure.id) {
                        Button("Retry") { Task { await aggregator.retrySource(failure.id) } }
                            .disabled(aggregator.isLoadingSource(failure.id))
                        Button("Open source") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            if showingCachedSource { Text(aggregator.loading ? "Showing saved catalog while it refreshes." : "Showing saved catalog. The source could not refresh.").font(.caption2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(sourceFailures.isEmpty ? Color.white.opacity(0.08) : Color.red.opacity(0.25))
        .padding(.horizontal, 30).padding(.top, 12)
    }

    private func centered<V: View>(@ViewBuilder _ v: () -> V) -> some View {
        v().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ text: String, retry: @escaping () -> Void) -> some View {
        let message = SourceErrorPresentation(text)
        return centered {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                Text(message.title).font(.title2.weight(.semibold))
                Text(message.detail).font(.caption).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary).textSelection(.enabled)
                if let plugin = childRecoveryPlugin {
                    Button("Open source browser") { recover(plugin, retry: retry) }
                    Text("Complete any verification, then close the browser to reconnect.")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Button("Try again", action: retry).tint(.red) }
            }.padding(40)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        @Bindable var browseState = browseState
        return SectionToolbar {
            HStack(spacing: 10) {
                if !browseState.stack.isEmpty {
                    Button { back() } label: { Image(systemName: "chevron.left") }.help("Back to previous catalog")
                }
                SectionHeading(
                    title: browseState.stack.isEmpty ? "Online" : levelTitle,
                    detail: countSummary
                )
            }
        } search: {
            NavigationSearchField(prompt: "Search this catalog", text: $browseState.searchText, onlineSuggestions: true, suggestionTitles: levelComics.map(\.title))
        } actions: {
            HStack(spacing: 12) {
                if let selectedCatalog {
                    Menu {
                        ForEach(catalogOptions) { option in
                            Button { selectCatalog(option.id) } label: {
                                if option.id == selectedCatalog.id { Label(option.name, systemImage: "checkmark") }
                                else { Text(option.name) }
                            }
                        }
                    } label: {
                        Text(selectedCatalog.name).lineLimit(1).truncationMode(.tail)
                    }
                    .help("Choose online catalog")
                }
                if let nextPage {
                    Button { open(nextPage) } label: { Label("Next page", systemImage: "chevron.right") }
                        .disabled(loadingChild).help("Next page")
                }
                if selecting {
                    Button("Open \(selectedIDs.count)") { openSelected() }.disabled(selectedIDs.isEmpty)
                    Button("Done") { exitSelection() }
                } else {
                    Menu {
                        Toggle("Must-read only", isOn: $browseState.mustReadOnly)
                        Picker("Sort", selection: $browseState.sortMode) {
                            Text("Title A–Z").tag(SortMode.title)
                            Text("Year (newest)").tag(SortMode.yearDesc)
                        }
                        Divider()
                        Button("Select comics") { selecting = true }
                        Button("Search all loaded catalogs") { router.showOnlineSearch(query: browseState.searchText) }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .menuIndicator(.hidden).help("Filter, sort, and selection")
                    Button {
                        if let current = browseState.stack.last { reopen(current) }
                        else if let selectedCatalog { Task { await aggregator.retrySource(selectedCatalog.id) } }
                    } label: { Image(systemName: "arrow.clockwise") }.help("Refresh catalog")
                }
            }
        }
    }

    // MARK: Actions

    private func recover(_ plugin: SourcePlugin, retry: @escaping () -> Void) {
        sessionRecovery.prepare(retry)
        recoveryPlugin = plugin
    }

    private func selectCatalog(_ key: String?) {
        guard browseState.selectedSourceKey != key else { return }
        cancelChild(); searchDebounce?.cancel()
        sessionRecovery.cancel()
        childError = nil; childRecoveryPlugin = nil; retryChild = nil
        exitSelection()
        browseState.selectedSourceKey = key
        browseState.resetNavigation()
        browseState.revision += 1
    }

    private func cancelChild() {
        childTask?.cancel()
        childTask = nil
        childGeneration = UUID()
        loadingChild = false
    }

    private func runChild(retry: @escaping () -> Void,
                          operation: @escaping @MainActor () async throws -> Void) {
        cancelChild()
        let generation = childGeneration
        retryChild = retry
        childError = nil
        loadingChild = true
        childTask = Task { @MainActor in
            do {
                try await operation()
            } catch {
                guard !Task.isCancelled, childGeneration == generation else { return }
                childError = error.localizedDescription
            }
            guard childGeneration == generation else { return }
            loadingChild = false
            childTask = nil
        }
    }

    private func open(_ folder: RemoteCatalog.ChildCatalog) {
        childRecoveryPlugin = folder.sourceID.flatMap { plugins.plugin(id: $0) }
        runChild(retry: { open(folder) }) {
            let catalog: RemoteCatalog
            if let sourceID = folder.sourceID, let plugin = plugins.plugin(id: sourceID) {
                catalog = try await SourcePluginRuntime.shared.catalog(plugin: plugin, at: folder.url)
            } else {
                catalog = try await CatalogClient.catalog(at: folder.url)
            }
            try Task.checkCancellation()
            browseState.push(catalog)
        }
    }

    private func reopen(_ cat: RemoteCatalog) {
        childRecoveryPlugin = cat.sourceID.flatMap { plugins.plugin(id: $0) }
        runChild(retry: { reopen(cat) }) {
            let catalog: RemoteCatalog
            if let sourceID = cat.sourceID, let plugin = plugins.plugin(id: sourceID) {
                catalog = try await SourcePluginRuntime.shared.catalog(plugin: plugin, at: cat.sourceURL, refresh: true)
            } else {
                catalog = try await CatalogClient.catalog(at: cat.sourceURL)
            }
            try Task.checkCancellation()
            guard let last = browseState.stack.indices.last,
                  browseState.stack[last].sourceURL == cat.sourceURL else { return }
            browseState.stack[last] = catalog
            browseState.revision += 1
        }
    }

    private func back() {
        sessionRecovery.cancel()
        cancelChild(); childError = nil
        if selecting { exitSelection(); return }
        router.escapeBack()
    }

    /// Tap a remote card. Plugins can turn cards into sub-catalogs or stream their page images
    /// directly into the reader; ordinary catalogs keep the existing browser-open behavior.
    private func tapComic(_ comic: RemoteComic) {
        OnlineSearchHistory.shared.record(browseState.searchText)
        if selecting {
            if selectedIDs.contains(comic.id) { selectedIDs.remove(comic.id) }
            else { selectedIDs.insert(comic.id) }
            return
        }

        guard let url = comic.pageURL else { return }

        guard let sourceID = comic.sourceID,
              let plugin = plugins.plugin(id: sourceID) else {
            NSWorkspace.shared.open(url)
            return
        }

        if comic.opensCatalog {
            openPluginCatalog(plugin, at: url)
        } else if comic.canRead {
            openPluginComic(plugin, comic: comic)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func openPluginCatalog(_ plugin: SourcePlugin, at url: URL) {
        open(RemoteCatalog.ChildCatalog(name: plugin.name, url: url, sourceID: plugin.id))
    }

    private func openPluginComic(_ plugin: SourcePlugin, comic: RemoteComic) {
        childRecoveryPlugin = plugin
        runChild(retry: { openPluginComic(plugin, comic: comic) }) {
            try await PluginComicOpener.open(comic, router: router)
        }
    }

    /// Open every selected comic's source page in the browser.
    private func openSelected() {
        for url in filteredComics.filter({ selectedIDs.contains($0.id) }).compactMap(\.pageURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func exitSelection() { selecting = false; selectedIDs = [] }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard !e.modifierFlags.contains(.command), e.keyCode == 53, NSApp.modalWindow == nil
        else { return false }
        back()
        return true
    }
}

// MARK: - Persistent Online state

/// The Online section's state that must outlive `BrowseView` (which `RootView` recreates on every
/// route change). Holding it in a singleton is what lets you leave for the Library and come back to
/// the same search, the same comics, and the same scroll position.
@MainActor
@Observable
final class BrowseState {
    static let shared = BrowseState()

    var selectedSourceKey: String?

    /// Folders drilled into. Empty = the selected catalogue's root.
    var stack: [RemoteCatalog] = []
    var returnToSearch = false
    var returnRoute: AppRouter.Route?
    private var parentViews: [Position] = []
    private var externalBackup: (stack: [RemoteCatalog], parents: [Position], position: Position)?

    private struct Position {
        let source: String?
        let search: String
        let query: String
        let results: [RemoteComic]?
        let token: String
        let start: Int
        let count: Int
        let anchor: String?
        let sort: SortMode
        let mustRead: Bool
        let revision: Int
    }
    private var position: Position {
        Position(source: selectedSourceKey, search: searchText, query: activeQuery,
                 results: searchResults, token: resultsToken, start: windowStart, count: windowCount,
                 anchor: anchorID, sort: sortMode, mustRead: mustReadOnly, revision: revision)
    }
    private func restore(_ saved: Position) {
        selectedSourceKey = saved.source; searchText = saved.search; activeQuery = saved.query
        searchResults = saved.results; resultsToken = saved.token
        windowStart = saved.start; windowCount = saved.count; anchorID = saved.anchor
        sortMode = saved.sort; mustReadOnly = saved.mustRead; revision = saved.revision
    }
    func push(_ catalog: RemoteCatalog) {
        parentViews.append(position)
        stack.append(catalog)
        clearSearch(); resetScroll(); revision += 1
    }
    func beginExternal(_ catalog: RemoteCatalog, returningTo route: AppRouter.Route) {
        externalBackup = (stack, parentViews, position)
        returnRoute = route
        returnToSearch = false
        stack = [catalog]; parentViews = []
        if let source = catalog.sourceID { selectedSourceKey = "plugin:" + source }
        clearSearch(); resetScroll(); revision += 1
    }
    @discardableResult
    func pop() -> AppRouter.Route? {
        guard !stack.isEmpty else { return nil }
        stack.removeLast()
        if stack.isEmpty, let destination = returnRoute {
            if let saved = externalBackup {
                stack = saved.stack; parentViews = saved.parents; restore(saved.position)
            }
            returnRoute = nil; externalBackup = nil
            return destination
        }
        if let saved = parentViews.popLast() { restore(saved) }
        else { clearSearch(); resetScroll(); revision += 1 }
        return nil
    }
    func resetNavigation() {
        stack = []; parentViews = []; externalBackup = nil; returnRoute = nil; returnToSearch = false
        clearSearch(); resetScroll()
    }
    var revision = 0
    var invalidationRevision = 0

    func invalidatePlugin(_ id: String) {
        if let first = stack.firstIndex(where: { $0.sourceID == id }) {
            stack.removeSubrange(first...)
            parentViews = Array(parentViews.prefix(first))
            resetScroll()
        }
        searchResults = nil; resultsToken = ""
        revision += 1
        invalidationRevision += 1
    }

    /// What the user is typing — bound to the field so text appears instantly.
    var searchText = ""
    /// The debounced query actually used for filtering (updated ~250 ms after typing stops).
    var activeQuery = ""
    /// The off-main filter result for `activeQuery`; nil when no search is active.
    var searchResults: [RemoteComic]?
    /// The filter token `searchResults` was computed for, so a re-entry can skip recomputing.
    var resultsToken = ""

    /// When on, only curated "must read" essentials are shown.
    var mustReadOnly = false
    /// Sort order for the grid; drives the A–Z jump bar (letters only make sense by title).
    var sortMode: SortMode = .title

    /// The rendered window into the sorted list: [windowStart, windowStart+windowCount).
    var windowStart = 0
    var windowCount = BrowseView.pageSize
    /// The id of the top-visible comic, remembered so the scroll position can be restored.
    var anchorID: String?

    func clearSearch() {
        searchText = ""; activeQuery = ""; searchResults = nil; resultsToken = ""
    }

    func resetScroll() {
        windowStart = 0; windowCount = BrowseView.pageSize; anchorID = nil
    }
}

// MARK: - Cards

/// A sub-catalog folder to drill into.
private struct FolderCard: View {
    let name: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverTile {
                Image(systemName: "folder.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.6))
            }
            Text(TitleCleaner.clean(name)).font(.callout.weight(.semibold)).foregroundStyle(.white)
                .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .brightness(hovering ? 0.08 : 0).animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .pointingHandCursor()
        .onTapGesture(perform: action)
    }
}

/// A catalog comic: clicking the cover opens its details and source actions.
private struct ComicCard: View {
    let comic: RemoteComic
    var selecting = false
    var selected = false
    var onTap: () -> Void = {}
    private let downloads = DownloadManager.shared
    @State private var hovering = false
    @State private var showDetail = false

    private var borderColor: Color {
        if selected { return .accentColor }
        return comic.hasMirrors || comic.opensCatalog || comic.canRead ? .white.opacity(0.12) : .orange.opacity(0.9)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The shared `CoverTile` drives the 2:3 layout/clip; this card adds its own badges.
            CoverTile(borderColor: borderColor, borderWidth: (selected || !comic.hasMirrors) ? 2 : 1) {
                cover
                    .overlay { if selected { Color.accentColor.opacity(0.22) } }
                    .overlay(alignment: .topLeading) {
                        if selecting { selectionMark } else if comic.mustRead { mustReadBadge }
                    }
                    .overlay(alignment: .bottomLeading) { if !comic.hasMirrors && !comic.opensCatalog && !comic.canRead { noMirrorBadge } }
                    .overlay { if !selecting && comic.hasMirrors { DownloadOverlay(item: CollectionItem(remote: comic)) } }
            }
            .contentShape(Rectangle())
            .pointingHandCursor()
            .onTapGesture {
                if selecting { onTap() }
                else if comic.sourceID == nil { showDetail = true }
                else { onTap() }
            }
            .popover(isPresented: $showDetail, arrowEdge: .trailing) { detail }

            Text(TitleCleaner.clean(comic.title)).font(.callout.weight(.medium)).foregroundStyle(.white)
                .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let d = comic.description {
                Text(d).font(.caption).foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .brightness(hovering ? 0.08 : 0).animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    private var selectionMark: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3).symbolRenderingMode(.palette)
            .foregroundStyle(.white, selected ? Color.accentColor : .black.opacity(0.35))
            .background(Circle().fill(selected ? .white : .black.opacity(0.25)))
            .padding(6).shadow(radius: 2)
    }

    private var cover: some View { PluginComicCover(comic: comic) }

    /// Corner badge marking a curated must-read essential.
    private var mustReadBadge: some View {
        Image(systemName: "star.fill")
            .font(.caption).foregroundStyle(.black)
            .padding(5).background(.yellow, in: Circle())
            .padding(6).shadow(radius: 2)
    }

    /// Corner badge marking a comic that has no download links.
    private var noMirrorBadge: some View {
        Label("No mirror", systemImage: "link.badge.plus")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.orange.opacity(0.9), in: Capsule())
            .padding(6)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pageURL = comic.pageURL {
                Button {
                    showDetail = false
                    NSWorkspace.shared.open(pageURL)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(TitleCleaner.clean(comic.title))
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Open source page in browser")
            } else {
                Text(TitleCleaner.clean(comic.title)).font(.headline)
            }
            if comic.mustRead {
                Label("Must read" + (comic.mustReadTitle.map { " · \($0)" } ?? ""),
                      systemImage: "star.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
            if let d = comic.description { Text(d).font(.callout).foregroundStyle(.secondary) }
            if !comic.metadataRows.isEmpty {
                Divider()
                ForEach(comic.metadataRows, id: \.key) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.key).font(.caption.weight(.semibold)).frame(width: 90, alignment: .leading)
                        Text(row.value).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                if let size = comic.size, !size.isEmpty {
                    Label(size, systemImage: "internaldrive")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("from \(comic.sourceName)").font(.caption2).foregroundStyle(.secondary)
            }
            downloadRow
        }
        .padding(16).frame(width: 320)
    }

    /// The single download control (mirrors are tried automatically by the downloader).
    @ViewBuilder private var downloadRow: some View {
        if !comic.hasMirrors {
            Text("No download links.").font(.caption2).foregroundStyle(.secondary)
        } else {
            let item = CollectionItem(remote: comic)
            switch downloads.status(forItem: comic.id) {
            case .downloading(let f):
                HStack(spacing: 8) {
                    if let f {
                        ProgressView(value: f).progressViewStyle(.linear)
                        Text("\(Int(f * 100))%").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                        Text("Downloading…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            case .needsBrowser:
                Button { downloads.openInBrowser(item) } label: {
                    Label("Open in Browser", systemImage: "arrow.up.forward.square")
                }.pointingHandCursor()
            case .done:
                Label("Downloaded to library", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            default:
                Button { downloads.download(item) } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }.pointingHandCursor()
            }
        }
    }
}

enum SortMode: String { case title, yearDesc }

/// The grid's sorted comics plus the A–Z letter index (first comic under each initial letter).
/// Uses the app-wide `AZLetter` so the shared rail can index this grid too.
struct DisplayResult {
    let comics: [RemoteComic]
    let letters: [AZLetter]
}

/// Memoizes `DisplayResult` for a given (filtered comics, sort) input so scrolling/hovering
/// doesn't re-sort the whole catalog on every SwiftUI render. Reference type: safe to update
/// from within a computed property (it isn't SwiftUI state).
@MainActor final class DisplayCache {
    private var key = ""
    private var cached = DisplayResult(comics: [], letters: [])

    func compute(base: [RemoteComic], sort: SortMode, token: String) -> DisplayResult {
        let k = "\(token)|\(sort.rawValue)|\(base.count)"
        if k == key { return cached }

        let sorted: [RemoteComic]
        switch sort {
        case .title:
            sorted = base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .yearDesc:
            sorted = base.sorted {
                let ya = Self.year($0), yb = Self.year($1)
                if ya != yb { return ya > yb }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }

        // A–Z index from the shared builder (only meaningful for title sort).
        let letters = sort == .title
            ? AZLetter.index(sorted, id: \.id, title: \.title) : []

        cached = DisplayResult(comics: sorted, letters: letters)
        key = k
        return cached
    }

    /// The latest 4-digit year (1900–2099) mentioned in the title, else 0.
    private static func year(_ c: RemoteComic) -> Int {
        var best = 0
        let chars = Array(c.title)
        var n = 0
        while n + 3 < chars.count {
            if chars[n].isNumber, chars[n+1].isNumber, chars[n+2].isNumber, chars[n+3].isNumber,
               let y = Int(String(chars[n..<n+4])), (1900...2099).contains(y) {
                best = max(best, y); n += 4
            } else { n += 1 }
        }
        return best
    }
}

/// Shows the web-style pointing-hand cursor while the pointer is over a clickable element,
/// and restores the arrow on exit. Uses `set()` (not push/pop) to avoid a stuck cursor when
/// lazy cells are destroyed mid-hover.
struct PointingHandCursor: ViewModifier {
    func body(content: Content) -> some View {
        // onContinuousHover re-asserts the cursor on every move, so it persists while the pointer
        // is over the element (a one-shot onHover + set() gets reset to the arrow on mouse-move).
        content.onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

extension View {
    /// Show the pointing-hand cursor on hover (for clickable elements).
    func pointingHandCursor() -> some View { modifier(PointingHandCursor()) }
}
