import SwiftUI
import CoreGraphics
import Observation
import AppKit

/// Shared look-and-feel for every cover grid in the app — Library, Online catalogs, and Collections.
/// Centralizing the *visual* layer here keeps all grids
/// pixel-identical and gives one place to tune them. (Behavior-only helpers — `RemoteImageCache`,
/// `ThumbnailCache` and `KeyMonitor` are already shared and used directly.)

/// The single source of truth for grid metrics: card size, spacing, padding, corner radius.
enum GridStyle {
    static let tileTarget: CGFloat = 200    // shared comic-cover width in grids and shelves
    static let spacing: CGFloat = 20        // gap between columns
    static let rowSpacing: CGFloat = 24     // gap between rows
    static let hPadding: CGFloat = 30       // grid horizontal inset
    static let shelfWidth: CGFloat = tileTarget
    static let corner: CGFloat = 8          // cover corner radius
    static let panel = Color.white.opacity(0.06)   // faint cover backing panel
    static let hairline = Color.white.opacity(0.12) // default cover border

    /// Fixed-width columns that fit inside the shared horizontal inset.
    static func columns(_ width: CGFloat, target: CGFloat = tileTarget) -> [GridItem] {
        let count = max(1, Int((width - hPadding * 2 + spacing) / (target + spacing)))
        return Array(repeating: GridItem(.fixed(target), spacing: spacing), count: count)
    }
}

/// The standard cover container: a fixed 2:3 rounded panel with the app's backing/stroke and the
/// cover clipped inside. `content` fills the tile (put the cover image and any corner badges here).
struct CoverTile<Content: View>: View {
    var width: CGFloat? = nil                       // fixed width (shelves) or nil to fill the cell
    var borderColor: Color = GridStyle.hairline
    var borderWidth: CGFloat = 1
    @ViewBuilder var content: () -> Content

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width)
            .overlay { content() }
            .background(GridStyle.panel)
            .clipShape(RoundedRectangle(cornerRadius: GridStyle.corner))
            .overlay(RoundedRectangle(cornerRadius: GridStyle.corner)
                .stroke(borderColor, lineWidth: borderWidth))
    }
}

/// A downsampled cover image that loads through the correct cache — local files via `ThumbnailCache`,
/// remote URLs via `RemoteImageCache` — retrying transient failures before falling back to
/// `placeholder`. This is the one thumbnail renderer used across the whole app.
struct CoverImage<Placeholder: View>: View {
    let url: URL?
    var maxPixel: Int = 500
    var retries: Int = 1
    /// Optional last resort: when the primary `url` never loads (e.g. a guessed cover whose filename
    /// is wrong), this resolves the *real* URL (possibly via network) and loads that instead of
    /// giving up. Only invoked after `url`'s retries are exhausted.
    var resolveFallback: (() async -> URL?)? = nil
    var resource: PluginResourceRequest? = nil
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var cg: CGImage?
    @State private var gaveUp = false

    var body: some View {
        Group {
            if let cg {
                Image(decorative: cg, scale: 1).resizable().interpolation(.medium).scaledToFill()
            } else if url != nil && !gaveUp {
                ProgressView().controlSize(.small)
            } else {
                placeholder()
            }
        }
        .task(id: (resource ?? url.map { PluginResourceRegistry.shared.request(for: $0) })?.cacheKey(maxPixel: maxPixel)) {
            cg = nil; gaveUp = false
            // Covers can transiently fail — a burst (e.g. a whole issue grid at once) gets the CDN
            // rate-limiting (429). Retry with capped backoff + jitter so the burst desynchronizes
            // and later attempts outlast the throttle window, rather than giving up early.
            if let url, await tryLoad(url) { return }
            if Task.isCancelled { return }
            // Primary exhausted (or absent) — resolve the real URL as a last resort, then load it.
            if let resolveFallback, let real = await resolveFallback(), real != url,
               await tryLoad(real) { return }
            gaveUp = true
        }
        .onDisappear { cg = nil }
    }

    /// Try to load `url`, retrying with capped backoff + jitter; sets `cg` and returns true on
    /// success. Returns false without retrying on a **definitive 404** (a wrong/guessed URL will
    /// never load, so the caller should fall back at once) or on cancellation.
    private func tryLoad(_ url: URL) async -> Bool {
        for attempt in 0...max(0, retries) {
            let r = await loadResource(url)
            if let cg = r.image { self.cg = cg; return true }
            if r.notFound || Task.isCancelled { return false }   // don't retry a definitive miss
            if attempt < retries {
                let base = min(1500, 300 * (attempt + 1))
                try? await Task.sleep(for: .milliseconds(base + Int.random(in: 0...250)))
            }
        }
        return false
    }

    private func loadResource(_ target: URL) async -> (image: CGImage?, notFound: Bool) {
        if let resource, target == url {
            return await RemoteImageCache.shared.result(for: resource, maxPixel: maxPixel)
        }
        return await Self.load(target, maxPixel: maxPixel)
    }

    /// Local files → `ThumbnailCache`; remote URLs → `RemoteImageCache`. Both downsample + cache.
    /// `notFound` marks a definitive 404 (remote only) so retries can be skipped.
    static func load(_ url: URL, maxPixel: Int) async -> (image: CGImage?, notFound: Bool) {
        if url.isFileURL {
            return (await ThumbnailCache.shared.thumbnail(for: url, maxPixel: maxPixel), false)
        }
        return await RemoteImageCache.shared.result(for: url, maxPixel: maxPixel)
    }
}

// MARK: - Search matching & ranking

/// Punctuation/separator-insensitive search shared by every catalog search, so "avengers
/// armageddon" finds "Avengers: Armageddon", "Avengers - Armageddon", "Avengers_Armageddon", etc.
/// Both the title and the query are normalized (runs of non-alphanumerics collapse to one space)
/// before comparing, and relevance is scored so the strongest hits lead.
enum SearchRank {
    /// Lowercase; every run of non-alphanumerics becomes a single space; trimmed.
    static func normalize(_ s: String) -> String {
        var out = ""
        var lastSpace = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch); lastSpace = false }
            else if !lastSpace { out.append(" "); lastSpace = true }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// True if the already-normalized `nq` appears in `title` after normalization.
    static func matches(_ title: String, normalizedQuery nq: String) -> Bool {
        !nq.isEmpty && normalize(title).contains(nq)
    }

    /// Relevance of `title` for the already-normalized query (higher = stronger). Convenience that
    /// normalizes the title first.
    static func score(_ title: String, normalizedQuery nq: String) -> Int {
        score(normalizedTitle: normalize(title), normalizedQuery: nq)
    }

    /// Relevance from pre-normalized strings — tiers favor exact / phrase-start / whole-phrase /
    /// word-boundary matches over mid-word substrings, all separator-insensitive.
    static func score(normalizedTitle nt: String, normalizedQuery nq: String) -> Int {
        if nq.isEmpty { return 0 }
        if nt == nq { return 100 }                              // exact title
        if nt.hasPrefix(nq + " ") { return 90 }                // title starts with the query phrase
        if (" " + nt + " ").contains(" " + nq + " ") { return 80 }  // whole phrase on word bounds
        if nt.hasPrefix(nq) { return 70 }                      // starts mid-word ("aveng" → "avengers")
        if (" " + nt).contains(" " + nq) { return 60 }         // query begins some word
        if nt.contains(nq) { return 30 }                       // substring anywhere
        return 10                                              // matched elsewhere (series/desc)
    }
}

// MARK: - Random "shuffle" shelf

/// Deterministic PRNG so a shuffle seed reproduces the same sample across re-renders (and even after
/// a view's @State resets on navigation) — the random set stays stable for the session.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// A session-scoped "surprise me" shelf state for one catalog engine: whether the random landing is
/// active, and the seed that fixes which random comics show. `sample` picks `count` items in a
/// stable pseudo-random order for the current seed (O(count), no full shuffle of a 70k catalog).
@MainActor @Observable
final class RandomShelf {
    static let online = RandomShelf()

    /// Random landing on by default — the section opens on a random set until you pick a letter.
    var active = true
    private(set) var seed: UInt64 = .random(in: .min ... .max)

    /// New random set (and ensure the shuffle view is showing).
    func reshuffle() { seed = .random(in: .min ... .max); active = true }

    func sample<T>(_ items: [T], count: Int = 200) -> [T] {
        guard items.count > count else {
            var rng = SplitMix64(seed: seed); return items.shuffled(using: &rng)
        }
        var rng = SplitMix64(seed: seed)
        let n = UInt64(items.count)
        var picked: [Int] = []; var seen = Set<Int>()
        while picked.count < count {
            let i = Int(rng.next() % n)
            if seen.insert(i).inserted { picked.append(i) }
        }
        return picked.map { items[$0] }
    }
}

// MARK: - A–Z jump rail

/// One entry in the A–Z rail: a letter and the id of the first grid item under it.
struct AZLetter: Hashable {
    let letter: String; let id: String; let index: Int

    /// The rail bucket for a title: its uppercased initial, or "#" for anything non-letter (digits,
    /// symbols). Kept identical for every grid.
    static func bucket(_ title: String) -> String {
        guard let ch = title.trimmingCharacters(in: .whitespaces).uppercased().first else { return "#" }
        return ch.isLetter ? String(ch) : "#"
    }

    /// Build the A–Z index for an **already-sorted** list: the first item under each bucket, in the
    /// list's own order (so "#" lands wherever digit/symbol titles sort — the top, matching every
    /// grid — not force-sorted elsewhere).
    static func index<T>(_ items: [T], id: (T) -> String, title: (T) -> String) -> [AZLetter] {
        var out: [AZLetter] = []
        var seen = Set<String>()
        for (i, item) in items.enumerated() {
            let l = bucket(title(item))
            if seen.insert(l).inserted { out.append(AZLetter(letter: l, id: id(item), index: i)) }
        }
        return out
    }
}

/// The A–Z jump rail shared by every alphabetical grid: current-position letter red, hovered gray,
/// tap jumps. Callers supply the letters, the active letter, and a jump handler.
struct AZLetterRail: View {
    let letters: [AZLetter]
    let activeLetter: String?
    let onJump: (AZLetter) -> Void
    /// Optional "surprise me" control at the very top of the rail (before "#"): `active` highlights
    /// it (random landing showing), `action` (re)shuffles. nil = no shuffle control.
    var shuffle: (active: Bool, action: () -> Void)? = nil
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            if let shuffle {
                Image(systemName: "shuffle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(shuffle.active ? .red : (hovered == "⇄" ? .gray : .white.opacity(0.55)))
                    .frame(width: 18, height: 17)
                    .background { if hovered == "⇄" { Capsule().fill(.white.opacity(0.18)) } }
                    .contentShape(Rectangle())
                    .onHover { hovered = $0 ? "⇄" : (hovered == "⇄" ? nil : hovered) }
                    .pointingHandCursor()
                    .onTapGesture { shuffle.action() }
                    .help("Shuffle — random comics")
            }
            ForEach(letters, id: \.letter) { entry in
                Text(entry.letter)
                    .font(.system(size: 10, weight: entry.letter == activeLetter ? .bold : .semibold))
                    .foregroundStyle(color(for: entry.letter))
                    .frame(width: 18, height: 15)
                    .background { if entry.letter == hovered { Capsule().fill(.white.opacity(0.18)) } }
                    .contentShape(Rectangle())
                    .onHover { hovered = $0 ? entry.letter : (hovered == entry.letter ? nil : hovered) }
                    .pointingHandCursor()
                    .onTapGesture { onJump(entry) }
            }
        }
        .padding(.vertical, 6)
        .background(.white.opacity(0.06), in: Capsule())
        .padding(.trailing, 6)
    }

    private func color(for letter: String) -> Color {
        if letter == activeLetter { return .red }
        if letter == hovered { return .gray }
        return .white.opacity(0.55)
    }
}

// MARK: - Windowed A–Z cover grid (shared engine for every catalog browser)

/// The one windowed, A–Z-navigable cover grid behind both catalog browsers. It renders a `pageSize`
/// slice starting at `windowStart`, extends the window as you scroll near the end, tracks the active
/// letter from the scroll offset, and — crucially — **jumps by re-windowing**: tapping a rail letter
/// unloads the rest and reloads the slice at that letter, snapping to the top (no long scroll). This
/// keeps the jump behavior identical across servers. Callers supply the items, the shared letter
/// index, a cell, optional `header` (banners / empty state) and `leading` (folders, shown only at the
/// list head), plus hooks for prefetch/anchoring (`onActiveIndex`) and reset (`onReset`).
struct WindowedCoverGrid<Item: Identifiable, Cell: View, Header: View, Leading: View>: View
where Item.ID == String {
    let items: [Item]
    let letters: [AZLetter]
    @Binding var windowStart: Int
    @Binding var windowCount: Int
    /// When this string changes (search / sort / level), the window resets to the top.
    let resetKey: String
    var target: CGFloat = GridStyle.tileTarget
    var pageSize: Int = 400
    var showRail: Bool = true
    /// Scroll-restore target applied once on first appear (nil = start at top).
    var restoreID: String? = nil
    var onActiveIndex: (Int) -> Void = { _ in }
    var onReset: () -> Void = {}
    /// When set, a shuffle control shows atop the rail; `shuffleActive` highlights it and suppresses
    /// the A–Z "you are here" highlight (a random order has no alphabetical position).
    var shuffleActive: Bool = false
    var onShuffle: (() -> Void)? = nil
    /// Called just before a rail letter jump — lets a shuffling caller flip back to the A–Z list so
    /// the jump index lands correctly.
    var onBeforeLetterJump: () -> Void = {}
    @ViewBuilder var header: () -> Header
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var cell: (Item) -> Cell

    @State private var scrollMinY: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var didRestore = false
    private let topID = "wcg-top"
    private let space = "wcgScroll"

    var body: some View {
        GeometryReader { geo in
            let cols = GridStyle.columns(geo.size.width, target: target)
            let total = items.count
            let lo = min(windowStart, max(0, total - 1))
            let hi = min(lo + windowCount, total)
            let slice = lo < hi ? Array(items[lo..<hi]) : []
            let triggerID: String? = hi < total ? slice[max(0, slice.count - 16)].id : nil
            let frac = contentHeight > geo.size.height
                ? min(1, max(0, -scrollMinY / (contentHeight - geo.size.height))) : 0
            let activeIdx = lo + Int(frac * Double(max(0, slice.count - 1)))
            let activeLetter = shuffleActive ? nil : letters.last { $0.index <= activeIdx }?.letter
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { g in
                        Color.clear.preference(key: GridScrollOffsetKey.self,
                                               value: g.frame(in: .named(space)).minY)
                    }
                    .frame(height: 0).id(topID)
                    header()
                    // The columns are fixed width, so centering the grid shifts the first cover
                    // away from the same left guide used by the toolbar and section headings.
                    LazyVGrid(columns: cols, alignment: .leading, spacing: GridStyle.rowSpacing) {
                        if lo == 0 { leading() }
                        ForEach(slice) { item in
                            cell(item).id(item.id)
                                .onAppear {
                                    if item.id == triggerID {
                                        windowCount = min(windowCount + pageSize, total - lo)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, GridStyle.hPadding).padding(.top, 20)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: GridContentHeightKey.self, value: g.size.height)
                    })
                    if hi < total {
                        ProgressView().controlSize(.small).padding(.vertical, 20).frame(maxWidth: .infinity)
                    }
                    Color.clear.frame(height: 24)
                }
                .coordinateSpace(name: space)
                .onPreferenceChange(GridScrollOffsetKey.self) { scrollMinY = $0 }
                .onPreferenceChange(GridContentHeightKey.self) { contentHeight = $0 }
                .onChange(of: activeIdx) { _, idx in onActiveIndex(idx) }
                .onAppear {
                    guard !didRestore, let id = restoreID else { return }
                    didRestore = true
                    for delay in [0.05, 0.25] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
                .overlay(alignment: .trailing) {
                    if showRail && (letters.count > 2 || onShuffle != nil) {
                        AZLetterRail(
                            letters: letters, activeLetter: activeLetter,
                            onJump: { entry in
                                onBeforeLetterJump()
                                windowStart = entry.index
                                windowCount = pageSize
                                DispatchQueue.main.async { proxy.scrollTo(topID, anchor: .top) }
                            },
                            shuffle: onShuffle.map { action in (active: shuffleActive, action: action) })
                    }
                }
                .onChange(of: resetKey) { _, _ in
                    windowStart = 0; windowCount = pageSize
                    onReset()
                    proxy.scrollTo(topID, anchor: .top)
                }
            }
        }
    }
}

/// Publishes a scroll view's top offset (negative as you scroll down) for "you are here" tracking.
struct GridScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
/// Publishes a grid's total content height (for the scroll fraction that drives the A–Z highlight).
struct GridContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Equal side columns keep search centered regardless of title length or action count.
struct SectionToolbar<Location: View, Search: View, Actions: View>: View {
    @ViewBuilder var location: () -> Location
    @ViewBuilder var search: () -> Search
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - GridStyle.hPadding * 2)
            let searchWidth = min(360, width * 0.38)
            let sideWidth = max(0, (width - searchWidth - 24) / 2)
            HStack(spacing: 12) {
                location().lineLimit(1).frame(width: sideWidth, alignment: .leading).clipped()
                search().frame(width: searchWidth)
                actions().frame(width: sideWidth, alignment: .trailing)
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, GridStyle.hPadding)
        }
        .frame(height: 50)
        .buttonStyle(.borderless)
        .tint(.white)
        .background(Color.black)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) }
    }
}

/// Shared one-line section label: title on the left, its count or context on the right.
struct SectionHeading: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail {
                Spacer(minLength: 4)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

struct NavigationSearchField: View {
    let prompt: String
    @Binding var text: String
    var onlineSuggestions = false
    var suggestionTitles: [String] = []
    var submit: () -> Void = {}
    @FocusState private var focused: Bool
    @State private var suggestionsDismissed = true
    @State private var showingHistory = false
    @State private var history = OnlineSearchHistory.shared
    @State private var clickRegions = SearchDropdownClickRegions()

    private var suggestions: [String] {
        showingHistory ? Array(history.recent.prefix(8))
            : (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : history.suggestions(for: text, titles: suggestionTitles))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).focused($focused).onSubmit {
                    if onlineSuggestions { history.record(text); suggestionsDismissed = true }
                    submit()
                }
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
            }
            if onlineSuggestions {
                Button { focused = true; showingHistory = true; suggestionsDismissed = false } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Search history")
                    .pointingHandCursor()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .top) {
            if onlineSuggestions && focused && !suggestionsDismissed && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(showingHistory ? "Recent searches" : "Suggestions")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if showingHistory && !history.recent.isEmpty {
                            Button("Clear history") { history.clear() }
                                .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                                .pointingHandCursor()
                                .background(SearchDropdownClickRegion(regions: clickRegions, action: { history.clear() }))
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 4)
                    ForEach(suggestions, id: \.self) { suggestion in
                        SearchSuggestionRow(title: suggestion, recent: showingHistory) {
                            choose(suggestion)
                        }
                        .background(SearchDropdownClickRegion(regions: clickRegions, action: { choose(suggestion) }))
                    }
                }
                .padding(8)
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                .fixedSize(horizontal: false, vertical: true)
                .background(SearchDropdownClickRegion(regions: clickRegions))
                .offset(y: 40)
            }
        }
        .background(SearchOutsideClickArea(active: onlineSuggestions && focused, regions: clickRegions,
            insideFieldClick: {
                showingHistory = true; suggestionsDismissed = false
            }) {
            showingHistory = false; suggestionsDismissed = true; focused = false
        })
        .onChange(of: text) { _, value in
            showingHistory = false
            suggestionsDismissed = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .onChange(of: focused) { _, value in
            if value {
                if !showingHistory { suggestionsDismissed = true }
            } else if onlineSuggestions {
                showingHistory = false; suggestionsDismissed = true; history.record(text)
            }
        }
        .onDisappear { if onlineSuggestions { history.record(text) } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if onlineSuggestions { showingHistory = false; suggestionsDismissed = true; focused = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusNavigationSearch)) { _ in focused = true }
    }

    private func choose(_ suggestion: String) {
        text = suggestion
        history.record(suggestion)
        showingHistory = false
        suggestionsDismissed = true
        focused = false
        submit()
    }

}

/// Native geometry remains usable when SwiftUI draws the dropdown beyond its toolbar's bounds.
@MainActor
final class SearchDropdownClickRegions {
    var views: [SearchDropdownClickRegion.RegionView] = []
    func containing(_ event: NSEvent) -> [SearchDropdownClickRegion.RegionView] {
        views.filter { view in
            view.window === event.window && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
    }
}

struct SearchDropdownClickRegion: NSViewRepresentable {
    let regions: SearchDropdownClickRegions
    var action: (() -> Void)? = nil
    final class RegionView: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> RegionView {
        let view = RegionView()
        regions.views.append(view)
        context.coordinator.regions = regions
        return view
    }
    func updateNSView(_ view: RegionView, context: Context) { view.action = action }
    final class Coordinator { weak var regions: SearchDropdownClickRegions? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ view: RegionView, coordinator: Coordinator) {
        coordinator.regions?.views.removeAll { $0 === view }
    }
}

/// macOS buttons can leave a text field focused, so focus changes alone cannot dismiss this menu.
struct SearchOutsideClickArea: NSViewRepresentable {
    let active: Bool
    let regions: SearchDropdownClickRegions
    var insideFieldClick: () -> Void = {}
    let dismiss: () -> Void

    final class AreaView: NSView {
        var active = false
        var regions: SearchDropdownClickRegions?
        var dismiss: () -> Void = {}
        var insideFieldClick: () -> Void = {}
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard active, let window else { return event }
            guard event.window === window else { dismiss(); return event }
            let inside = regions?.containing(event) ?? []
            if event.type == .leftMouseDown, let action = inside.compactMap(\.action).first {
                // Apply the selection before dismissal; don't forward the click to the grid underneath.
                action()
                return nil
            }
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) {
                if event.type == .leftMouseDown { insideFieldClick() }
            } else if inside.isEmpty { dismiss() }
            return event
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
    func makeNSView(context: Context) -> AreaView { AreaView() }
    func updateNSView(_ view: AreaView, context: Context) {
        view.active = active; view.regions = regions; view.dismiss = dismiss; view.insideFieldClick = insideFieldClick
    }
    static func dismantleNSView(_ view: AreaView, coordinator: ()) { view.stop() }
}

private struct SearchSuggestionRow: View {
    let title: String
    let recent: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: recent ? "clock" : "magnifyingglass").foregroundStyle(.secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(.white.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).pointingHandCursor().onHover { hovering = $0 }
    }
}

@MainActor
@Observable
final class OnlineSearchHistory {
    static let shared = OnlineSearchHistory()
    private let defaults: UserDefaults
    private let key = "online.recentSearches"
    private(set) var recent: [String]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recent = Array((defaults.stringArray(forKey: key) ?? []).prefix(20))
    }
    func record(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        recent.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        recent.insert(query, at: 0); recent = Array(recent.prefix(20))
        defaults.set(recent, forKey: key)
    }
    func clear() { recent = []; defaults.removeObject(forKey: key) }
    func suggestions(for query: String, titles: [String]) -> [String] {
        let normalized = SearchRank.normalize(query)
        guard !normalized.isEmpty else { return Array(recent.prefix(8)) }
        var seen = Set<String>(), matches: [String] = []
        for title in titles {
            let value = SearchRank.normalize(title)
            guard value.contains(normalized), seen.insert(value).inserted else { continue }
            matches.append(title)
            if matches.count == 8 { break }
        }
        return matches
    }
}

extension Notification.Name {
    static let toggleNavigationSidebar = Notification.Name("toggleNavigationSidebar")
    static let sidebarDidNavigate = Notification.Name("sidebarDidNavigate")
    static let browseBack = Notification.Name("browseBack")
    static let focusNavigationSearch = Notification.Name("focusNavigationSearch")
}
