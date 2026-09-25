import SwiftUI
import AppKit
import Observation

/// Shared state for the app-wide Online search field. Keeping the query here lets Home and
/// the results screen hand off the same text without coupling the two views.
@MainActor
@Observable
final class OnlineSearchState {
    static let shared = OnlineSearchState()
    var query = ""
}

/// A result from any indexed online engine. GetComics-style catalog entries keep their download
/// metadata; ReadComicsOnline entries open directly into the streamed reader.
enum UnifiedSearchItem: Identifiable {
    case catalog(RemoteComic)
    case readComics(CatalogEntry)

    var id: String {
        switch self {
        case .catalog(let comic): return "catalog:" + comic.id
        case .readComics(let entry): return "readcomics:" + entry.id
        }
    }

    var title: String {
        switch self {
        case .catalog(let comic): return comic.title
        case .readComics(let entry): return entry.title
        }
    }

    var coverURL: URL? {
        switch self {
        case .catalog(let comic): return comic.coverURL
        case .readComics(let entry): return entry.coverURL
        }
    }

    var sourceName: String {
        switch self {
        case .catalog(let comic): return comic.sourceName
        case .readComics: return "ReadComicsOnline"
        }
    }
}

/// Unified search across every configured catalog source plus the mirrored ReadComicsOnline index.
/// This is intentionally an indexed search: it never has to hit a remote site for each keystroke.
struct OnlineSearchView: View {
    @Environment(AppRouter.self) private var router
    @State private var searchState = OnlineSearchState.shared
    private let aggregator = CatalogAggregator.shared
    private let readComics = ReadComicsCatalogStore.shared

    @State private var results: [UnifiedSearchItem] = []
    @State private var searching = false
    @State private var loaded = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var state = searchState
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Divider().overlay(.white.opacity(0.12))
                content
            }
        }
        .tint(.white)
        .onAppear {
            searchFocused = true
            Task { await ensureIndexesLoaded(); runSearch() }
        }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: state.query) { _, _ in runSearch() }
    }

    private var topBar: some View {
        @Bindable var state = searchState
        return HStack(spacing: 14) {
            Button { router.showLibrary() } label: {
                Label("Home", systemImage: "chevron.left")
            }
            .pointingHandCursor()

            Text("Online Search")
                .font(.headline).foregroundStyle(.white)

            if !results.isEmpty {
                Text("\(results.count) results")
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField("Search every source", text: $state.query)
                    .textFieldStyle(.plain)
                    .frame(width: 320)
                    .focused($searchFocused)
                if !state.query.isEmpty {
                    Button { state.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain).pointingHandCursor()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.white.opacity(0.08), in: Capsule())

            Button { router.showLocal() } label: {
                Label("Local", systemImage: "internaldrive")
            }
            .labelStyle(.iconOnly).help("Local library").pointingHandCursor()

            Button { router.showOnline() } label: {
                Label("Online", systemImage: "globe")
            }
            .labelStyle(.iconOnly).help("Browse online catalogs").pointingHandCursor()

            Button { router.showCollections() } label: {
                Label("Collections", systemImage: "rectangle.stack")
            }
            .labelStyle(.iconOnly).help("Collections").pointingHandCursor()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 30).padding(.vertical, 10)
        .background(Color.black)
    }

    @ViewBuilder private var content: some View {
        if searchState.query.trimmingCharacters(in: .whitespaces).isEmpty {
            centered {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 44)).foregroundStyle(.white.opacity(0.35))
                    Text("Search your online catalogs")
                        .font(.title3.bold()).foregroundStyle(.white)
                    Text("Results are combined from every configured catalog and ReadComicsOnline.")
                        .font(.callout).foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .padding(40)
            }
        } else if searching {
            centered { ProgressView().controlSize(.large) }
        } else if results.isEmpty {
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 38)).foregroundStyle(.white.opacity(0.3))
                    Text("No matches").font(.title3.bold())
                    Text("Try a title, series name, or character.")
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVGrid(columns: GridStyle.columns(geo.size.width),
                          alignment: .center, spacing: GridStyle.rowSpacing) {
                    ForEach(results) { item in
                        UnifiedSearchCard(item: item) { open(item) }
                    }
                }
                .padding(.horizontal, GridStyle.hPadding)
                .padding(.top, 24).padding(.bottom, 24)
            }
        }
    }

    private func open(_ item: UnifiedSearchItem) {
        switch item {
        case .catalog(let comic):
            if let url = comic.pageURL { NSWorkspace.shared.open(url) }
        case .readComics(let entry):
            router.readComicsSeries = entry
            router.route = .readcomics
        }
    }

    private func ensureIndexesLoaded() async {
        if !aggregator.loadedOnce {
            await aggregator.loadRoots()
        }
        loaded = true
    }

    private func runSearch() {
        searchTask?.cancel()
        let q = searchState.query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            results = []
            searching = false
            return
        }

        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            if Task.isCancelled { return }

            if !loaded {
                await ensureIndexesLoaded()
            }

            let catalogItems = aggregator.comics
            let readComicsItems = readComics.entries
            let ranked = await Self.rank(catalogItems: catalogItems,
                                         readComicsItems: readComicsItems,
                                         query: q)
            if Task.isCancelled { return }
            results = ranked
            searching = false
        }
    }

    /// Match titles across both online indexes, separator-insensitive, then combine the engines
    /// into one relevance-ranked result list.
    private static func rank(catalogItems: [RemoteComic],
                             readComicsItems: [CatalogEntry],
                             query: String) async -> [UnifiedSearchItem] {
        await Task.detached(priority: .userInitiated) {
            let nq = SearchRank.normalize(query)
            guard !nq.isEmpty else { return [] }

            var ranked: [(item: UnifiedSearchItem, score: Int)] = []
            for comic in catalogItems {
                let nt = SearchRank.normalize(comic.title)
                if nt.contains(nq) {
                    ranked.append((.catalog(comic),
                                   SearchRank.score(normalizedTitle: nt, normalizedQuery: nq)))
                }
                else if let series = comic.series {
                    let ns = SearchRank.normalize(series)
                    if ns.contains(nq) {
                        ranked.append((.catalog(comic), 20))
                    }
                }
            }

            for entry in readComicsItems {
                let nt = SearchRank.normalize(entry.title)
                if nt.contains(nq) {
                    ranked.append((.readComics(entry),
                                   SearchRank.score(normalizedTitle: nt, normalizedQuery: nq)))
                }
            }

            return ranked
                .sorted { a, b in
                    if a.score != b.score { return a.score > b.score }
                    if a.item.title.count != b.item.title.count { return a.item.title.count < b.item.title.count }
                    return a.item.title.localizedStandardCompare(b.item.title) == .orderedAscending
                }
                .map(\.item)
        }.value
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A result card that makes the available action visible on the cover:
/// a book badge means it can be read directly in ReadComicsOnline; the download control marks
/// catalog entries that have a direct downloadable file.
private struct UnifiedSearchCard: View {
    let item: UnifiedSearchItem
    let onTap: () -> Void
    private let downloads = DownloadManager.shared
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverTile {
                CoverImage(url: item.coverURL, maxPixel: 320) {
                    Image(systemName: "book.closed")
                        .font(.largeTitle).foregroundStyle(.white.opacity(0.4))
                }

                if case .readComics = item {
                    Image(systemName: "book.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.7), in: Circle())
                        .padding(6)
                        .help("Read online")
                }

                if case .catalog(let comic) = item, comic.hasMirrors {
                    DownloadOverlay(item: CollectionItem(remote: comic))
                }
            }
            .contentShape(Rectangle())
            .pointingHandCursor()
            .onTapGesture(perform: onTap)

            HStack(spacing: 6) {
                Text(TitleCleaner.clean(item.title))
                    .font(.callout.weight(.medium)).foregroundStyle(.white)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(item.sourceName)
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .brightness(hovering ? 0.08 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
