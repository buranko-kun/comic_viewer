import SwiftUI
import AppKit
import CoreGraphics
import CoreServices

// MARK: - Model

/// One entry in a user collection. It can point at a local library comic or an online catalog
/// comic; enough is stored to render a cover and re-open it later (a file path for library items,
/// a page/mirror links for online items).
struct CollectionItem: Identifiable, Codable, Hashable {
    /// `online` = a downloadable GetComics entry; `library` = a local comic; `readComics` = a
    /// streamed ReadComicsOnline series (opens back into that section, never downloads).
    enum Kind: String, Codable { case online, library, readComics }
    var id: String            // online RemoteComic.id, library path, or "rco:<slug>"
    var kind: Kind
    var title: String
    var cover: String?        // absolute URL string: https (online) or file (library cover image)
    var page: String?         // online source page
    var path: String?         // library comic path, or the ReadComicsOnline slug
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

    init(readComics e: CatalogEntry) {
        id = "rco:" + e.slug; kind = .readComics; title = e.title
        cover = e.coverURL?.absoluteString; page = e.pageURL?.absoluteString
        path = e.slug             // the slug reconstructs the CatalogEntry on open
        source = "ReadComicsOnline"; mirrors = []; mustRead = false
    }

    /// Rebuild the ReadComicsOnline series entry this item points to (for `.readComics` items).
    var readComicsEntry: CatalogEntry? {
        guard kind == .readComics, let slug = path else { return nil }
        return CatalogEntry(slug: slug, title: title, coverURL: cover.flatMap { URL(string: $0) })
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
        case .readComics: return "square.grid.3x3.fill"
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
    @State private var library = LibraryModel.shared
    @State private var keyMonitor = KeyMonitor()
    @State private var swipeBack = SwipeBackDetector()

    @State private var showNew = false
    @State private var renaming: Collection?
    @State private var pendingDelete: Collection?

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
            swipeBack.onBack = { router.escapeBack() }
            keyMonitor.start(key: handleKey, scroll: swipeBack.handle)
        }
        .onDisappear { keyMonitor.stop() }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard !e.modifierFlags.contains(.command), e.keyCode == 53, NSApp.modalWindow == nil
        else { return false }
        return router.escapeBack()
    }

    // MARK: Top bar

    private var current: Collection? { router.selectedCollection.flatMap { store.collection($0) } }

    private var currentSmart: SmartCollectionKind? {
        guard let id = router.selectedSmartCollection else { return nil }
        return SmartCollectionKind(rawValue: id)
    }

    private var topBarTitle: String {
        if let current { return current.name }
        if let currentSmart { return currentSmart.title }
        return "Collections"
    }

    private var topBarSubtitle: String {
        if let current {
            return String(current.items.count)
                + " item"
                + (current.items.count == 1 ? "" : "s")
        }
        if let currentSmart {
            let count = currentSmart.comics(in: library).count
            return String(count) + " item" + (count == 1 ? "" : "s")
        }
        let count = store.collections.count
        return String(count) + " collection" + (count == 1 ? "" : "s")
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            if current != nil || currentSmart != nil {
                Button {
                    router.selectedCollection = nil
                    router.selectedSmartCollection = nil
                } label: {
                    Label("Collections", systemImage: "chevron.left")
                }
                .pointingHandCursor()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(topBarTitle).font(.headline).foregroundStyle(.white).lineLimit(1)
                Text(topBarSubtitle).font(.caption2).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer()
            Button { router.showLibrary() } label: {
                Label("Home", systemImage: "house")
            }
            .labelStyle(.iconOnly).help("Home").pointingHandCursor()
            Button { router.showLocal() } label: {
                Label("Local", systemImage: "internaldrive")
            }
            .labelStyle(.iconOnly).help("Local library").pointingHandCursor()
            Button { router.showOnline() } label: {
                Label("Online", systemImage: "globe")
            }
            .labelStyle(.iconOnly).help("Online").pointingHandCursor()
            DownloadQueueButton()
            if current == nil && currentSmart == nil {
                Button { showNew = true } label: { Label("New", systemImage: "plus") }
                    .pointingHandCursor()
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 30).padding(.vertical, 10)
        .background(Color.black)
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
        } else if let smart = currentSmart {
            SmartCollectionItemsView(kind: smart)
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
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    smartCollectionsSection(width: geo.size.width)
                    if !store.collections.isEmpty {
                        manualCollectionsSection(width: geo.size.width)
                    }
                }
                .padding(.horizontal, GridStyle.hPadding)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func smartCollectionsSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Smart Collections")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            LazyVGrid(
                columns: GridStyle.columns(width),
                alignment: .center,
                spacing: GridStyle.rowSpacing
            ) {
                ForEach(SmartCollectionKind.allCases) { kind in
                    let comics = kind.comics(in: library)
                    SmartCollectionFolderCard(
                        kind: kind,
                        comics: comics
                    ) {
                        router.selectedCollection = nil
                        router.selectedSmartCollection = kind.rawValue
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
                alignment: .center,
                spacing: GridStyle.rowSpacing
            ) {
                ForEach(store.collections) { col in
                    CollectionFolderCard(collection: col) { router.selectedCollection = col.id }
                        .contextMenu {
                            Button("Rename…") { renaming = col }
                            Button("Delete…", role: .destructive) { pendingDelete = col }
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
                LazyVGrid(columns: GridStyle.columns(geo.size.width), alignment: .center,
                          spacing: GridStyle.rowSpacing) {
                    ForEach(col.items) { item in
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
        case .readComics:
            guard let entry = item.readComicsEntry else { return }
            router.readComicsSeries = entry     // drill straight into that series
            router.route = .readcomics
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
