import SwiftUI
import AppKit
import CoreGraphics
import CoreServices

// MARK: - Model

/// One entry in a user collection. It can point at a local library comic or an online catalog
/// comic; enough is stored to render a cover and re-open it later (a file path for library items,
/// a page/mirror links for online items).
struct CollectionItem: Identifiable, Codable, Hashable {
    /// `online` = a remote catalog comic; `library` = a local comic.
    enum Kind: String, Codable {
        case online, library

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = raw == Self.library.rawValue ? .library : .online
        }
    }
    var id: String            // online RemoteComic.id or library path
    var kind: Kind
    var title: String
    var cover: String?        // absolute URL string: https (online) or file (library cover image)
    var page: String?         // online source page
    var path: String?         // library comic path
    var source: String?       // online source name
    var mirrors: [String]     // online download links
    var mustRead: Bool

    init(remote c: RemoteComic) {
        id = c.id; kind = .online; title = c.title
        cover = c.coverURL?.absoluteString; page = c.pageURL?.absoluteString
        path = nil; source = c.sourceName
        mirrors = c.mirrors.map(\.absoluteString); mustRead = c.mustRead
    }

    init(library c: Comic) {
        id = c.url.path; kind = .library; title = c.title
        cover = c.coverURL?.absoluteString; page = nil; path = c.url.path
        source = nil; mirrors = []; mustRead = false
    }

}

enum CollectionDisplayMode: String, CaseIterable, Identifiable {
    case grid
    case shelves

    var id: String { rawValue }
    var label: String { self == .grid ? "Grid" : "Shelves" }
}

enum CollectionOrder: String, CaseIterable, Identifiable {
    case titleAscending, titleDescending, mostItems, fewestItems, newest, oldest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .titleAscending: "Title A–Z"
        case .titleDescending: "Title Z–A"
        case .mostItems: "Most comics"
        case .fewestItems: "Fewest comics"
        case .newest: "Newest collections"
        case .oldest: "Oldest collections"
        }
    }
}

enum CollectionItemOrder: String, CaseIterable, Identifiable {
    case added, titleAscending, titleDescending, downloadedFirst, recentlyRead, mostProgress
    var id: String { rawValue }
    var label: String {
        switch self {
        case .added: "Custom order"
        case .titleAscending: "Title A–Z"
        case .titleDescending: "Title Z–A"
        case .downloadedFirst: "Downloaded first"
        case .recentlyRead: "Recently read"
        case .mostProgress: "Most progress"
        }
    }
}

enum CollectionSortSupport {
    static func ordered(_ collections: [Collection], by order: CollectionOrder) -> [Collection] {
        switch order {
        case .titleAscending:
            return collections.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .titleDescending:
            return collections.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .mostItems:
            return collections.sorted {
                $0.items.count == $1.items.count
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.items.count > $1.items.count
            }
        case .fewestItems:
            return collections.sorted {
                $0.items.count == $1.items.count
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.items.count < $1.items.count
            }
        case .newest:
            return collections.sorted { $0.created > $1.created }
        case .oldest:
            return collections.sorted { $0.created < $1.created }
        }
    }

    static func ordered(_ comics: [Comic], by order: CollectionItemOrder) -> [Comic] {
        switch order {
        case .added: return comics
        case .titleAscending:
            return comics.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .titleDescending:
            return comics.sorted { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        case .downloadedFirst:
            return comics.sorted { $0.isRemote == $1.isRemote
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : !$0.isRemote }
        case .recentlyRead:
            return comics.sorted {
                let a = CentralStore.lastReadDate(forKey: CentralStore.key(for: $0.url)) ?? .distantPast
                let b = CentralStore.lastReadDate(forKey: CentralStore.key(for: $1.url)) ?? .distantPast
                return a == b ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : a > b
            }
        case .mostProgress:
            return comics.sorted {
                let a = $0.progress?.fraction ?? 0
                let b = $1.progress?.fraction ?? 0
                return a == b ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : a > b
            }
        }
    }
}

/// A named, ordered list of comics the user is organizing (e.g. "Wonder Woman must-reads").
struct Collection: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var items: [CollectionItem] = []
    var created: Date = Date()
}

// MARK: - Store

/// Persists user collections as one JSON file per collection under `…/collections/<id>.json`, and
/// is the single source of truth for the Collections UI and the "Add to Collection" menus.
///
/// One-file-per-collection (keyed by stable id, not name) means a collection can be added, edited,
/// or removed without rewriting the others — so external edits can't clobber the set. A directory
/// watcher reloads live whenever files change on disk (in-app or dropped in from outside), so a
/// collection created externally shows up **without relaunching**.
@MainActor
@Observable
final class CollectionStore {
    static let shared = CollectionStore()

    private(set) var collections: [Collection] = []

    private var dir: URL { CentralStore.baseDir.appendingPathComponent("collections", isDirectory: true) }
    private var legacyURL: URL { CentralStore.baseDir.appendingPathComponent("collections.json") }
    private func fileURL(_ id: String) -> URL { dir.appendingPathComponent(id + ".json") }

    private var watcher: DirectoryWatcher?

    init() {
        migrateLegacy()
        reloadFromDisk()
        watcher = DirectoryWatcher(path: dir.path) { [weak self] in
            MainActor.assumeIsolated { self?.reloadFromDisk() }
        }
        watcher?.start()
    }

    // MARK: - Disk

    /// One-time: split an old single `collections.json` into per-collection files, then retire it.
    private func migrateLegacy() {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: legacyURL),
              let cols = try? JSONDecoder().decode([Collection].self, from: data) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for c in cols { writeFile(c) }
        let retired = legacyURL.appendingPathExtension("migrated")
        try? fm.removeItem(at: retired)
        try? fm.moveItem(at: legacyURL, to: retired)
    }

    /// Load every `<id>.json` from the directory (ordered by creation). Only updates the published
    /// array when the on-disk set actually differs, so the watcher can't loop on our own writes.
    private func reloadFromDisk() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Collection] = []
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f),
               let c = try? JSONDecoder().decode(Collection.self, from: data) {
                loaded.append(c)
            }
        }
        loaded.sort { $0.created < $1.created }
        if loaded != collections { collections = loaded }
    }

    private func writeFile(_ c: Collection) {
        CentralStore.ensureDirs()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(c) {
            try? data.write(to: fileURL(c.id), options: .atomic)
        }
    }

    private func deleteFile(_ id: String) {
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    // MARK: - Mutations

    @discardableResult
    func create(name: String) -> String {
        let c = Collection(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : name)
        collections.append(c); writeFile(c); return c.id
    }

    func rename(_ id: String, to name: String) {
        guard let i = idx(id) else { return }
        collections[i].name = name; writeFile(collections[i])
    }

    func delete(_ id: String) { collections.removeAll { $0.id == id }; deleteFile(id) }

    func add(_ item: CollectionItem, to id: String) {
        guard let i = idx(id), !collections[i].items.contains(where: { $0.id == item.id }) else { return }
        collections[i].items.append(item); writeFile(collections[i])
    }

    func remove(_ itemID: String, from id: String) {
        guard let i = idx(id) else { return }
        collections[i].items.removeAll { $0.id == itemID }; writeFile(collections[i])
    }

    func toggle(_ item: CollectionItem, in id: String) {
        contains(item.id, in: id) ? remove(item.id, from: id) : add(item, to: id)
    }

    func contains(_ itemID: String, in id: String) -> Bool {
        idx(id).map { collections[$0].items.contains { $0.id == itemID } } ?? false
    }

    func collection(_ id: String) -> Collection? { collections.first { $0.id == id } }

    private func idx(_ id: String) -> Int? { collections.firstIndex { $0.id == id } }

    /// Replace online items with the matching downloaded library comic (by normalized title), so a
    /// comic downloaded — in-app or via the browser into a scanned folder — takes the online
    /// entry's place. Called after every library scan.
    func reconcile(libraryComics: [Comic]) {
        guard !collections.isEmpty else { return }
        var byTitle: [String: Comic] = [:]
        for c in libraryComics { byTitle[Self.norm(c.title)] = c }
        var changedIDs = Set<String>()
        for i in collections.indices {
            for j in collections[i].items.indices where collections[i].items[j].kind == .online {
                guard let match = byTitle[Self.norm(collections[i].items[j].title)] else { continue }
                collections[i].items[j].kind = .library
                collections[i].items[j].path = match.url.path
                collections[i].items[j].cover = match.coverURL?.absoluteString
                changedIDs.insert(collections[i].id)
            }
        }
        for id in changedIDs where idx(id) != nil { writeFile(collections[idx(id)!]) }
    }

    private static func norm(_ s: String) -> String {
        TitleCleaner.clean(s).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}

/// Watches a directory (file-level) via FSEvents and calls `handler` on the main queue whenever
/// anything inside changes — so external edits to the collections folder are picked up live.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let handler: () -> Void

    init(path: String, handler: @escaping () -> Void) {
        self.path = path
        self.handler = handler
    }

    func start() {
        guard stream == nil else { return }
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    deinit {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }
}

// MARK: - Add-to-collection menu (used in .contextMenu on cards)

/// A submenu listing collections (with a check for membership) plus "New Collection…". Toggling
/// adds/removes the item; "New Collection…" sets `pendingNew` so the host view can prompt a name.
struct AddToCollectionMenu: View {
    let item: CollectionItem
    @Binding var pendingNew: CollectionItem?
    private let store = CollectionStore.shared

    var body: some View {
        Menu("Add to Collection") {
            ForEach(store.collections) { col in
                Button {
                    store.toggle(item, in: col.id)
                } label: {
                    if store.contains(item.id, in: col.id) {
                        Label(col.name, systemImage: "checkmark")
                    } else {
                        Text(col.name)
                    }
                }
            }
            if !store.collections.isEmpty { Divider() }
            Button("New Collection…") { pendingNew = item }
        }
    }
}

/// Sheet to name a new collection; if `item` is set, it's added to the new collection.
struct NewCollectionSheet: View {
    let item: CollectionItem?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    private let store = CollectionStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Collection").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 300)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    let id = store.create(name: name)
                    if let item { store.add(item, to: id) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

/// Sheet to rename an existing collection.
struct RenameCollectionSheet: View {
    let collection: Collection
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    private let store = CollectionStore.shared

    init(collection: Collection) {
        self.collection = collection
        _name = State(initialValue: collection.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Collection").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 300)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { store.rename(collection.id, to: name); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Cover

/// Renders a collection item's cover from either the remote cache (https) or the thumbnail
/// cache (local file), matching the rest of the app's cover look.
struct CollectionCover: View {
    let item: CollectionItem
    @State private var cg: CGImage?

    private var placeholderIcon: String {
        switch item.kind {
        case .library: return "book.closed"
        case .online: return "globe"
        }
    }

    var body: some View {
        Group {
            if let cg {
                Image(decorative: cg, scale: 1).resizable().interpolation(.medium).scaledToFill()
            } else {
                Image(systemName: placeholderIcon).font(.largeTitle).foregroundStyle(.white.opacity(0.4))
            }
        }
        .task(id: item.id + (item.path ?? "")) {
            // Prefer a stored cover URL (online https, or a resolved library image path).
            if let s = item.cover, let u = URL(string: s) {
                cg = u.isFileURL ? await ThumbnailCache.shared.thumbnail(for: u, maxPixel: 320)
                                 : await RemoteImageCache.shared.image(for: u, maxPixel: 320)
                if cg != nil { return }
            }
            // A library item with no stored image (e.g. a downloaded archive): resolve it now.
            if item.kind == .library, let p = item.path {
                let url = URL(fileURLWithPath: p)
                var src: URL?
                if ArchiveExtractor.isArchive(url) { src = await ArchiveCover.make(for: url) }
                else { src = FileScanner.scan(url).first }
                if let src { cg = await ThumbnailCache.shared.thumbnail(for: src, maxPixel: 320) }
            }
        }
    }
}

/// Full-cover download control for online collection items: a corner ⬇ button when idle, a
/// **bottom progress bar** (matching the reading-progress line) filling as it downloads, and an ↗
/// "open in browser" button if no mirror yields a real file. Disappears once downloaded.
struct DownloadOverlay: View {
    let item: CollectionItem
    private let dl = DownloadManager.shared

    var body: some View {
        if item.kind == .online {
            switch dl.status(forItem: item.id) {
            case .idle, .failed:
                corner("arrow.down.circle.fill") { dl.download(item) }
            case .queued:
                // Waiting for a slot — a clock badge; tap to remove from the queue.
                corner("clock.fill") { dl.cancel(item.id) }
            case .downloading(let frac):
                DownloadProgressBar(fraction: frac).allowsHitTesting(false)
            case .needsBrowser:
                corner("arrow.up.forward.circle.fill") { dl.openInBrowser(item) }
            case .done:
                Color.clear
            }
        }
    }

    private func corner(_ system: String, _ action: @escaping () -> Void) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: action) {
                    Image(systemName: system).font(.title2).foregroundStyle(.white).shadow(radius: 2).padding(6)
                }
                .buttonStyle(.plain).pointingHandCursor()
            }
        }
    }
}

/// A thin red progress bar hugging the cover's bottom edge (over a faint track) — same look as the
/// reading-progress line — plus a small percentage pill so an active download reads at a glance.
/// A nil fraction (total unknown) shows a full faint track with a small spinner.
struct DownloadProgressBar: View {
    let fraction: Double?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack {
                Spacer()
                if let f = fraction {
                    Text("\(Int(f * 100))%")
                        .font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                } else {
                    ProgressView().controlSize(.small).tint(.white).padding(6)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.25))
                    Rectangle().fill(Color.red)
                        .frame(width: g.size.width * CGFloat(fraction ?? 0))
                }
            }
            .frame(height: 3)
            .animation(.easeOut(duration: 0.2), value: fraction)
        }
    }
}

// MARK: - Collections screen

/// Browse and manage collections. Top level lists the collections; tapping one shows its items.
struct CollectionsView: View {
    @Environment(AppRouter.self) private var router
    private let store = CollectionStore.shared
    @State private var keyMonitor = KeyMonitor()

    @State private var searchText = ""
    @State private var showNew = false
    @State private var renaming: Collection?
    @State private var pendingDelete: Collection?
    @AppStorage("collections.displayMode") private var displayModeRawValue = CollectionDisplayMode.grid.rawValue
    @AppStorage("collections.order") private var collectionOrderRawValue = CollectionOrder.titleAscending.rawValue
    @AppStorage("collections.itemOrder") private var itemOrderRawValue = CollectionItemOrder.added.rawValue

    private var displayMode: CollectionDisplayMode {
        CollectionDisplayMode(rawValue: displayModeRawValue) ?? .grid
    }

    private var collectionOrder: CollectionOrder {
        CollectionOrder(rawValue: collectionOrderRawValue) ?? .titleAscending
    }

    private var itemOrder: CollectionItemOrder {
        CollectionItemOrder(rawValue: itemOrderRawValue) ?? .added
    }

    private var orderedCollections: [Collection] {
        CollectionSortSupport.ordered(store.collections, by: collectionOrder)
    }

    private func orderedItems(_ items: [CollectionItem]) -> [CollectionItem] {
        switch itemOrder {
        case .added: return items
        case .titleAscending:
            return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .titleDescending:
            return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        case .downloadedFirst:
            return items.sorted { ($0.kind == .library) == ($1.kind == .library)
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : $0.kind == .library }
        case .recentlyRead:
            return items.sorted { readDate(for: $0) > readDate(for: $1) }
        case .mostProgress:
            return items.sorted { progress(for: $0) > progress(for: $1) }
        }
    }

    private func readDate(for item: CollectionItem) -> Date {
        guard let path = item.path else { return .distantPast }
        return CentralStore.lastReadDate(forKey: CentralStore.key(for: URL(fileURLWithPath: path))) ?? .distantPast
    }

    private func progress(for item: CollectionItem) -> Double {
        guard let path = item.path,
              let state = CentralStore.loadState(forKey: CentralStore.key(for: URL(fileURLWithPath: path))),
              let index = state.lastIndex, let count = state.pageCount, count > 0 else { return 0 }
        return Double(index + 1) / Double(count)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Divider().overlay(.white.opacity(0.12))
                content
            }
        }
        .tint(.white)
        .sheet(isPresented: $showNew) { NewCollectionSheet(item: nil) }
        .sheet(item: $renaming) { RenameCollectionSheet(collection: $0) }
        .confirmationDialog("Delete collection?", isPresented: .init(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { col in
            Button("Delete “\(col.name)”", role: .destructive) {
                store.delete(col.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { col in
            Text("This removes the “\(col.name)” collection (\(col.items.count) item\(col.items.count == 1 ? "" : "s")). "
                 + "The comics themselves are not deleted.")
        }
        .onAppear {
            keyMonitor.start(key: handleKey)
        }
        .onDisappear { keyMonitor.stop() }
        .onChange(of: router.selectedCollection) { _, _ in searchText = "" }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard !e.modifierFlags.contains(.command), e.keyCode == 53, NSApp.modalWindow == nil
        else { return false }
        return router.escapeBack()
    }

    // MARK: Top bar

    private var current: Collection? { router.selectedCollection.flatMap { store.collection($0) } }

    private var topBarTitle: String {
        if let current { return current.name }
        return "Collections"
    }

    private var topBarSubtitle: String {
        if let current {
            return String(current.items.count)
                + " item"
                + (current.items.count == 1 ? "" : "s")
        }
        let count = store.collections.count
        return String(count) + " collection" + (count == 1 ? "" : "s")
    }

    private var topBar: some View {
        SectionToolbar {
            HStack(spacing: 10) {
                if current != nil {
                    Button { router.escapeBack() } label: { Image(systemName: "chevron.left") }.help("Back to Collections")
                }
                SectionHeading(title: topBarTitle, detail: topBarSubtitle)
            }
        } search: {
            NavigationSearchField(prompt: current != nil ? "Search this collection" : "Search collections", text: $searchText)
        } actions: {
            if current == nil {
                Button { showNew = true } label: { Label("New", systemImage: "plus") }
            }
        }
    }

    private func matches(_ title: String) -> Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.localizedStandardContains(searchText)
    }

    private var subtitle: String {
        if let c = current { return "\(c.items.count) item\(c.items.count == 1 ? "" : "s")" }
        let n = store.collections.count
        return "\(n) collection\(n == 1 ? "" : "s")"
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let c = current {
            itemsGrid(c)
        } else {
            collectionsGrid
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.5))
            Text("No collections yet").font(.title2.bold())
            Text("Build reading lists from your library or the online catalog.\n"
                 + "Right-click any comic → Add to Collection.")
                .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.6))
            Button { showNew = true } label: { Label("New Collection", systemImage: "plus") }
                .buttonStyle(.borderedProminent).tint(.red).pointingHandCursor()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    private var collectionsGrid: some View {
        Group {
            if store.collections.isEmpty {
                emptyState
            } else {
                GeometryReader { geo in
                    ScrollView {
                        Group {
                            if displayMode == .grid {
                                manualCollectionsSection(width: geo.size.width)
                            } else {
                                manualCollectionShelves
                            }
                        }
                        .padding(.horizontal, GridStyle.hPadding)
                        .padding(.top, 24)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
    }

    private func manualCollectionsSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("My Collections")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                Button { showNew = true } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()
            }

            LazyVGrid(
                columns: GridStyle.columns(width),
                alignment: .leading,
                spacing: GridStyle.rowSpacing
            ) {
            ForEach(orderedCollections.filter { matches($0.name) }) { col in
                    CollectionFolderCard(collection: col) { router.selectedCollection = col.id }
                        .contextMenu {
                            Button("Rename…") { renaming = col }
                            Button("Delete…", role: .destructive) { pendingDelete = col }
                        }
                }
            }
        }
    }

    private var manualCollectionShelves: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(orderedCollections.filter { collection in
                matches(collection.name) || collection.items.contains { matches($0.title) }
            }) { col in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button { router.selectedCollection = col.id } label: {
                            Text(col.name)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("Open collection \(col.name)")

                        Text("\(col.items.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Menu {
                            Button("Open collection") { router.selectedCollection = col.id }
                            Button("Rename…") { renaming = col }
                            Button("Delete…", role: .destructive) { pendingDelete = col }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 28, height: 28)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .help("Collection options")

                    }

                    let items = orderedItems(col.items.filter { matches($0.title) })
                    if items.isEmpty {
                        Text("This collection is empty.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.45))
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: GridStyle.spacing) {
                                ForEach(items) { item in
                                    CollectionShelfCard(item: item) { open(item) }
                                        .contextMenu {
                                            Button(item.kind == .online ? "Open Page" : "Read") { open(item) }
                                            Button("Remove from Collection", role: .destructive) {
                                                store.remove(item.id, from: col.id)
                                            }
                                        }
                                }
                            }
                            .padding(.bottom, 4)
                        }
                    }
                }
            }
        }
    }

    private func itemsGrid(_ col: Collection) -> some View {
        GeometryReader { geo in
            ScrollView {
                if col.items.isEmpty {
                    Text("This collection is empty.\nRight-click comics elsewhere to add them here.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.5)).padding(.top, 60)
                }
                LazyVGrid(columns: GridStyle.columns(geo.size.width), alignment: .leading,
                          spacing: GridStyle.rowSpacing) {
                    ForEach(orderedItems(col.items.filter { matches($0.title) })) { item in
                        CollectionItemCard(item: item) { open(item) }
                            .contextMenu {
                                Button(item.kind == .online ? "Open Page" : "Read") { open(item) }
                                Button("Remove from Collection", role: .destructive) {
                                    store.remove(item.id, from: col.id)
                                }
                            }
                    }
                }
                .padding(.horizontal, GridStyle.hPadding).padding(.top, 24).padding(.bottom, 24)
            }
        }
    }

    private func open(_ item: CollectionItem) {
        switch item.kind {
        case .online:
            if let s = item.page, let u = URL(string: s) { NSWorkspace.shared.open(u) }
        case .library:
            guard let p = item.path else { return }
            router.readerOrigin = .collections
            AppModel.shared.open(urls: [URL(fileURLWithPath: p)])
            router.route = .reader
        }
    }
}

/// A collection tile: a 2×2 mosaic of its first covers, name, and item count.
private struct CollectionFolderCard: View {
    let collection: Collection
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                CoverTile { cover }
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.name).font(.callout.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(collection.items.count) item\(collection.items.count == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
        .brightness(hovering ? 0.08 : 0).animation(.easeOut(duration: 0.12), value: hovering)
        .onContinuousHover { phase in
            switch phase {
            case .active: hovering = true; NSCursor.pointingHand.set()
            case .ended: hovering = false; NSCursor.arrow.set()
            }
        }
    }

    /// The cover is the collection's first item (its "poster").
    @ViewBuilder private var cover: some View {
        if let first = collection.items.first {
            CollectionCover(item: first)
        } else {
            Image(systemName: "rectangle.stack").font(.system(size: 40)).foregroundStyle(.secondary)
        }
    }
}

/// A cover tile for an item inside a collection.
private struct CollectionItemCard: View {
    let item: CollectionItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                CoverTile(borderColor: item.mustRead ? .orange.opacity(0.9) : GridStyle.hairline,
                          borderWidth: item.mustRead ? 2 : 1) {
                    CollectionCover(item: item)
                        .overlay(alignment: .topLeading) { if item.mustRead { star } }
                        .overlay { DownloadOverlay(item: item) }
                }
                Text(TitleCleaner.clean(item.title)).font(.callout.weight(.medium)).foregroundStyle(.white)
                    .lineLimit(2, reservesSpace: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .brightness(hovering ? 0.08 : 0).animation(.easeOut(duration: 0.12), value: hovering)
        .onContinuousHover { phase in
            switch phase {
            case .active: hovering = true; NSCursor.pointingHand.set()
            case .ended: hovering = false; NSCursor.arrow.set()
            }
        }
    }

    private var star: some View {
        Image(systemName: "star.fill").font(.caption).foregroundStyle(.black)
            .padding(5).background(.yellow, in: Circle()).padding(6).shadow(radius: 2)
    }
}
