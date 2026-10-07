import SwiftUI
import AppKit

/// App-level navigation between the Library home and the Reader.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    enum Route { case library, local, onlineSearch, reader, browse, collections }
    var route: Route = .library
    var localQuery = ""
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


    /// Where the reader was opened from, so the reader's Back button returns to the right context
    /// instead of always dropping to Home — matters when opening from the "Continue Reading" shelf.
    enum ReaderOrigin {
        case home                       // default: back to the Home library
        case library(path: [URL])       // restore this drilled library folder (a local comic's series)
        case local                       // restore the flat local library
        case collections                 // restore the Collections screen
        case onlineSearch               // restore online search results
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

    /// Continue into the following issue in a series from the reader's end-of-issue card.
    func openNextIssue(_ comic: Comic) {
        let returnPath = [comic.url.deletingLastPathComponent()]
        if comic.chapterCount > 0 {
            path = returnPath
            selectedComicOrigin = .library(path: returnPath)
            selectedComic = comic
            route = .library
        } else {
            openComic(comic, origin: .library(path: returnPath))
        }
    }

    /// Move between adjacent local issues without returning to the chapter grid. A negative
    /// page index starts from the end of the issue (`-1` means its last page).
    func openAdjacentIssue(_ comic: Comic, startIndex: Int) {
        let parent = comic.url.deletingLastPathComponent().standardizedFileURL
        let returnPath = path.last?.standardizedFileURL == parent ? path : [parent]
        readerOrigin = .library(path: returnPath)
        selectedComic = nil
        path = returnPath
        AppModel.shared.open(urls: [comic.url], startIndex: startIndex)
        route = .reader
    }

    /// Back out of the chapter level to the folder listing.
    func closeComic() {
        selectedComic = nil
        selectedComicOrigin = .home
    }

    /// Open a comic (issue) from the library in the reader (resumes at last page). By default Back
    /// returns to wherever the library currently is (`.home`); callers that open from a context-less
    /// place (a Home shelf) set `readerOrigin` afterwards via `openFromShelf`.
    func openComic(_ comic: Comic, origin: ReaderOrigin = .home) {
        readerOrigin = origin
        if comic.isRemote { AppModel.shared.openRemote(comic) }   // web comic / series issue
        else { AppModel.shared.open(urls: [comic.url]) }
        route = .reader
    }

    /// Open a comic straight to reading from a Home shelf ("Continue Reading"), remembering its
    /// context so Back returns to the generic Online browser for streamed comics, or the containing
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

    /// Explicit Home navigation always returns to the dashboard.
    func showHome() {
        path = []
        selectedComic = nil
        selectedComicOrigin = .home
        showLibrary()
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

    /// Open the online source browser.
    func showBrowse() { route = .browse }

    func showOnlineRoot() {
        BrowseState.shared.resetNavigation()
        route = .browse
    }

    /// Open the online section.
    func showOnline() { route = .browse }

    /// Open the Collections screen (at its top level).
    func showCollections() {
        selectedCollection = nil
        selectedSmartCollection = nil
        route = .collections
    }

    /// Go up one level: reader/browse → library, chapter level → folder listing, then
    /// pop the folder path one step. At home there's nothing above, so it's a no-op. Returns
    /// true when it actually navigated. (The Browse view handles its own in-feed back stack.)
    @discardableResult
    func escapeBack() -> Bool {
        withAnimation(Self.backSlide) {
            switch route {
            case .reader:
                // Back returns to the context the reader was opened from (its series menu).
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
                case .onlineSearch:
                    readerOrigin = .home
                    route = .onlineSearch
                    return true
                case .browse:
                    readerOrigin = .home
                    route = .browse
                    return true
                case .home:
                    showLibrary()
                    return true
                }
            case .onlineSearch:
                route = .browse
                return true
            case .browse:
                let browse = BrowseState.shared
                if !browse.stack.isEmpty {
                    if let destination = browse.pop() { route = destination }
                } else { showHome() }
                return true
            case .local:
                if selectedComic != nil { closeComic(); return true }
                if !path.isEmpty { path.removeLast(); return true }
                showHome()
                return true
            case .collections:
                if selectedCollection != nil || selectedSmartCollection != nil {
                    selectedCollection = nil
                    selectedSmartCollection = nil
                    return true
                }
                showHome()
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

/// Keeps the native title bar in sync with the reader without adding another toolbar.
private struct ComicWindowTitle: NSViewRepresentable {
    let title: String?

    final class TitleView: NSView {
        var comicTitle: String? { didSet { updateTitle() } }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateTitle()
        }
        func updateTitle() {
            guard let window else { return }
            window.title = comicTitle ?? "Comic Viewer"
            window.titleVisibility = comicTitle == nil ? .hidden : .visible
        }
    }

    func makeNSView(context: Context) -> TitleView {
        let view = TitleView()
        view.comicTitle = title
        return view
    }
    func updateNSView(_ view: TitleView, context: Context) { view.comicTitle = title }
}

/// Switches between the Library grid and the Reader.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(LibraryModel.self) private var library
    @State private var appKeyMonitor = KeyMonitor()
    /// Covers the first-frame layout (small window + placeholder cover icons) until the window
    /// is maximized and the initial scan settles, so launch doesn't look broken.
    @State private var showSplash = true

    private var routedContent: some View {
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
    }

    var body: some View {
        Group {
            if router.route == .reader {
                routedContent
            } else {
                AppNavigationShell { routedContent }
            }
        }
        .background(ComicWindowTitle(title: router.route == .reader ? model.comicTitle : nil))
        .onAppear {
            appKeyMonitor.start(key: handleAppKey)
            if router.route == .library { maximizeWindow() }
        }
        .onDisappear { appKeyMonitor.stop() }
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

    /// F toggles the app window's fullscreen state from every section, not only the reader.
    /// Escape remains owned by the active screen so it can pop that screen's navigation stack.
    private func handleAppKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "f",
              NSApp.modalWindow == nil else { return false }

        if NSApp.keyWindow?.firstResponder is NSTextView { return false }
        (event.window ?? NSApp.keyWindow)?.toggleFullScreen(nil)
        return true
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
        ("1 / 0", "First / Last page of comic"),
        ("2 / 9", "First / Last page of chapter"),
        ("⌘C", "Copy current page image"),
        ("C", "Toggle chapter"),
        ("T", "Chapter thumbnails"),
        ("+  −", "Zoom in / out (fit)"),
        ("Double-click", "Zoom to point"),
        ("Drag / arrows (zoomed)", "Pan"),
        ("Z", "Fit to screen / cycle fit mode"),
        ("H", "Toggle page number"),
        ("R", "Horizontal / Vertical view"),
        ("F", "Toggle fullscreen"),
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


/// A persistent sidebar on desktop; narrow windows open the full sidebar over the content.
struct AppNavigationShell<Content: View>: View {
    @AppStorage("navigation.sidebarExpanded") private var sidebarExpanded = true
    @State private var narrowDrawer = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900
            let expanded = wide && sidebarExpanded
            HStack(spacing: 0) {
                AppSidebar(expanded: expanded) {
                    if wide { sidebarExpanded.toggle() } else { narrowDrawer.toggle() }
                }
                .frame(width: expanded ? 220 : 56)
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .leading) {
                if !wide && narrowDrawer {
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.45)
                            .onTapGesture { narrowDrawer = false }
                            .accessibilityLabel("Close sidebar")
                        AppSidebar(expanded: true) { narrowDrawer = false }
                            .frame(width: 220)
                            .shadow(color: .black.opacity(0.4), radius: 18, x: 8)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: expanded)
            .animation(.easeInOut(duration: 0.18), value: narrowDrawer)
            .onChange(of: wide) { _, _ in narrowDrawer = false }
            .onReceive(NotificationCenter.default.publisher(for: .toggleNavigationSidebar)) { _ in
                if wide { sidebarExpanded.toggle() } else { narrowDrawer.toggle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sidebarDidNavigate)) { _ in narrowDrawer = false }
        }
    }
}

struct AppSidebar: View {
    @Environment(AppRouter.self) private var router
    let expanded: Bool
    var toggle: () -> Void

    private var active: AppRouter.Route {
        if router.route == .onlineSearch { return .browse }
        if router.route == .library && (!router.path.isEmpty || router.selectedComic != nil) { return .local }
        return router.route
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if expanded {
                    Text("Comic Viewer").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                Button(action: toggle) { Image(systemName: "sidebar.left").frame(width: 32, height: 32) }
                    .sidebarTooltip(expanded ? "Collapse sidebar" : "Expand sidebar")
                    .accessibilityLabel(expanded ? "Collapse sidebar" : "Expand sidebar")
            }
            .padding(.horizontal, expanded ? 16 : 12)
            .frame(height: 54)

            VStack(spacing: 4) {
                destination("Home", icon: "house", route: .library) { router.showHome() }
                destination("Library", icon: "books.vertical", route: .local) { router.showLocal() }
                destination("Online", icon: "globe", route: .browse) { router.showOnlineRoot() }
                destination("Collections", icon: "rectangle.stack", route: .collections) { router.showCollections() }
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 4) {
                DownloadQueueButton(showLabel: expanded)
                    .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
                    .padding(.horizontal, expanded ? 12 : 0).frame(height: 38)
                    .sidebarTooltip("Downloads", isEnabled: !expanded)
                TorrentQueueButton(showLabel: expanded)
                    .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
                    .padding(.horizontal, expanded ? 12 : 0).frame(height: 38)
                    .sidebarTooltip("Torrents", isEnabled: !expanded)
                Divider().overlay(.white.opacity(0.07)).padding(.vertical, 6)
                SettingsLink {
                    HStack(spacing: 12) {
                        Image(systemName: "gearshape").frame(width: 18)
                        if expanded { Text("Settings"); Spacer(minLength: 0) }
                    }
                    .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
                    .padding(.horizontal, expanded ? 12 : 0).frame(height: 38)
                    .contentShape(Rectangle())
                }.sidebarTooltip("Settings", isEnabled: !expanded)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
        .buttonStyle(.plain).tint(.white)
        .foregroundStyle(.white.opacity(0.8))
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.075))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.06)).frame(width: 1) }
    }

    private func destination(_ title: String, icon: String, route: AppRouter.Route, action: @escaping () -> Void) -> some View {
        Button {
            action()
            NotificationCenter.default.post(name: .sidebarDidNavigate, object: nil)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 18)
                if expanded { Text(title).lineLimit(1); Spacer(minLength: 0) }
            }
            .font(.system(size: 13, weight: active == route ? .medium : .regular))
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .padding(.horizontal, expanded ? 12 : 0).frame(height: 40)
            .background(active == route ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(active == route ? .white : .white.opacity(0.65))
            .contentShape(Rectangle())
        }
        .sidebarTooltip(title, shortcut: shortcut(for: route), isEnabled: !expanded)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active == route ? .isSelected : [])
        .pointingHandCursor()
    }

    private func shortcut(for route: AppRouter.Route) -> String? {
        switch route {
        case .library: "⌘1"
        case .local: "⌘L"
        case .browse: "⌘B"
        case .collections: "⌘K"
        default: nil
        }
    }
}

private struct SidebarTooltipModifier: ViewModifier {
    let title: String
    var shortcut: String? = nil
    var isEnabled = true

    @State private var isHovering = false
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .task(id: isHovering && isEnabled) {
                isVisible = false
                guard isEnabled, isHovering else { return }
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.12)) { isVisible = true }
            }
            .overlay(alignment: .leading) {
                if isEnabled && isVisible {
                    HStack(spacing: 0) {
                        SidebarTooltipArrow()
                            .fill(Color(white: 0.16))
                            .frame(width: 7, height: 12)
                        HStack(spacing: 14) {
                            Text(title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.96))
                            if let shortcut {
                                Text(shortcut)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.58))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.white.opacity(0.09), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
                    }
                    .fixedSize()
                    .offset(x: 54)
                    .zIndex(1000)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .offset(x: -3)))
                }
            }
    }
}

private struct SidebarTooltipArrow: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

private extension View {
    func sidebarTooltip(
        _ title: String,
        shortcut: String? = nil,
        isEnabled: Bool = true
    ) -> some View {
        modifier(SidebarTooltipModifier(title: title, shortcut: shortcut, isEnabled: isEnabled))
    }
}
