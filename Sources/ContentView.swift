import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @State private var keyMonitor = KeyMonitor()
    @State private var readerSettings = ReaderSettings.shared
    @State private var library = LibraryModel.shared

    // Page counter caption (toggled with H, off by default).
    @State private var captionOpacity = 0.0
    @State private var captionTask: Task<Void, Never>?
    @State private var captionEnabled = false

    // Transient status toast (chapter actions).
    @State private var toast = ""
    @State private var toastOpacity = 0.0
    @State private var toastTask: Task<Void, Never>?

    // Zoom & pan (screen-space transform over the fitted image).
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero
    @State private var containerSize: CGSize = .zero

    // Captured at the start of a pinch so the whole gesture zooms about a fixed anchor point.
    @State private var zoomStart: CGFloat?
    @State private var panStart: CGSize?
    private let hardMaxZoom: CGFloat = 8
    private let minimumUsefulMaxZoom: CGFloat = 2.5

    // Base fit mode (cycled with Z); applied as a starting zoom over the page-fit.
    @State private var fitMode: FitMode = .fit

    enum FitMode: String, CaseIterable {
        case fit, width, height, actual

        var label: String {
            switch self {
            case .fit: return "Fit page"
            case .width: return "Fit width"
            case .height: return "Fit height"
            case .actual: return "Actual size"
            }
        }
    }

    // Hides the pointer after 3 seconds of mouse inactivity while a comic is open.
    @State private var cursorHider = CursorAutohider()

    // Chapter thumbnail grid (toggled with T).
    @State private var showChapterGrid = false
    @State private var chapterGridPage = 0
    @State private var thumbnailTask: Task<Void, Never>?
    private let thumbCache = ThumbnailCache.shared

    // End-of-chapter continuation card.
    @State private var upNextThumbnail: CGImage?

    private struct UpNextChapter: Hashable {
        let ordinal: Int
        let page: Int
        let index: Int
        let url: URL
        let name: String
    }

    @ViewBuilder
    private var readerContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.current != nil {
                GeometryReader { geo in
                    let maxZoom = maximumZoom(container: geo.size)
                    let z = min(max(zoom, 1), maxZoom)
                    let raw = CGSize(width: pan.width + dragOffset.width,
                                     height: pan.height + dragOffset.height)
                    let off = clampOffset(raw, zoom: z, container: geo.size)

                    pages
                        .scaleEffect(z)
                        .offset(off)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .gesture(magnifyGesture(container: geo.size))
                        .simultaneousGesture(panGesture(container: geo.size))
                        .simultaneousGesture(
                            SpatialTapGesture(count: 2).onEnded { value in
                                smartZoom(at: value.location, container: geo.size)
                            }
                        )
                        .onAppear {
                            containerSize = geo.size
                            applyFitMode(container: geo.size, animated: false)
                        }
                        .onChange(of: geo.size) { _, size in
                            containerSize = size
                            applyFitMode(container: size, animated: false)
                        }
                }
            } else if model.isOpening {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)

                    Text("Opening \(model.openingName ?? "comic")…")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 360)
                }
            } else if let failed = model.failedName {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)

                    Text("Couldn't open \(failed)")
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)

                    Text("The file may be damaged, or in a format that can't be read.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.45))

                    if let url = model.failedURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .padding(.top, 4)
                    }
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(40)
            } else {
                Text("Open an image  (⌘O)")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    var body: some View {
        readerLifecycle
    }

    private var readerLifecycle: some View {
        readerEvents
            .onAppear(perform: handleReaderAppear)
            .onDisappear(perform: handleReaderDisappear)
            .onChange(of: model.current != nil) { _, _ in
                handleCurrentChanged()
            }
            .onChange(of: model.openGeneration) { _, _ in
                handleOpenGenerationChanged()
            }
            .onChange(of: model.renderTick) { _, _ in
                handleRenderTick()
            }
            .onChange(of: model.spreadEnabled) { _, _ in
                handleSpreadChanged()
            }
            .onChange(of: readerSettings.coverAloneInSpread) { _, value in
                model.setCoverAloneInSpread(value)
            }
            .onChange(of: model.transientMessage) { _, message in
                handleTransientMessage(message)
            }
            .onChange(of: model.chapters) { _, _ in
                handleChaptersChanged()
            }
            .task(id: model.index) {
                await preloadUpNextThumbnail()
            }
            .task {
                preloadChapterThumbs()
            }
    }

    private var readerEvents: some View {
        readerSurface
            .dropDestination(for: URL.self) { urls, _ in
                handleDrop(urls)
            }
            .navigationTitle(model.currentName ?? "Comic Viewer")
    }

    private var readerSurface: some View {
        readerContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { pinnedOverlays }
            .overlay { rotatedToRead { readingProgressBar } }
            .overlay { upNextOverlay }
            .overlay { chapterGridOverlay }
            .overlay { shortcutOverlay }
    }

    @ViewBuilder
    private var chapterGridOverlay: some View {
        if showChapterGrid {
            rotatedToRead { chapterGrid }
        }
    }

    private func handleReaderAppear() {
        keyMonitor.start(key: handleKey, scroll: handleScroll)
        updateReaderState()
    }

    private func handleReaderDisappear() {
        keyMonitor.stop()
        cursorHider.stop()
        cancelTransientTasks()
        thumbnailTask?.cancel()
        thumbnailTask = nil
    }

    private func handleCurrentChanged() {
        updateReaderState()
    }

    private func handleOpenGenerationChanged() {
        resetViewForNewComic()
    }

    private func handleRenderTick() {
        applyFitMode(container: containerSize, animated: false)
        flashCaption()
    }

    private func handleSpreadChanged() {
        applyFitMode(container: containerSize, animated: false)
    }

    private func handleTransientMessage(_ message: String?) {
        if let message {
            flashToast(message)
        }
    }

    private func handleChaptersChanged() {
        preloadChapterThumbs()
    }

    @discardableResult
    private func handleDrop(_ urls: [URL]) -> Bool {
        model.open(urls: urls)
        return true
    }

    private func shortcutOverlayContent() -> some View {
        ShortcutsOverlay { router.showShortcuts = false }
    }

    @ViewBuilder
    private var shortcutOverlay: some View {
        if router.showShortcuts {
            rotatedToRead {
                shortcutOverlayContent()
            }
        }
    }

    private func preloadUpNextThumbnail() async {
        guard let url = upNextChapter?.url else {
            upNextThumbnail = nil
            return
        }
        upNextThumbnail = await thumbCache.thumbnail(for: url, maxPixel: 240)
    }

    private func updateReaderState() {
        if model.current != nil {
            cursorHider.start()
        } else {
            cursorHider.stop()
        }
    }

    private func cancelTransientTasks() {
        captionTask?.cancel()
        captionTask = nil
        toastTask?.cancel()
        toastTask = nil
    }

    /// Warm the thumbnail cache for the chapters so the T grid is fast when opened.
    /// A new preload cancels the previous one so chapter changes cannot build a queue of
    /// overlapping preload tasks.
    private func preloadChapterThumbs() {
        thumbnailTask?.cancel()
        thumbnailTask = nil

        let urls = model.chapterEntries.map(\.url)
        guard !urls.isEmpty else { return }

        let cache = thumbCache
        thumbnailTask = Task {
            await cache.preload(urls, maxPixel: 500)
        }
    }

    /// Uses the model's reading orientation for the HUD. Two-page spreads are already laid out
    /// upright side-by-side, so the HUD should not receive an additional 90° rotation there.
    private var isPortrait: Bool {
        !model.spreadEnabled && model.readingPortrait
    }

    /// Wrap a full-screen overlay so it is oriented the same way as the page.
    @ViewBuilder
    private func rotatedToRead<Content: View>(
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        GeometryReader { geo in
            content()
                .frame(
                    width: isPortrait ? geo.size.height : geo.size.width,
                    height: isPortrait ? geo.size.width : geo.size.height
                )
                .rotationEffect(isPortrait ? .degrees(90) : .zero)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: Pages

    /// The page content under the zoom/pan transform: a single page, or in two-page spread,
    /// the current and facing pages upright and side-by-side as a physical open-book layout.
    @ViewBuilder
    private var pages: some View {
        if model.spreadEnabled,
           let first = model.current,
           let second = model.secondary {
            let (left, right) = readerSettings.readingDirection.arrangeSpread(first, second)

            HStack(spacing: max(0, readerSettings.spreadGutter)) {
                RotatingImageView(image: left, rotate: false)
                RotatingImageView(image: right, rotate: false)
            }
        } else if let img = model.current {
            RotatingImageView(image: img, rotate: model.readingPortrait)
        }
    }

    // MARK: Fit modes

    /// A new comic opened → drop the per-comic fit override back to the default and re-fit.
    private func resetViewForNewComic() {
        fitMode = .fit
        applyFitMode(container: containerSize, animated: false)
    }

    /// `Z`: snap back to the fitted view when zoomed in; only cycle Fit page → width → height →
    /// actual when already at the fit baseline. So one key both "fits" and changes the fit style.
    private func cycleFitMode() {
        if let img = model.current, containerSize.width > 0,
           zoom > fitBaseline(img, container: containerSize) + 0.01 {
            applyFitMode(container: containerSize, animated: true)
            flashToast("Fit to screen")
            return
        }
        let all = FitMode.allCases
        fitMode = all[(all.firstIndex(of: fitMode)! + 1) % all.count]
        applyFitMode(container: containerSize, animated: true)
        flashToast(fitMode.label)
    }

    /// The fit mode actually applied for a page. The default (`.fit`) is content-aware: a landscape
    /// (wide) page fills the width and pans vertically instead of shrinking to fit the whole page.
    /// Explicit modes chosen via `Z` (width/height/actual) and spread mode are honored as-is.
    private func effectiveFitMode(_ img: DisplayImage, container: CGSize) -> FitMode {
        // In Vertical view, "fit to width" applies only to **originally-landscape** pages (wider than
        // tall); portrait-native pages fit the whole screen even though they're shown rotated.
        guard fitMode == .fit, !model.spreadEnabled,
              model.readingPortrait, ReaderSettings.shared.fitWideToWidth else { return fitMode }
        return img.isPortrait ? .fit : .width
    }

    /// The starting (fitted) zoom for a page under the current mode — the "you're not zoomed" level.
    private func fitBaseline(_ img: DisplayImage, container: CGSize) -> CGFloat {
        guard !model.spreadEnabled else { return 1 }
        return min(max(fitZoom(effectiveFitMode(img, container: container), img: img, container: container), 1),
                   maximumZoom(container: container))
    }

    /// Apply the current fit mode as the starting zoom over the actual fitted page size.
    /// In spread mode the two-page layout fills the reader, so Fit page is used.
    private func applyFitMode(container: CGSize, animated: Bool) {
        guard let img = model.current, container.width > 0, container.height > 0 else { return }

        let mode = effectiveFitMode(img, container: container)
        let target = model.spreadEnabled
            ? 1
            : min(
                max(fitZoom(mode, img: img, container: container), 1),
                maximumZoom(container: container)
            )

        let apply = {
            zoom = target

            if mode == .width && !model.spreadEnabled {
                // Start at the top of the page rather than vertically centered.
                let fitted = fittedSize(img, container: container)
                let maxY = max(0, (zoom * fitted.height - container.height) / 2)
                pan = clampOffset(
                    CGSize(width: 0, height: maxY),
                    zoom: zoom,
                    container: container
                )
            } else {
                pan = .zero
            }
        }

        if animated {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85), apply)
        } else {
            apply()
        }
    }

    /// Zoom factor (>= 1) that realizes a fit mode relative to the page-fit size.
    private func fitZoom(_ mode: FitMode, img: DisplayImage, container: CGSize) -> CGFloat {
        let fitted = fittedSize(img, container: container)
        guard fitted.width > 0, fitted.height > 0 else { return 1 }

        switch mode {
        case .fit:
            return 1

        case .width:
            return container.width / fitted.width

        case .height:
            return container.height / fitted.height

        case .actual:
            let spin = model.readingPortrait && img.isPortrait
            let nativeW = spin
                ? CGFloat(img.cgImage.height)
                : CGFloat(img.cgImage.width)
            return nativeW / fitted.width
        }
    }

    /// The on-screen size of a page at zoom 1, mirroring RotatingImageView's fit + rotation.
    private func fittedSize(_ img: DisplayImage, container: CGSize) -> CGSize {
        let iw = CGFloat(img.cgImage.width)
        let ih = CGFloat(img.cgImage.height)
        let spin = model.readingPortrait && img.isPortrait
        let aspect = spin ? ih / iw : iw / ih
        return RotatingImageView.fit(aspect: aspect, in: container)
    }

    /// The actual base content size used by the zoom/pan geometry.
    /// A single page uses its fitted dimensions. A spread occupies the reader container.
    private func baseContentSize(container: CGSize) -> CGSize {
        guard let img = model.current else { return .zero }
        return model.spreadEnabled
            ? container
            : fittedSize(img, container: container)
    }

    /// Maximum useful zoom for the current page. The upper limit adapts to source resolution so
    /// low-resolution pages do not pretend to offer useful extreme magnification, while large
    /// scans can still reach a little beyond native pixel size.
    private func maximumZoom(container: CGSize) -> CGFloat {
        guard container.width > 0, container.height > 0 else {
            return hardMaxZoom
        }

        guard let img = model.current, !model.spreadEnabled else {
            return hardMaxZoom
        }

        let fitted = fittedSize(img, container: container)
        guard fitted.width > 0 else {
            return hardMaxZoom
        }

        let spin = model.readingPortrait && img.isPortrait
        let nativeWidth = spin
            ? CGFloat(img.cgImage.height)
            : CGFloat(img.cgImage.width)
        let actualZoom = max(1, nativeWidth / fitted.width)

        // Keep a little headroom beyond native size without allowing runaway magnification.
        return min(hardMaxZoom, max(minimumUsefulMaxZoom, actualZoom * 1.25))
    }

    // MARK: Zoom & pan

    /// Pinch-to-zoom anchored at the gesture's start point. The content point under the fingers
    /// remains fixed throughout the gesture.
    private func magnifyGesture(container: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStart == nil {
                    zoomStart = zoom
                    panStart = pan
                }

                let start = zoomStart ?? zoom
                let basePan = panStart ?? pan
                let target = min(
                    max(start * value.magnification, 1),
                    maximumZoom(container: container)
                )

                zoom = target
                pan = anchoredPan(
                    target: target,
                    fromZoom: start,
                    fromPan: basePan,
                    anchor: value.startLocation,
                    container: container
                )
            }
            .onEnded { _ in
                pan = clampOffset(pan, zoom: zoom, container: container)
                zoomStart = nil
                panStart = nil
            }
    }

    /// Keeps the content point under anchor fixed as zoom changes.
    /// Math is relative to the container center, which is the scaleEffect anchor.
    private func anchoredPan(
        target: CGFloat,
        fromZoom: CGFloat,
        fromPan: CGSize,
        anchor: CGPoint,
        container: CGSize
    ) -> CGSize {
        guard fromZoom > 0 else { return fromPan }

        let cx = anchor.x - container.width / 2
        let cy = anchor.y - container.height / 2
        let ratio = target / fromZoom

        let newPan = CGSize(
            width: cx - ratio * (cx - fromPan.width),
            height: cy - ratio * (cy - fromPan.height)
        )

        return clampOffset(newPan, zoom: target, container: container)
    }

    private func panGesture(container: CGSize) -> some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in
                state = zoom > 1 ? value.translation : .zero
            }
            .onEnded { value in
                guard zoom > 1 else { return }

                let moved = CGSize(
                    width: pan.width + value.translation.width,
                    height: pan.height + value.translation.height
                )
                pan = clampOffset(moved, zoom: zoom, container: container)
            }
    }

    /// Clamps pan using the actual fitted content dimensions rather than assuming that the
    /// image fills the entire reader at zoom 1. This prevents extra empty space at portrait
    /// or landscape page boundaries.
    private func clampOffset(_ offset: CGSize, zoom: CGFloat, container: CGSize) -> CGSize {
        guard zoom > 1 else { return .zero }

        let content = baseContentSize(container: container)
        guard content.width > 0, content.height > 0 else { return .zero }

        let maxX = max(0, (zoom * content.width - container.width) / 2)
        let maxY = max(0, (zoom * content.height - container.height) / 2)

        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private func zoomBy(_ factor: CGFloat) {
        guard containerSize.width > 0, containerSize.height > 0 else { return }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            zoom = min(
                max(zoom * factor, 1),
                maximumZoom(container: containerSize)
            )
            pan = clampOffset(pan, zoom: zoom, container: containerSize)
        }
    }

    /// Two-finger trackpad pan when zoomed. Returns true to consume the scroll event.
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard zoom > 1 else { return false }

        let moved = CGSize(
            width: pan.width + event.scrollingDeltaX,
            height: pan.height + event.scrollingDeltaY
        )
        pan = clampOffset(moved, zoom: zoom, container: containerSize)
        return true
    }

    /// Keyboard pan when zoomed. dx/dy are direction (+1 / -1); step is a fraction of the view.
    private func panBy(dx: CGFloat = 0, dy: CGFloat = 0) -> Bool {
        guard zoom > 1 else { return false }

        let step: CGFloat = 0.18
        let moved = CGSize(
            width: pan.width + dx * containerSize.width * step,
            height: pan.height + dy * containerSize.height * step
        )
        let clamped = clampOffset(moved, zoom: zoom, container: containerSize)

        let didMove = abs(clamped.width - pan.width) > 0.5 || abs(clamped.height - pan.height) > 0.5
        if didMove {
            withAnimation(.easeOut(duration: 0.12)) {
                pan = clamped
            }
        }
        return didMove
    }

    /// Pan while zoomed. If that direction is already at the page boundary, navigate to the
    /// adjacent page instead. This makes keyboard reading continuous at the edges.
    private func panOrNavigate(
        dx: CGFloat = 0,
        dy: CGFloat = 0,
        navigate: () -> Void
    ) {
        guard zoom > 1 else {
            navigate()
            return
        }

        if !panBy(dx: dx, dy: dy) {
            navigate()
        }
    }

    /// Double-click smart zoom: toggles between fit and a 2.5x view centered on the click point.
    private func smartZoom(at point: CGPoint, container: CGSize) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            if zoom > 1 {
                resetZoom()
            } else {
                let target: CGFloat = 2.5
                zoom = target
                pan = anchoredPan(
                    target: target,
                    fromZoom: 1,
                    fromPan: .zero,
                    anchor: point,
                    container: container
                )
            }
        }
    }

    private func resetZoom() {
        zoom = 1
        pan = .zero
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
    }

    /// Distance of a pinned pill's center from the window edge it hugs.
    private let overlayMargin: CGFloat = 60

    /// A thin red bar pinned to the bottom edge in reading orientation.
    private var upNextChapter: UpNextChapter? {
        guard model.current != nil, !showChapterGrid, !router.showShortcuts else { return nil }

        let entries = model.chapterEntries
        guard entries.count > 1,
              let currentOrdinal = entries.lastIndex(where: { $0.index <= model.index }),
              entries.indices.contains(currentOrdinal + 1)
        else { return nil }

        let next = entries[currentOrdinal + 1]

        // In single-page mode this is the final page. In spread mode the reader advances by two,
        // so the last visible spread begins two pages before the next chapter.
        let lastVisibleStart = model.spreadEnabled
            ? model.spreadStartIndex(for: next.index - 1)
            : next.index - 1
        guard model.index >= lastVisibleStart else { return nil }

        return UpNextChapter(
            ordinal: next.ordinal,
            page: next.page,
            index: next.index,
            url: next.url,
            name: next.name
        )
    }

    @ViewBuilder
    private var upNextOverlay: some View {
        if let next = upNextChapter {
            rotatedToRead {
                VStack {
                    Spacer()

                    HStack {
                        Spacer()

                        Button {
                            model.jumpToChapter(orderedIndex: next.ordinal - 1)
                        } label: {
                            HStack(spacing: 12) {
                                Group {
                                    if let cg = upNextThumbnail {
                                        Image(decorative: cg, scale: 1)
                                            .resizable()
                                            .interpolation(.medium)
                                            .scaledToFill()
                                    } else {
                                        Image(systemName: "bookmark.fill")
                                            .font(.title3)
                                            .foregroundStyle(.white.opacity(0.45))
                                    }
                                }
                                .frame(width: 52, height: 74)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Up Next")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .textCase(.uppercase)

                                    Text(next.name)
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                        .lineLimit(2)

                                    Text("Chapter \(next.ordinal)  •  p.\(next.page)")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.55))

                                    Label("Continue", systemImage: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.top, 2)
                                }

                                Image(systemName: "chevron.right")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .padding(.leading, 2)
                            }
                            .padding(14)
                            .frame(width: 330, alignment: .leading)
                            .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(.white.opacity(0.12), lineWidth: 1)
                            }
                            .shadow(radius: 18)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                    .padding(.trailing, 58)
                    .padding(.bottom, 78)
                }
            }
        }
    }

    @ViewBuilder
    private var readingProgressBar: some View {
        if model.current != nil, ReaderSettings.shared.showProgressBar {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                readerTimeline
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
        }
    }

    @ViewBuilder
    private var readerTimeline: some View {
        switch readerSettings.timelineScope {
        case .chapter:
            chapterTimeline
        case .issue:
            issueTimeline
        case .series:
            seriesTimeline
        }
    }

    private var issueTimeline: some View {
        PageScrubber(
            urls: model.items,
            currentIndex: model.index,
            spreadEnabled: model.spreadEnabled,
            readingDirection: readerSettings.readingDirection,
            cache: thumbCache,
            showChapterMarkers: readerSettings.showChapterMarkers,
            chapterIndices: model.chapterEntries.map(\.index),
            coverAloneInSpread: readerSettings.coverAloneInSpread,
            onSelect: { index in
                model.goTo(index: index)
            }
        )
    }

    @ViewBuilder
    private var chapterTimeline: some View {
        if let range = currentChapterRange, range.end > range.start {
            PageScrubber(
                urls: Array(model.items[range.start..<range.end]),
                currentIndex: model.index - range.start,
                spreadEnabled: model.spreadEnabled,
                readingDirection: readerSettings.readingDirection,
                cache: thumbCache,
                showChapterMarkers: false,
                chapterIndices: [],
                coverAloneInSpread: readerSettings.coverAloneInSpread,
                onSelect: { index in
                    model.goTo(index: range.start + index)
                }
            )
        } else {
            issueTimeline
        }
    }

    @ViewBuilder
    private var seriesTimeline: some View {
        let comics = seriesTimelineComics
        if comics.count > 1, let current = currentLibraryComic {
            SeriesScrubber(
                comics: comics,
                currentComicKey: currentComicKeyForTimeline(current),
                currentIndex: model.index,
                currentPageCount: model.items.count,
                showChapterMarkers: readerSettings.showChapterMarkers,
                chapterIndices: model.chapterEntries.map(\.index),
                readingDirection: readerSettings.readingDirection,
                cache: thumbCache,
                onSelect: handleSeriesTimelineSelection
            )
        } else {
            issueTimeline
        }
    }

    private var currentChapterRange: (start: Int, end: Int)? {
        let entries = model.chapterEntries
        guard !model.items.isEmpty else { return nil }

        let start: Int
        let nextEnd: Int

        if let current = entries.lastIndex(where: { $0.index <= model.index }) {
            start = entries[current].index
            nextEnd = entries.indices.contains(current + 1)
                ? entries[current + 1].index
                : model.items.count
        } else {
            start = 0
            nextEnd = entries.first?.index ?? model.items.count
        }

        guard start < nextEnd else { return nil }
        return (start, nextEnd)
    }

    private var currentLibraryComic: Comic? {
        guard let key = model.currentComicKey else { return nil }
        return library.comics.first { CentralStore.key(for: $0.url) == key }
    }

    private var seriesTimelineComics: [Comic] {
        guard let current = currentLibraryComic else { return [] }
        return library.comics
            .filter { $0.series == current.series }
            .sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    private func currentComicKeyForTimeline(_ comic: Comic) -> String {
        CentralStore.key(for: comic.url)
    }

    private func handleSeriesTimelineSelection(_ comic: Comic, _ fraction: Double) {
        let knownCount = comic == currentLibraryComic
            ? model.items.count
            : max(comic.progress?.count ?? 0, comic.pageCount)

        let startIndex: Int? = knownCount > 1
            ? Int((min(max(fraction, 0), 1) * Double(knownCount - 1)).rounded())
            : nil

        if comic == currentLibraryComic {
            if let startIndex {
                model.goTo(index: startIndex)
            } else {
                model.first()
            }
        } else if comic.isRemote {
            model.openRemote(comic, startIndex: startIndex)
        } else {
            model.open(urls: [comic.url], startIndex: startIndex)
        }
    }

    private var pinnedOverlays: some View {
        GeometryReader { geometry in
            let size = geometry.size

            captionPill
                .rotationEffect(isPortrait ? .degrees(90) : .zero)
                .position(
                    isPortrait
                        ? CGPoint(x: size.width - overlayMargin, y: size.height / 2)
                        : CGPoint(x: size.width / 2, y: size.height - overlayMargin)
                )

            toastPill
                .rotationEffect(isPortrait ? .degrees(90) : .zero)
                .position(
                    isPortrait
                        ? CGPoint(x: overlayMargin, y: size.height / 2)
                        : CGPoint(x: size.width / 2, y: overlayMargin)
                )
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var captionPill: some View {
        if model.currentName != nil {
            HStack(spacing: 8) {
                if model.isCurrentChapter {
                    Circle()
                        .fill(.red)
                        .frame(width: 11, height: 11)
                }

                Text(model.counter)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .opacity(captionOpacity)
        }
    }

    @ViewBuilder
    private var toastPill: some View {
        if !toast.isEmpty {
            pill(toast)
                .opacity(toastOpacity)
        }
    }

    private var chapterGrid: some View {
        ChapterGridOverlay(
            entries: model.chapterEntries,
            currentIndex: model.index,
            cache: thumbCache,
            pageIndex: $chapterGridPage,
            onSelect: { index in
                model.goTo(index: index)
                withAnimation(.easeInOut(duration: 0.12)) {
                    showChapterGrid = false
                }
            },
            onClose: {
                withAnimation(.easeInOut(duration: 0.12)) {
                    showChapterGrid = false
                }
            },
            onRename: { index, name in model.renameChapter(atIndex: index, to: name) },
            onDelete: { index in model.deleteChapter(atIndex: index) }
        )
        .transition(.opacity)
    }

    // MARK: Transient overlays

    private func flashCaption() {
        guard captionEnabled else { return }

        captionTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            captionOpacity = 1
        }

        captionTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }

            withAnimation(.easeIn(duration: 0.5)) {
                captionOpacity = 0
            }
        }
    }

    private func toggleCaption() {
        captionEnabled.toggle()

        if captionEnabled {
            flashCaption()
        } else {
            captionTask?.cancel()
            captionTask = nil
            withAnimation(.easeIn(duration: 0.25)) {
                captionOpacity = 0
            }
        }
    }

    private func flashToast(_ text: String) {
        toast = text
        toastTask?.cancel()

        withAnimation(.easeOut(duration: 0.15)) {
            toastOpacity = 1
        }

        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }

            withAnimation(.easeIn(duration: 0.5)) {
                toastOpacity = 0
            }
        }
    }

    // MARK: Keys

    /// Handles navigation and reader shortcuts. Printable shortcuts use the actual characters
    /// where possible so they are less dependent on physical key positions / keyboard layout.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard !flags.contains(.command) else { return false }

        let shift = flags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // While the chapter grid is open, keys drive it and are swallowed.
        if showChapterGrid {
            switch event.keyCode {
            case 53: // Esc
                withAnimation(.easeInOut(duration: 0.12)) {
                    showChapterGrid = false
                }

            case 123: // Left
                chapterGridPage = max(0, chapterGridPage - 1)

            case 124: // Right
                let maxPage = max(0, (model.chapterEntries.count - 1) / 6)
                chapterGridPage = min(maxPage, chapterGridPage + 1)

            default:
                if key == "t" {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showChapterGrid = false
                    }
                }
            }

            return true
        }

        // Navigation/function keys remain key-code based because they are not layout-dependent.
        // In RTL, the horizontal arrow meaning is reversed: the left arrow advances and the right
        // arrow goes back. Pan directions remain physical so zoomed pages can be explored naturally.
        let rightArrowAdvances = readerSettings.readingDirection.rightArrowAdvances

        switch event.keyCode {
        case 53: // Esc: close help / fullscreen / library
            if router.showShortcuts {
                withAnimation(.easeInOut(duration: 0.12)) {
                    router.showShortcuts = false
                }
                return true
            }

            if let window = event.window ?? NSApp.keyWindow,
               window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                return true
            }

            AppRouter.shared.escapeBack()
            return true

        case 123: // Left
            if shift {
                flashToast(rightArrowAdvances ? model.prevChapter() : model.nextChapter())
            } else {
                panOrNavigate(dx: 1) { rightArrowAdvances ? model.prev() : model.next() }
            }
            return true

        case 124: // Right
            if shift {
                flashToast(rightArrowAdvances ? model.nextChapter() : model.prevChapter())
            } else {
                panOrNavigate(dx: -1) { rightArrowAdvances ? model.next() : model.prev() }
            }
            return true

        case 126: // Up
            if shift {
                flashToast(model.prevChapter())
            } else {
                panOrNavigate(dy: 1) { model.prev() }
            }
            return true

        case 125: // Down
            if shift {
                flashToast(model.nextChapter())
            } else {
                panOrNavigate(dy: -1) { model.next() }
            }
            return true

        case 49: // Space
            model.next()
            return true

        case 115: // Home
            model.first()
            return true

        case 119: // End
            model.last()
            return true

        default:
            break
        }

        // Layout-aware printable shortcuts.
        switch key {
        case "t": // Chapter thumbnail grid
            if model.chapterEntries.isEmpty {
                flashToast("No chapters")
            } else {
                chapterGridPage = 0
                withAnimation(.easeInOut(duration: 0.12)) {
                    showChapterGrid = true
                }
            }
            return true

        case "1": // Start of current chapter
            model.firstOfChapter()
            return true

        case "c": // Toggle chapter
            flashToast(model.toggleChapter())
            return true

        case "f": // Fullscreen
            toggleFullScreen(event.window)
            return true

        case "h": // Caption
            toggleCaption()
            return true

        case "r": // Reading rotation
            flashToast(model.toggleReadingRotation())
            return true

        case "w": // Two-page spread
            flashToast(model.toggleSpread())
            return true

        case "z": // Fit mode
            cycleFitMode()
            return true

        case "+", "=": // Zoom in / keypad +
            zoomBy(1.25)
            return true

        case "-": // Zoom out
            zoomBy(0.8)
            return true

        case "0": // Start of whole book
            model.first()
            return true

        case "/": // Shift + / = help
            if shift {
                withAnimation(.easeInOut(duration: 0.12)) {
                    router.showShortcuts.toggle()
                }
                return true
            }
            return false

        default:
            break
        }

        return false
    }

    private func toggleFullScreen(_ window: NSWindow?) {
        (window ?? NSApp.keyWindow)?.toggleFullScreen(nil)
    }
}

/// Hides the mouse pointer after exactly 3 seconds of mouse inactivity while the comic reader
/// is active. It works in both windowed and fullscreen mode because it is tied to the reader view,
/// not to the window style mask.
///
/// Mouse movement immediately reveals the cursor and restarts the three-second countdown. The
/// settings changed on the app's visible windows are restored when the reader disappears.
@MainActor
final class CursorAutohider {
    private var monitor: Any?
    private var idle: Task<Void, Never>?
    private let idleSeconds: Double = 3

    // Only windows active during the reader session are changed, and their original settings
    // are restored when the reader disappears. This keeps cursor handling local to the reader.
    private var trackedWindows: [(window: NSWindow, acceptsMouseMovedEvents: Bool)] = []
    private var keyWindowObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var resignationObserver: NSObjectProtocol?

    func start() {
        stop(reveal: true)
        NSCursor.setHiddenUntilMouseMoves(false)

        trackWindow(NSApp.keyWindow ?? NSApp.mainWindow)

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged
            ]
        ) { [weak self] event in
            self?.mouseMoved(event)
            return event
        }

        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, let window = notification.object as? NSWindow else { return }
                self.trackWindow(window)
                self.bump()
            }
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.bump()
            }
        }

        resignationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reveal()
            }
        }

        bump()
    }

    func stop() {
        stop(reveal: true)
    }

    private func stop(reveal: Bool) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        idle?.cancel()
        idle = nil

        if let observer = keyWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            keyWindowObserver = nil
        }

        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
            activationObserver = nil
        }

        if let observer = resignationObserver {
            NotificationCenter.default.removeObserver(observer)
            resignationObserver = nil
        }

        for entry in trackedWindows {
            entry.window.acceptsMouseMovedEvents = entry.acceptsMouseMovedEvents
        }
        trackedWindows.removeAll()

        if reveal {
            NSCursor.setHiddenUntilMouseMoves(false)
        }
    }

    private func trackWindow(_ window: NSWindow?) {
        guard let window else { return }
        guard !trackedWindows.contains(where: { $0.window === window }) else { return }

        let previous = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        trackedWindows.append((window: window, acceptsMouseMovedEvents: previous))
    }

    private func mouseMoved(_ event: NSEvent) {
        guard NSApp.isActive, let window = event.window else { return }
        guard trackedWindows.contains(where: { $0.window === window }) else { return }
        bump()
    }

    private func reveal() {
        idle?.cancel()
        idle = nil
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    /// Mouse movement immediately reveals the cursor and restarts the three-second countdown.
    private func bump() {
        guard NSApp.isActive else { return }

        NSCursor.setHiddenUntilMouseMoves(false)
        idle?.cancel()

        idle = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: .seconds(self.idleSeconds))
            guard !Task.isCancelled else { return }

            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}
