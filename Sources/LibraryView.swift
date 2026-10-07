import SwiftUI
import AppKit

/// The library home screen: configured folders scanned into a grid of comic covers,
/// grouped into series sections. Clicking a cover opens the reader (via `onOpen`). Rendered
/// in the reading orientation (portrait by default) to match the reader's overlays.
struct LibraryView: View {
    let localOnly: Bool

    init(localOnly: Bool = false) {
        self.localOnly = localOnly
    }

    @Environment(LibraryModel.self) private var library
    @Environment(AppRouter.self) private var router

    private let coverCache = ThumbnailCache.shared
    @State private var keyMonitor = KeyMonitor()
    @State private var pendingNewCollectionItem: CollectionItem?
    @State private var pendingDelete: Comic?
    @State private var pendingDeleteFolder: LibraryGroup?
    @State private var folderDeleteError: String?
    @State private var pendingReset: Comic?
    @State private var pendingResetFolder: LibraryGroup?
    // Chapters of the currently opened comic, loaded async (archives need extraction).
    @State private var chapterRefs: [ChapterRef] = []
    @State private var loadingChapters = false
    // Chapter rename dialog (the chapter being renamed + working text).
    @State private var renamingChapter: ChapterRef?
    @State private var chapterRenameText = ""
    @State private var historyRefresh = 0

    private var localSearchText: String {
        get { router.localQuery }
        nonmutating set { router.localQuery = newValue }
    }
    @State private var localFilter: LocalFilter = .all
    @State private var localSort: LocalSort = .title
    @State private var pendingTorrentSource: URL?

    private var homeSmartCollections: [(kind: SmartCollectionKind, comics: [Comic])] {
        SmartCollectionKind.homeShelves(in: library)
    }

    private enum LocalFilter: String, CaseIterable, Identifiable {
        case all
        case unread
        case inProgress
        case completed
        case hasChapters

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .unread: return "Unread"
            case .inProgress: return "In Progress"
            case .completed: return "Completed"
            case .hasChapters: return "Has Chapters"
            }
        }

        var systemImage: String {
            switch self {
            case .all: return "books.vertical"
            case .unread: return "circle"
            case .inProgress: return "play.circle"
            case .completed: return "checkmark.circle"
            case .hasChapters: return "bookmark"
            }
        }
    }

    private enum LocalSort: String, CaseIterable, Identifiable {
        case title
        case series
        case lastRead
        case recentlyAdded
        case progress

        var id: String { rawValue }

        var label: String {
            switch self {
            case .title: return "Title"
            case .series: return "Series"
            case .lastRead: return "Last Read"
            case .recentlyAdded: return "Recently Added"
            case .progress: return "Progress"
            }
        }

        var systemImage: String {
            switch self {
            case .title: return "textformat"
            case .series: return "rectangle.stack"
            case .lastRead: return "clock"
            case .recentlyAdded: return "calendar"
            case .progress: return "chart.bar"
            }
        }
    }

    private var isPortrait: Bool { router.libraryPortrait }

    /// Shared cover width and insets keep section headings, cards, and controls on the same guides.
    private static let cardWidth = GridStyle.shelfWidth
    private static let gridSpacing = GridStyle.spacing
    private static let gridHPadding = GridStyle.hPadding

    /// A scrolling, width-filling grid of same-size cards, with an optional header above it
    /// (used for the home "Continue Reading" shelf).
    @ViewBuilder
    private func comicGrid<Content: View>(header: AnyView? = nil,
                                          @ViewBuilder _ content: @escaping () -> Content) -> some View {
        GeometryReader { geo in
            let cols = GridStyle.columns(geo.size.width)
            ScrollView {
                VStack(spacing: 0) {
                    if let header { header.padding(.top, 60) }
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 24) {
                        content()
                    }
                    .padding(.horizontal, Self.gridHPadding)
                    .padding(.top, header == nil ? 60 : 20)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    var body: some View {
        rotatedToRead {
            ZStack {
                Color.black.ignoresSafeArea()
                content
                    .id("\(router.path.count)/\(router.selectedComic?.id ?? "")")
                    .transition(.asymmetric(insertion: .move(edge: .leading),
                                            removal: .move(edge: .trailing)))
                    .clipped()
            }
        }
        .sheet(item: $pendingNewCollectionItem) { NewCollectionSheet(item: $0) }
        .sheet(item: $pendingReset) { comic in
            ResetReadingSheet(title: comic.title) { removeChapters in
                library.resetState(comic, removingChapters: removeChapters)
            }
        }
        .sheet(item: $pendingResetFolder) { folder in
            ResetReadingSheet(title: folder.name, includesFolder: true) { removeChapters in
                library.resetFolder(folder.url, removingChapters: removeChapters)
            }
        }
        .sheet(item: $pendingDelete) { comic in
            DeleteComicSheet(comic: comic,
                             onCancel: { pendingDelete = nil },
                             onDelete: { fromDisk in
                                 library.delete(comic, fromDisk: fromDisk)
                                 pendingDelete = nil
                             })
        }
        .sheet(item: $pendingDeleteFolder) { group in
            DeleteFolderSheet(group: group, onCancel: { pendingDeleteFolder = nil }) {
                do {
                    try library.deleteFolder(group.url)
                    pendingDeleteFolder = nil
                } catch {
                    pendingDeleteFolder = nil
                    folderDeleteError = error.localizedDescription
                }
            }
        }
        .alert("Couldn't delete folder", isPresented: Binding(
            get: { folderDeleteError != nil },
            set: { if !$0 { folderDeleteError = nil } }
        )) {
            Button("OK") { folderDeleteError = nil }
        } message: {
            Text(folderDeleteError ?? "")
        }
        .sheet(isPresented: Binding(
            get: { pendingTorrentSource != nil },
            set: { if !$0 { pendingTorrentSource = nil } }
        )) {
            if let source = pendingTorrentSource {
                CreateTorrentSheet(sourceURL: source)
            }
        }
        .onAppear {
            keyMonitor.start(key: handleKey)
        }
        .onDisappear { keyMonitor.stop() }
        .onAppear { historyRefresh += 1 }
        .task(id: router.selectedComic?.id) { await loadChapters() }
    }

    /// Escape moves up one library level, matching the visible back control.
    private func handleKey(_ e: NSEvent) -> Bool {
        guard !e.modifierFlags.contains(.command), e.keyCode == 53,
              NSApp.modalWindow == nil else { return false }
        router.escapeBack()
        return true
    }

    @ViewBuilder private var content: some View {
        // Streamed reading history can populate Home even without a local library.
        if !localOnly && router.currentDir == nil && router.selectedComic == nil && !homeSmartCollections.isEmpty {
            folderGrid
        } else if library.folders.isEmpty {
            emptyState
        } else if library.comics.isEmpty {
            emptyScan
        } else if let comic = router.selectedComic {
            chapterGrid(comic: comic)
        } else if localOnly {
            folderGrid
        } else {
            folderGrid
        }
    }

    /// Flat local-library destination: every downloaded/on-disk comic, without Home shelves or
    /// the folder hierarchy. This is the explicit Local section in the app chrome.
    private var localGrid: some View {
        let comics = filteredLocalComics
        return comicGrid {
            ForEach(comics) { comic in
                CoverCell(comic: comic, cache: coverCache) {
                    router.openIssue(comic, origin: .local)
                }
                .contextMenu { comicMenu(comic) }
            }
        }
        .overlay {
            if comics.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: localSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && localFilter == .all ? "books.vertical" : "magnifyingglass")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.35))
                    Text(localEmptyMessage)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.65))
                    if !localSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || localFilter != .all {
                        Button("Clear Search & Filters") {
                            localSearchText = ""
                            localFilter = .all
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.white)
                        .pointingHandCursor()
                    }
                }
            }
        }
        .overlay(alignment: .top) { localToolbar }
    }

    /// Search covers title, series, and ComicInfo-derived metadata, then applies a reading-state
    /// filter and sorts the remaining cards.
    private var filteredLocalComics: [Comic] {
        let query = localSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = library.comics.filter { comic in
            let textMatches = query.isEmpty
                || comic.title.localizedCaseInsensitiveContains(query)
                || comic.series.localizedCaseInsensitiveContains(query)
                || (comic.tooltip?.localizedCaseInsensitiveContains(query) ?? false)

            guard textMatches else { return false }

            switch localFilter {
            case .all:
                return true
            case .unread:
                return comic.progress == nil
            case .inProgress:
                guard let progress = comic.progress else { return false }
                return progress.count == 0 || progress.page < progress.count
            case .completed:
                guard let progress = comic.progress, progress.count > 0 else { return false }
                return progress.page >= progress.count
            case .hasChapters:
                return comic.chapterCount > 0
            }
        }

        return localSortComics(matched)
    }

    private var localEmptyMessage: String {
        let hasQuery = !localSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasQuery { return "No comics match your search" }
        switch localFilter {
        case .all: return "No comics in your library"
        case .unread: return "No unread comics"
        case .inProgress: return "No comics in progress"
        case .completed: return "No completed comics"
        case .hasChapters: return "No comics with chapters"
        }
    }

    private func localSortComics(_ comics: [Comic]) -> [Comic] {
        func titleOrder(_ a: Comic, _ b: Comic) -> Bool {
            let title = a.title.localizedStandardCompare(b.title)
            if title != .orderedSame { return title == .orderedAscending }
            return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
        }

        switch localSort {
        case .title:
            return comics.sorted(by: titleOrder)

        case .series:
            return comics.sorted {
                let series = $0.series.localizedStandardCompare($1.series)
                if series != .orderedSame { return series == .orderedAscending }
                return titleOrder($0, $1)
            }

        case .lastRead:
            return comics.sorted {
                let a = CentralStore.lastReadDate(forKey: CentralStore.key(for: $0.url)) ?? .distantPast
                let b = CentralStore.lastReadDate(forKey: CentralStore.key(for: $1.url)) ?? .distantPast
                if a != b { return a > b }
                return titleOrder($0, $1)
            }

        case .recentlyAdded:
            return comics.sorted {
                let a = (try? $0.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                if a != b { return a > b }
                return titleOrder($0, $1)
            }

        case .progress:
            return comics.sorted {
                let a = $0.progress?.fraction ?? 0
                let b = $1.progress?.fraction ?? 0
                if a != b { return a > b }
                return titleOrder($0, $1)
            }
        }
    }

    /// The current folder level: sub-folder groups (series / sub-series) to drill into,
    /// followed by the comics that live directly here. Mirrors the on-disk folder tree.
    private var folderGrid: some View {
        let candidates = localOnly ? filteredLocalComics : library.comics
        let entries = library.entries(at: router.currentDir, matching: candidates)
        let atRoot = router.currentDir == nil
        let atHome = atRoot && !localOnly
        let smartCollections = atHome ? homeSmartCollections : []
        let hasShelves = !smartCollections.isEmpty
        let visibleIssues = localOnly ? localSortComics(entries.comics) : entries.comics
        let _ = historyRefresh
        return comicGrid(header: hasShelves ? AnyView(homeHeader(smartCollections)) : nil) {
            ForEach(entries.groups) { group in
                GroupCard(group: group, cache: coverCache) { router.openGroup(group) }
                    .contextMenu {
                        Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([group.url]) }
                        Button("Reset Reading…") { pendingResetFolder = group }
                        Button("Delete Folder…", role: .destructive) { pendingDeleteFolder = group }
                    }
            }
            ForEach(visibleIssues) { comic in
                CoverCell(comic: comic, cache: coverCache) {
                    router.openIssue(comic, origin: localOnly ? .local : .home)
                }
                    .contextMenu { comicMenu(comic) }
            }
        }
        .overlay(alignment: .top) {
            if atRoot {
                localOnly ? AnyView(localToolbar) : AnyView(toolbar)
            } else {
                AnyView(folderToolbar)
            }
        }
    }

    /// Home shelves show the dynamic Smart Collections, followed by the library grid.
    private func homeHeader(_ collections: [(kind: SmartCollectionKind, comics: [Comic])]) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(collections, id: \.kind.id) { section in
                shelf(title: section.kind.title) {
                    ForEach(section.comics) { comic in
                        ContinueCard(comic: comic, cache: coverCache) { router.openFromShelf(comic) }
                            .contextMenu { comicMenu(comic) }
                    }
                }
            }
            Text("Library").font(.title3.bold()).foregroundStyle(.white)
                .padding(.horizontal, Self.gridHPadding)
        }
    }

    /// A titled horizontal shelf of fixed-size cards.
    private func shelf<Cards: View>(title: String, @ViewBuilder cards: () -> Cards) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold()).foregroundStyle(.white)
                .padding(.horizontal, Self.gridHPadding).lineLimit(1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Self.gridSpacing) { cards() }
                    .padding(.horizontal, Self.gridHPadding)
            }
        }
    }

    /// Third level: the chapters of one comic (only shown when it has chapters). The chapter
    /// you're currently in (last chapter starting at/before your resume page) is highlighted.
    private func chapterGrid(comic: Comic) -> some View {
        let chapters = chapterRefs
        let currentIndex = comic.progress.map { $0.page - 1 }
        let currentOrdinal = currentIndex.flatMap { ci in
            chapters.last { $0.index <= ci }?.ordinal
        }
        return comicGrid {
            ForEach(chapters) { ch in
                ChapterCard(chapter: ch, isCurrent: ch.ordinal == currentOrdinal,
                            cache: coverCache) {
                    router.openChapter(in: comic,
                                       at: resumeTarget(for: ch, in: chapters, resume: currentIndex))
                }
                .contextMenu {
                    if ch.isManual {
                        Button("Rename…") { renamingChapter = ch; chapterRenameText = ch.label }
                        Button("Delete", role: .destructive) {
                            LibraryModel.deleteChapter(comicKey: CentralStore.key(for: comic.url), key: ch.key)
                            Task { await loadChapters() }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) { chapterToolbar(comic, currentOrdinal: currentOrdinal) }
        .overlay { if loadingChapters { ProgressView().controlSize(.large) } }
        .alert("Rename chapter", isPresented: Binding(
            get: { renamingChapter != nil },
            set: { if !$0 { renamingChapter = nil } })) {
            TextField("Name", text: $chapterRenameText)
            Button("Cancel", role: .cancel) { renamingChapter = nil }
            Button("Save") {
                if let ch = renamingChapter {
                    LibraryModel.renameChapter(comicKey: CentralStore.key(for: comic.url),
                                               key: ch.key, to: chapterRenameText)
                    Task { await loadChapters() }
                }
                renamingChapter = nil
            }
        } message: {
            Text("Leave blank to reset to the default name.")
        }
    }

    /// Load the selected comic's chapters (extracting the archive off-main if needed).
    private func loadChapters() async {
        guard let comic = router.selectedComic else { chapterRefs = []; return }
        loadingChapters = true
        let refs = await library.resolveChapters(of: comic)
        guard router.selectedComic?.id == comic.id else { return }   // still viewing it
        chapterRefs = refs
        loadingChapters = false
        await coverCache.preload(refs.map(\.url), maxPixel: 500)
    }

    /// Where opening `ch` should land: if your last-read page falls inside this chapter (from
    /// its start up to the next chapter's start), resume there; otherwise start at the chapter.
    private func resumeTarget(for ch: ChapterRef, in chapters: [ChapterRef], resume: Int?) -> Int {
        guard let r = resume, r >= ch.index else { return ch.index }
        let nextStart = chapters.first { $0.index > ch.index }?.index ?? Int.max
        return r < nextStart ? r : ch.index
    }

    /// Right-click menu shared by every library comic cell.
    @ViewBuilder private func comicMenu(_ comic: Comic) -> some View {
        AddToCollectionMenu(item: CollectionItem(library: comic),
                            pendingNew: $pendingNewCollectionItem)
        Divider()
        if comic.progress != nil {
            Button("Reset Reading…") { pendingReset = comic }
        }
        Button("Create Torrent…") { pendingTorrentSource = comic.url }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = comic }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        SectionToolbar {
            Text("Home").font(.headline)
        } search: { librarySearchField } actions: {
            HStack(spacing: 14) {
                if library.isScanning { ProgressView().controlSize(.small) }
                Button { library.rescan() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh library")
                Button { addFolder() } label: { Image(systemName: "folder.badge.plus") }.help("Add library folder")
            }
        }
    }

    private var librarySearchField: some View {
        NavigationSearchField(prompt: "Search library", text: Binding(get: { localSearchText }, set: { localSearchText = $0 })) {
            router.showLocal()
        }
    }

    /// Toolbar for the explicit Local destination.
    private var localToolbar: some View {
        SectionToolbar {
            SectionHeading(title: "Library", detail: localCountLabel)
        } search: { librarySearchField } actions: {
            HStack(spacing: 12) {
            Menu {
                ForEach(LocalFilter.allCases) { filter in
                    Button {
                        localFilter = filter
                    } label: {
                        Label(filter.label, systemImage: filter == localFilter ? "checkmark" : filter.systemImage)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Filter local comics")
            .pointingHandCursor()

            Menu {
                ForEach(LocalSort.allCases) { sort in
                    Button {
                        localSort = sort
                    } label: {
                        Label(sort.label, systemImage: sort == localSort ? "checkmark" : sort.systemImage)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Sort local comics")
            .pointingHandCursor()

            }
        }
    }

    private var localCountLabel: String {
        let total = library.comics.count
        let shown = filteredLocalComics.count
        return shown == total ? "\(total) comics" : "\(shown) of \(total)"
    }

    /// Toolbar while drilled into a sub-folder: back one level + the folder's name + count.
    private var folderToolbar: some View {
        let dir = router.currentDir
        let entries = library.entries(at: dir, matching: localOnly ? filteredLocalComics : nil)
        let issues = entries.comics.count
        let subs = entries.groups.count
        return SectionToolbar {
            HStack(spacing: 10) {
                Button { router.escapeBack() } label: { Image(systemName: "chevron.left") }
                    .help("Back to \(parentLabel)").pointingHandCursor()
                SectionHeading(
                    title: dir.map { LibraryModel.displayName(for: $0) } ?? "Home",
                    detail: countLabel(subs: subs, issues: issues)
                )
            }
        } search: { librarySearchField } actions: {
            Button { library.rescan() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh library")
        }
    }

    /// Name of the level one step up: the parent folder, or "Home" at the first level.
    private var parentLabel: String {
        let p = router.path
        return p.count >= 2 ? LibraryModel.displayName(for: p[p.count - 2]) : "Home"
    }

    private func countLabel(subs: Int, issues: Int) -> String {
        if subs > 0 && issues == 0 { return "\(subs) series" }
        if subs > 0 { return "\(subs) series · \(issues) issues" }
        return "\(issues) issues"
    }

    /// Toolbar while viewing one comic's chapters: back + title + where-you-left-off + a
    /// "Continue" (resume) shortcut.
    private func chapterToolbar(_ comic: Comic, currentOrdinal: Int?) -> some View {
        SectionToolbar {
            HStack(spacing: 10) {
                Button { router.closeComic() } label: { Image(systemName: "chevron.left") }
                    .help("Back to issues").pointingHandCursor()
                SectionHeading(title: comic.title, detail: "\(comic.chapterCount) chapters")
            }
        } search: { librarySearchField } actions: {
            Button(comic.progress == nil ? "Read" : "Continue") { router.openComic(comic, origin: router.selectedComicOrigin) }
        }
    }

    // MARK: Empty states

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("No library folders yet").font(.title2.bold())
            Text("Add a folder of comics to get started.").foregroundStyle(.secondary)
            Button { addFolder() } label: { Label("Add Library Folder…", systemImage: "plus") }
                .controlSize(.large).pointingHandCursor()
            if defaultComicsFolder != nil {
                Button("Add ~/Comics") {
                    if let d = defaultComicsFolder { library.addFolder(d) }
                }
                .pointingHandCursor()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { localOnly ? AnyView(localToolbar) : AnyView(toolbar) }
    }

    private var emptyScan: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No comics found in your folders").font(.title3.bold())
            Button { library.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .pointingHandCursor()
        }
        .overlay(alignment: .top) { localOnly ? AnyView(localToolbar) : AnyView(toolbar) }
    }

    private var defaultComicsFolder: URL? {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Comics")
        return (try? d.checkResourceIsReachable()) == true ? d : nil
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        if panel.runModal() == .OK { panel.urls.forEach { library.addFolder($0) } }
    }

    // MARK: Orientation

    @ViewBuilder
    private func rotatedToRead<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        GeometryReader { geo in
            content()
                .frame(width: isPortrait ? geo.size.height : geo.size.width,
                       height: isPortrait ? geo.size.width : geo.size.height)
                .rotationEffect(isPortrait ? .degrees(90) : .zero)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// One sub-folder group (series / sub-series): representative cover + folder name + a badge
/// with how many comics it contains. Tapping drills into it.
/// A uniform 2:3 cover tile. The aspect ratio is fixed by a zero-intrinsic-size `Color`, so the
/// box is *exactly* the same size for every card regardless of the source image's proportions;
/// the image fills it (`scaledToFill`) and is cropped by the rounded clip. `bottomOverlay` (e.g.
/// a progress line) is added before the clip so it's cropped to the corners too.
private struct CoverBox<Placeholder: View, BottomOverlay: View>: View {
    let cg: CGImage?
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var bottomOverlay: () -> BottomOverlay

    var body: some View {
        // Built on the shared `CoverTile`, so local cards match every other grid. This variant takes
        // an already-decoded `cg` (its cards handle archive-cover extraction) plus a bottom overlay.
        CoverTile {
            Group {
                if let cg {
                    Image(decorative: cg, scale: 1).resizable().interpolation(.medium).scaledToFill()
                } else {
                    placeholder()
                }
            }
            .overlay(alignment: .bottom) { bottomOverlay() }
        }
    }
}

private struct GroupCard: View {
    @Environment(LibraryModel.self) private var library
    let group: LibraryGroup
    let cache: ThumbnailCache
    let action: () -> Void
    @State private var cg: CGImage?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                CoverBox(cg: cg, placeholder: {
                    Image(systemName: "books.vertical").font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }, bottomOverlay: { EmptyView() })

                Text(group.name).font(.callout.weight(.semibold))
                    .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .hoverLift()
        .task(id: group.id + (group.coverURL?.absoluteString ?? "") + "|\(library.coverRevision)") {
            var url = group.coverURL
            if url == nil, let a = group.coverArchive { url = await ArchiveCover.make(for: a) }
            if let url { cg = await loadCover(url, local: cache) }
        }
    }
}

/// One chapter of a comic: its page thumbnail + "Chapter N" / page label.
/// A chapter cell, styled exactly like a comic `CoverCell`: 2:3 cover, left-aligned title,
/// and a bottom badge (here marking the chapter you're currently reading).
private struct ChapterCard: View {
    let chapter: ChapterRef
    var isCurrent: Bool = false
    let cache: ThumbnailCache
    let action: () -> Void
    @State private var cg: CGImage?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                CoverBox(cg: cg, placeholder: { ProgressView() }, bottomOverlay: {
                    if isCurrent {
                        Rectangle().fill(Color.red).frame(height: 3)   // marks the current chapter
                    }
                })

                Text(chapter.label).font(.callout.weight(.medium))
                    .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .hoverLift()
        .task(id: chapter.url) { cg = await cache.thumbnail(for: chapter.url, maxPixel: 500) }
    }
}

/// One comic cover in the grid: portrait 2:3 image + title + progress badge.
/// Load a cover thumbnail from the right cache: local files via `ThumbnailCache`, remote (http)
/// covers — e.g. a web comic's first page — via `RemoteImageCache`.
private func loadCover(_ url: URL, local: ThumbnailCache, maxPixel: Int = 500) async -> CGImage? {
    url.isFileURL
        ? await local.thumbnail(for: url, maxPixel: maxPixel)
        : await RemoteImageCache.shared.image(for: url, maxPixel: maxPixel)
}

private struct CoverCell: View {
    @Environment(LibraryModel.self) private var library
    let comic: Comic
    let cache: ThumbnailCache
    let action: () -> Void
    @State private var cg: CGImage?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                CoverBox(cg: cg, placeholder: {
                    if comic.isArchive {
                        Image(systemName: "doc.zipper").font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }, bottomOverlay: { progressBadge })

                Text(comic.title).font(.callout.weight(.medium))
                    .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .hoverLift()
        .help(comic.tooltip ?? comic.title)
        .task(id: comic.id + (comic.coverURL?.absoluteString ?? "") + "|\(library.coverRevision)") {
            var url = comic.coverURL
            if url == nil, comic.isArchive { url = await ArchiveCover.make(for: comic.url) }
            if let url { cg = await loadCover(url, local: cache) }
        }
    }

    /// A thin red progress line hugging the cover's bottom edge (over a faint track). No text
    /// block — just the line. Archives (unknown total) show only the faint track to mark "opened".
    @ViewBuilder private var progressBadge: some View {
        if let p = comic.progress {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.25))
                    Rectangle().fill(Color.red)
                        .frame(width: g.size.width * CGFloat(p.fraction))
                }
            }
            .frame(height: 3)
        }
    }
}

/// A metadata detail popover for a library comic. Loads `ComicInfo.xml` on demand (folder or —
/// cheaply, via the streaming extraction — archive), then shows the credits/publisher/genre rows
/// and the story summary. Nothing is loaded until you open it, so scans stay fast.
private struct ComicDetailPopover: View {
    let comic: Comic
    @State private var info: ComicInfo?
    @State private var loading = true
    @State private var refreshing = false
    @State private var showFetch = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(info?.displayTitle ?? comic.title).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading metadata…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let info, !info.metadataRows.isEmpty || info.summary != nil {
                if !info.metadataRows.isEmpty {
                    Divider()
                    ForEach(info.metadataRows, id: \.key) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(row.key).font(.caption.weight(.semibold))
                                .frame(width: 78, alignment: .leading).foregroundStyle(.secondary)
                            Text(row.value).font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if let sum = info.summary, !sum.isEmpty {
                    Divider()
                    ScrollView {
                        Text(sum).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            } else {
                Text("No embedded metadata.").font(.caption).foregroundStyle(.secondary)
            }

            if let error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !loading {
                Divider()
                HStack {
                    if info?.comicVineVolumeID != nil {
                        Button {
                            Task { await refreshLinkedMetadata() }
                        } label: {
                            Label(refreshing ? "Refreshing…" : "Refresh metadata",
                                  systemImage: "arrow.clockwise")
                        }
                        .disabled(!ComicVine.hasKey || refreshing)
                    } else {
                        Button {
                            showFetch = true
                        } label: {
                            Label(info == nil ? "Fetch metadata online" : "Update metadata online",
                                  systemImage: "arrow.down.doc")
                        }
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
        }
        .padding(16).frame(width: 320)
        .task(id: comic.id) { await reload() }
        .sheet(isPresented: $showFetch) {
            MetadataFetchSheet(comic: comic) { Task { await reload() } }
        }
    }

    private func reload() async {
        loading = true
        error = nil
        let isArchive = comic.isArchive, url = comic.url
        info = await Task.detached {
            ComicInfo.load(forComic: url, isArchive: isArchive)
        }.value
        loading = false
    }

    private func refreshLinkedMetadata() async {
        guard !refreshing else { return }
        refreshing = true
        error = nil
        defer { refreshing = false }

        do {
            _ = try await MetadataRefresh.refresh(comic)
            await reload()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Refresh failed."
        }
    }
}

/// Search ComicVine for a comic and save the chosen match as its `ComicInfo.xml`.
private struct MetadataFetchSheet: View {
    let comic: Comic
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [ComicVine.Volume] = []
    @State private var searching = false
    @State private var saving: Int?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fetch metadata").font(.headline)
            if !ComicVine.hasKey {
                Text("Add a ComicVine API key in Settings → Library first.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                TextField("Search title…", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }.disabled(query.isEmpty || searching)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }

            if searching {
                HStack { Spacer(); ProgressView(); Spacer() }.frame(height: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(results) { v in
                            Button { Task { await pick(v) } } label: { row(v) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 260)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 460, height: 460)
        .onAppear { query = TitleCleaner.clean(comic.title); Task { await search() } }
    }

    private func row(_ v: ComicVine.Volume) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: v.coverURL) { img in img.resizable().scaledToFill() } placeholder: {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
            .frame(width: 40, height: 60).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(v.name).font(.callout.weight(.medium)).lineLimit(2)
                Text(v.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if saving == v.id { ProgressView().controlSize(.small) }
            else { Image(systemName: "square.and.arrow.down").foregroundStyle(.secondary) }
        }
        .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func search() async {
        guard !query.isEmpty else { return }
        error = nil; searching = true
        defer { searching = false }
        do { results = try await ComicVine.searchVolumes(query) }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Search failed." }
    }

    private func pick(_ v: ComicVine.Volume) async {
        saving = v.id; error = nil
        defer { saving = nil }
        do {
            let info = try await ComicVine.comicInfo(forVolume: v.id)
            if info.write(forComic: comic.url, isArchive: comic.isArchive) {
                onSaved(); dismiss()
            } else { error = "Couldn't save ComicInfo.xml (check write permissions)." }
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Fetch failed." }
    }
}

/// A compact fixed-width cover for the home "Continue Reading" shelf: cover + progress line +
/// a small percentage, and the comic's title beneath. Tapping resumes at the last page.
struct ContinueCard: View {
    @Environment(LibraryModel.self) private var library
    let comic: Comic
    let cache: ThumbnailCache
    let action: () -> Void
    @State private var cg: CGImage?
    private static let width = GridStyle.shelfWidth

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                CoverBox(cg: cg, placeholder: {
                    Image(systemName: comic.isArchive ? "doc.zipper" : "book.closed")
                        .font(.system(size: 30)).foregroundStyle(.secondary)
                }, bottomOverlay: {
                    if let p = comic.progress {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.25))
                                Rectangle().fill(Color.red).frame(width: g.size.width * CGFloat(p.fraction))
                            }
                        }
                        .frame(height: 3)
                    }
                })
                .frame(width: Self.width)

                Text(comic.title).font(.callout.weight(.medium)).foregroundStyle(.white)
                    .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                    .frame(width: Self.width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .hoverLift()
        .help(comic.tooltip ?? comic.title)
        .task(id: comic.id + (comic.coverURL?.absoluteString ?? "") + "|\(library.coverRevision)") {
            var url = comic.coverURL
            if url == nil, comic.isArchive { url = await ArchiveCover.make(for: comic.url) }
            if let url { cg = await loadCover(url, local: cache) }
        }
    }
}

/// A fixed-width card for a collection item on a home shelf — matches the library cover size.
struct CollectionShelfCard: View {
    let item: CollectionItem
    let action: () -> Void
    private static let width = GridStyle.shelfWidth

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                CoverTile(width: Self.width,
                          borderColor: item.mustRead ? .orange.opacity(0.9) : GridStyle.hairline,
                          borderWidth: item.mustRead ? 2 : 1) {
                    CollectionCover(item: item)
                        .overlay(alignment: .topLeading) {
                            if item.mustRead {
                                Image(systemName: "star.fill").font(.caption).foregroundStyle(.black)
                                    .padding(5).background(.yellow, in: Circle()).padding(6).shadow(radius: 2)
                            }
                        }
                        .overlay { DownloadOverlay(item: item) }
                }
                Text(TitleCleaner.clean(item.title)).font(.callout.weight(.medium)).foregroundStyle(.white)
                    .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                    .frame(width: Self.width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .hoverLift()
    }
}

/// A subtle mouse-hover cue for library cards: a gentle brightness bump (no scaling).
private struct HoverLift: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .brightness(hovering ? 0.08 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !hovering { hovering = true }
                    NSCursor.pointingHand.set()
                case .ended:
                    hovering = false
                    NSCursor.arrow.set()
                }
            }
    }
}

private extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
}

/// Confirms removing a comic from the library, with an opt-in to also delete the file from disk.
private struct DeleteFolderSheet: View {
    let group: LibraryGroup
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete folder “\(group.name)”?").font(.headline)
            Text("This folder and everything inside it will be moved to the Trash, including all issues and subfolders.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(group.url.path).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive, action: onDelete)
            }
        }
        .padding(20).frame(width: 440)
    }
}

private struct DeleteComicSheet: View {
    let comic: Comic
    let onCancel: () -> Void
    let onDelete: (_ fromDisk: Bool) -> Void
    @State private var alsoDeleteFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete “\(comic.title)”?").font(.headline)
            Text(alsoDeleteFile
                 ? "The comic will be removed from your library and its file moved to the Trash."
                 : "The comic will be removed from your library. The file stays on disk — it just "
                   + "won't be shown until you add it back.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Also delete the file from disk (moves it to the Trash)", isOn: $alsoDeleteFile)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(alsoDeleteFile ? "Delete File" : "Remove", role: .destructive) {
                    onDelete(alsoDeleteFile)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Reset progress, with an explicit opt-in to erase chapter markers as well.
private struct ResetReadingSheet: View {
    let title: String
    var includesFolder = false
    let onReset: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var resetChapters = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reset reading for \(title)?")
                .font(.headline)
            Text("Reading progress and its Continue Reading / Recently Read entries will be cleared. Chapter markers are kept unless you select the option below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if includesFolder {
                Text("Applies to every comic in this folder and its subfolders.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Local covers will be refreshed from the current first page.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Also reset chapter markers", isOn: $resetChapters)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Reset Reading", role: .destructive) {
                    onReset(resetChapters)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
