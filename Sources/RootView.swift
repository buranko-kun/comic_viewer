import SwiftUI
import AppKit

/// App-level navigation between the Library home and the Reader.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    enum Route { case library, local, onlineSearch, reader, browse, collections }
    var route: Route = .library
    /// Global "Keyboard Shortcuts" overlay toggle (menu ⌘/, or ? in the reader).
    var showShortcuts = false
    /// The collection currently opened in the Collections view (nil = the list of collections).
    var selectedCollection: String?
    var selectedSmartCollection: String?
    /// Orientation of the Library screen. The **library is enjoyed in landscape** (the reader
    /// is what goes portrait); a toolbar button can flip it.
    var libraryPortrait = false

    /// The sub-folder path drilled into within the library (empty = home / the roots' contents).
    /// Each element is a folder URL; the last one is the level currently shown.
    var path: [URL] = []
    /// When set, the library shows the chapters of this comic (chapter level).
    var selectedComic: Comic?
    /// Where the currently selected comic was opened from before entering its chapter grid.
    private(set) var selectedComicOrigin: ReaderOrigin = .home


    /// Where the reader was opened from, so Escape returns to the right context (its series menu)
    /// instead of always dropping to Home — matters when opening from the "Continue Reading" shelf.
    enum ReaderOrigin {
        case home                       // default: back to the Home library
        case library(path: [URL])       // restore this drilled library folder (a local comic's series)
        case local                       // restore the flat local library
        case collections                 // restore the Collections screen
        case browse                     // restore the unified Online browser
    }
    var readerOrigin: ReaderOrigin = .home

    /// The folder whose contents the library is currently showing (nil = home).
    var currentDir: URL? { path.last }

    /// Drill into a sub-folder group (a series / sub-series).
    func openGroup(_ group: LibraryGroup) {
        selectedComic = nil
        path.append(group.url)
    }

    /// Open an issue: if it has chapters, drill into the chapter level; otherwise read it.
    func openIssue(_ comic: Comic, origin: ReaderOrigin = .home) {
        if comic.chapterCount > 0 {
            selectedComic = comic
            selectedComicOrigin = origin
        } else {
            openComic(comic, origin: origin)
        }
    }

    /// Back out of the chapter level to the folder listing.
    func closeComic() {
        selectedComic = nil
        selectedComicOrigin = .home
    }

    /// Open a comic (issue) from the library in the reader (resumes at last page). By default Escape
    /// returns to wherever the library currently is (`.home`); callers that open from a context-less
    /// place (a Home shelf) set `readerOrigin` afterwards via `openFromShelf`.
    func openComic(_ comic: Comic, origin: ReaderOrigin = .home) {
        readerOrigin = origin
        if comic.isRemote { AppModel.shared.openRemote(comic) }   // web comic / series issue
        else { AppModel.shared.open(urls: [comic.url]) }
        route = .reader
    }

    /// Open a comic straight to reading from a Home shelf ("Continue Reading"), remembering its
    /// context so Escape returns to the generic Online browser for streamed comics, or the containing
    /// library folder for a local comic.
    func openFromShelf(_ comic: Comic) {
        openComic(comic)
        if comic.isRemote {
            readerOrigin = .browse
        } else {
            readerOrigin = .library(path: [comic.url.deletingLastPathComponent()])
        }
    }

    /// Open a comic at a specific page index (the chapter start, or the resume page when the
    /// last-read page falls inside the chapter). Passing the index into `open` makes it survive an
    /// archive's asynchronous extraction (a follow-up `goTo` would run before the pages exist).
    func openChapter(in comic: Comic, at index: Int) {
        readerOrigin = selectedComicOrigin
        AppModel.shared.open(urls: [comic.url], startIndex: index)
        route = .reader
    }

    /// Open an ad-hoc file/folder (⌘O, drag, Open-With) straight into the reader.
    func openExternal(_ urls: [URL]) {
        readerOrigin = .home
        AppModel.shared.open(urls: urls)
        route = .reader
    }

    /// Return to the library, refreshing progress badges from the just-read comic.
    func showLibrary() {
        route = .library
        LibraryModel.shared.rescan()
    }

    /// Open the flat local-library view without Home shelves.
    func showLocal() {
        selectedComic = nil
        selectedComicOrigin = .home
        path = []
        route = .local
    }

    /// Open the unified online search surface.
    func showOnlineSearch(query: String = "") {
        OnlineSearchState.shared.query = query
        route = .onlineSearch
    }

    /// Open the online (OPDS) browser.
    func showBrowse() { route = .browse }

    /// Open the online source browser.
    func showBrowse() { route = .browse }

    /// Open the online section.
    func showOnline() { route = .browse }

    /// Open the Collections screen (at its top level).
    func showCollections() {
        selectedCollection = nil
        selectedSmartCollection = nil
        route = .collections
    }

    /// Go up one level (Escape): reader/browse → library, chapter level → folder listing, then
    /// pop the folder path one step. At home there's nothing above, so it's a no-op. Returns
    /// true when it actually navigated. (The Browse view handles its own in-feed back stack.)
    @discardableResult
    func escapeBack() -> Bool {
        withAnimation(Self.backSlide) {
            switch route {
            case .reader:
                // Escape returns to the context the reader was opened from (its series menu).
                switch readerOrigin {
                case .library(let p):
                    readerOrigin = .home
                    selectedComic = nil
                    path = p
                    route = .library
                    LibraryModel.shared.rescan()
                    return true
                case .local:
                    readerOrigin = .home
                    selectedComic = nil
                    route = .local
                    return true
                case .collections:
                    readerOrigin = .home
                    route = .collections
                    LibraryModel.shared.rescan()
                    return true
                case .browse:
                    readerOrigin = .home
                    route = .browse
                    return true
                case .home:
                    showLibrary()
                    return true
                }
            case .browse, .onlineSearch:
                showLibrary()
                return true
            case .local:
                showLibrary()
                return true
            case .collections:
                if selectedCollection != nil || selectedSmartCollection != nil {
                    selectedCollection = nil
                    selectedSmartCollection = nil
                    return true
                }
                showLibrary()
                return true
            case .library:
                if selectedComic != nil { selectedComic = nil; return true }
                if !path.isEmpty { path.removeLast(); return true }
                return false
            }
        }
    }

    // (Online server selection lives in `OnlineServerStore`, below.)

    /// The slide timing used by every "back" navigation.
    static let backSlide: Animation = .easeInOut(duration: 0.3)
}

/// Switches between the Library grid and the Reader.
struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(LibraryModel.self) private var library
    /// Covers the first-frame layout (small window + placeholder cover icons) until the window
    /// is maximized and the initial scan settles, so launch doesn't look broken.
    @State private var showSplash = true

    var body: some View {
        Group {
            switch router.route {
            case .library:
                LibraryView()
                    .onAppear {
                        if library.comics.isEmpty && !library.folders.isEmpty { library.scan() }
                    }
            case .local:
                LibraryView(localOnly: true)
                    .onAppear {
                        if library.comics.isEmpty && !library.folders.isEmpty { library.scan() }
                    }
            case .onlineSearch:
                OnlineSearchView()
            case .reader:
                ContentView()
            case .browse:
                BrowseView()
            case .collections:
                CollectionsView()
            }
        }
        // A back navigation slides the current section off to the right and the previous in from
        // the left (driven by `withAnimation` in `escapeBack`); forward switches are instant.
        .id(router.route)
        .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing)))
        .clipped()
        .onAppear { if router.route == .library { maximizeWindow() } }
        .onChange(of: router.route) { _, r in if r != .reader { maximizeWindow() } }
        // The reader draws its own (rotation-aware) copy; here we cover library/online.
        .overlay { if router.showShortcuts && router.route != .reader {
            ShortcutsOverlay { router.showShortcuts = false }
        } }
        .overlay(alignment: .bottom) {
            AppNoticeBar()
        }
        .overlay { if showSplash { SplashView().transition(.opacity) } }
        .task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeOut(duration: 0.45)) { showSplash = false }
        }
    }

    /// Grow the window to fill the available screen (menu bar / Dock aside) — the library is
    /// meant to be seen big. Deferred so the window exists on first launch.
    private func maximizeWindow() {
        DispatchQueue.main.async {
            guard let win = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.mainWindow,
                  let screen = win.screen ?? NSScreen.main else { return }
            win.setFrame(screen.visibleFrame, display: true, animate: false)
        }
    }
}

/// The app's keyboard-shortcuts cheat sheet, shown by ⌘/ (menu) or ? (reader). Tapping the
/// dimmed backdrop, or pressing Esc/?, dismisses it. Shared by `RootView` and the reader.
struct ShortcutsOverlay: View {
    var onClose: () -> Void = {}

    private let rows: [(String, String)] = [
        ("← ↑", "Previous page"),
        ("→ ↓ Space", "Next page"),
        ("Home / End", "First / Last page"),
        ("Shift + arrows", "Previous / Next chapter"),
        ("1 / 0", "Chapter start / book start"),
        ("C", "Toggle chapter"),
        ("T", "Chapter thumbnails"),
        ("+  −", "Zoom in / out (fit)"),
        ("Double-click", "Zoom to point"),
        ("Drag / arrows (zoomed)", "Pan"),
        ("Z", "Fit to screen / cycle fit mode"),
        ("H", "Toggle page number"),
        ("R", "Horizontal / Vertical view"),
        ("F / Esc", "Fullscreen / exit"),
        ("⌘O", "Open file, folder, or archive"),
        ("⌘/", "Toggle this help"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: 9) {
                Text("Keyboard Shortcuts").font(.title2.bold()).padding(.bottom, 4)
                ForEach(rows, id: \.0) { key, desc in
                    HStack(spacing: 16) {
                        Text(key).font(.system(.body, design: .monospaced))
                            .frame(width: 170, alignment: .leading)
                        Text(desc).foregroundStyle(.secondary)
                    }
                }
                Text("Press ⌘/ or Esc to close").font(.footnote)
                    .foregroundStyle(.secondary).padding(.top, 6)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .transition(.opacity)
    }
}

/// Full-screen launch splash: app icon + name on black, shown while the window sizes and the
/// first library scan runs. Fades out from `RootView`.
struct SplashView: View {
    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Comic Viewer"
    }

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 132, height: 132)
                Text(appName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                ProgressView()
                    .controlSize(.small).tint(.white.opacity(0.7))
            }
        }
        .ignoresSafeArea()
    }
}
