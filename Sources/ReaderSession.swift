import SwiftUI
import AppKit
import Observation
import ImageIO

/// The stateful reading session for one currently-open comic.
///
/// ReaderSession owns the active reading session, image loading, orientation and reader caches.
/// Navigation and chapter semantics live in ReaderNavigation; persistence lives in ReaderStateStore. AppModel remains responsible for
/// deciding *how to open* a URL/source and delegates the resulting page set to this session.
@MainActor
@Observable
final class ReaderSession {
    private var navigation = ReaderNavigation()
    private(set) var current: DisplayImage?
    private(set) var renderTick = 0
    private(set) var secondary: DisplayImage?
    private(set) var failedName: String?
    private(set) var failedURL: URL?
    private(set) var transientMessage: String?
    private(set) var isOpening = false
    private(set) var openingName: String?

    var items: [URL] { navigation.items }
    var index: Int { navigation.index }
    var spreadEnabled: Bool { navigation.spreadEnabled }
    var chapters: Set<String> { navigation.chapters }
    var chapterNames: [String: String] { navigation.chapterNames }
    private var comicKey: String?
    private var manualRotate: Bool?
    private var loadTask: Task<Void, Never>?
    private var orientationProbeTask: Task<Void, Never>?
    private var pagesLandscape = true
    private var source: ReaderPageSource = .local(streamer: nil)
    private var openSeq = 0

    private let cache = ImageCache()
    private let stateStore = ReaderStateStore()
    private var loadToken = 0
    private var openStartedAt: UInt64?

    var counter: String {
        items.isEmpty ? "" : "\(index + 1) / \(items.count)"
    }

    var currentName: String? {
        items.indices.contains(index) ? items[index].lastPathComponent : nil
    }

    /// Whether the current comic is rendered in rotated landscape mode.
    var readingPortrait: Bool {
        manualRotate ?? ReaderSettings.shared.defaultView.rotated
    }

    /// Stable library/state key for the currently opened comic.
    var currentComicKey: String? { comicKey }

    /// Bumped every time a comic begins opening.
    var openGeneration: Int { openSeq }

    /// Reset session state for a new source while keeping the reader object alive.
    ///
    /// Returns the generation used to reject stale asynchronous work from a previous source.
    @discardableResult
    func prepareForOpen(name: String, remote: Bool) -> Int {
        loadTask?.cancel()
        loadTask = nil
        orientationProbeTask?.cancel()
        orientationProbeTask = nil
        stateStore.cancel()

        current = nil
        secondary = nil
        failedName = nil
        failedURL = nil
        isOpening = true
        openingName = name
        source = remote ? .remote : .local(streamer: nil)
        manualRotate = nil
        pagesLandscape = true
        openSeq += 1
        openStartedAt = ReaderPerformance.now()
        ReaderPerformance.event("reader_open source=\(remote ? "remote" : "local")")
        return openSeq
    }

    func setRemoteMode(_ remote: Bool) {
        if remote {
            source = .remote
        } else {
            source = .local(streamer: nil)
        }
    }

    func setStreamer(_ streamer: ArchiveStreamer?) {
        guard !source.isRemote else { return }
        source = .local(streamer: streamer)
    }

    @discardableResult
    func toggleReadingRotation() -> String {
        orientationProbeTask?.cancel()
        orientationProbeTask = nil
        manualRotate = !readingPortrait
        return readingPortrait ? "Vertical (pages rotated)" : "Horizontal (as-is)"
    }

    /// Shared setup used by folder, archive and multi-file opens.
    func beginComic(
        items newItems: [URL],
        folder newFolder: URL?,
        comicKey newKey: String?,
        legacyStateURLs newLegacy: [URL] = [],
        initialImage: URL? = nil,
        start explicitStart: Int? = nil
    ) {
        comicKey = newKey
        stateStore.configure(
            comicKey: newKey,
            legacyStateURLs: newLegacy
        )

        navigation.configure(
            items: newItems,
            folder: newFolder,
            coverAloneInSpread: ReaderSettings.shared.coverAloneInSpread
        )

        if let first = items.first, first.isFileURL, let info = ImageLoader.probe(first) {
            pagesLandscape = !info.isPortrait
        } else {
            pagesLandscape = true
        }

        loadState()

        var start = explicitStart ?? 0
        if let initialImage, let i = items.firstIndex(of: initialImage) {
            start = i
            if i == 0, let r = navigation.resumeIndex(), r != 0 {
                start = r
                transientMessage = "Resumed — \(r + 1) / \(items.count)"
            }
        } else if explicitStart == nil, let r = navigation.resumeIndex() {
            start = r
            if r != 0 {
                transientMessage = "Resumed — \(r + 1) / \(items.count)"
            }
        }

        guard navigation.goTo(index: min(max(start, 0), items.count - 1)) else { return }
        scheduleSaveState()
        reload()
    }

    func finishOpening() {
        isOpening = false
        openingName = nil
    }

    // MARK: Navigation

    func next() {
        guard navigation.next() else { return }
        scheduleSaveState()
        reload()
    }

    func prev() {
        guard navigation.prev() else { return }
        scheduleSaveState()
        reload()
    }

    func first() {
        guard navigation.first() else { return }
        scheduleSaveState()
        reload()
    }

    func last() {
        guard navigation.last() else { return }
        scheduleSaveState()
        reload()
    }

    func setCoverAloneInSpread(_ enabled: Bool) {
        navigation.setCoverAloneInSpread(enabled)
        guard navigation.spreadEnabled else { return }
        scheduleSaveState()
        reload()
    }

    @discardableResult
    func toggleSpread() -> String {
        navigation.setCoverAloneInSpread(ReaderSettings.shared.coverAloneInSpread)
        let message = navigation.toggleSpread()
        if !navigation.spreadEnabled {
            secondary = nil
        }
        scheduleSaveState()
        reload()
        return message
    }

    func goTo(index: Int) {
        guard navigation.goTo(index: index) else { return }
        scheduleSaveState()
        reload()
    }

    // MARK: Loading

    private func reload() {
        guard items.indices.contains(index) else {
            current = nil
            secondary = nil
            return
        }

        loadTask?.cancel()
        loadToken += 1
        let token = loadToken
        let url = items[index]
        let secondURL = navigation.secondaryIndex.map { items[$0] }
        let maxPixel = Self.displayMaxPixel()
        let source = source

        loadTask = Task { [weak self] in
            guard let self else { return }

            let signpost = ReaderPerformance.begin("Reader Page Load")
            defer { ReaderPerformance.end("Reader Page Load", signpost) }

            let (img, img2) = await source.loadVisiblePages(
                primary: url,
                secondary: secondURL,
                maxPixel: maxPixel,
                cache: cache
            )

            guard !Task.isCancelled, token == loadToken else { return }
            current = img
            renderTick &+= 1

            if let openStartedAt {
                ReaderPerformance.metric(
                    "reader_first_visible_page",
                    milliseconds: ReaderPerformance.milliseconds(since: openStartedAt)
                )
                self.openStartedAt = nil
            }
            secondary = img2
            failedName = (img == nil) ? url.lastPathComponent : nil
            failedURL = (img == nil) ? url : nil

            if source.isRemote,
               manualRotate == nil,
               orientationProbeTask == nil,
               let firstURL = items.first {
                startRemoteOrientationProbe(firstURL, openGeneration: openSeq)
            }

            finishOpening()

            guard !Task.isCancelled, token == loadToken else { return }

            let ns = navigation.neighbors()
            await source.prefetch(ns, maxPixel: maxPixel, cache: cache)
        }
    }

    private func startRemoteOrientationProbe(_ url: URL, openGeneration: Int) {
        orientationProbeTask?.cancel()
        orientationProbeTask = Task { [weak self] in
            guard let self else { return }
            guard let landscape = await Self.remotePageIsLandscape(url) else { return }
            guard !Task.isCancelled,
                  self.openSeq == openGeneration,
                  self.manualRotate == nil else { return }
            self.pagesLandscape = landscape
        }
    }

    // MARK: Chapters

    var isCurrentChapter: Bool {
        navigation.isCurrentChapter
    }

    var orderedChapters: [(page: Int, name: String)] {
        navigation.orderedChapters
    }

    var chapterEntries: [
        (ordinal: Int, page: Int, index: Int, url: URL, name: String)
    ] {
        navigation.chapterEntries
    }

    func firstOfChapter() {
        guard navigation.firstOfChapter() else { return }
        scheduleSaveState()
        reload()
    }

    var readingProgress: Double {
        navigation.readingProgress
    }

    /// First logical page of the visible spread containing an index.
    func spreadStartIndex(for index: Int) -> Int {
        navigation.spreadStartIndex(for: index)
    }

    @discardableResult
    func toggleChapter() -> String {
        let message = navigation.toggleChapter()
        saveState()
        return message
    }

    @discardableResult
    func nextChapter() -> String {
        let message = navigation.nextChapter()
        guard message != "No chapters" else { return message }
        scheduleSaveState()
        reload()
        return message
    }

    @discardableResult
    func prevChapter() -> String {
        let message = navigation.prevChapter()
        guard message != "No chapters" else { return message }
        scheduleSaveState()
        reload()
        return message
    }

    func jumpToChapter(orderedIndex: Int) {
        guard navigation.jumpToChapter(orderedIndex: orderedIndex) else { return }
        scheduleSaveState()
        reload()
    }

    func renameChapter(atIndex i: Int, to name: String) {
        guard navigation.renameChapter(atIndex: i, to: name) else { return }
        saveState()
    }

    func deleteChapter(atIndex i: Int) {
        guard navigation.deleteChapter(atIndex: i) else { return }
        saveState()
    }

    // MARK: Per-comic state persistence

    private func loadState() {
        let result = stateStore.load()
        navigation.loadState(result.state)

        if result.migratedFromLegacy {
            saveState()
            stateStore.removeLegacyStateFiles()
        }
    }

    private func scheduleSaveState() {
        stateStore.scheduleSave(
            navigation.makeState(comicKey: comicKey)
        )
    }

    private func saveState() {
        stateStore.save(
            navigation.makeState(comicKey: comicKey)
        )
    }

    // MARK: Helpers

    static func displayMaxPixel() -> Int {
        let longest = NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
            .max() ?? 2880
        return min(8192, Int(longest.rounded(.up)))
    }

    private nonisolated static func remotePageIsLandscape(_ url: URL) async -> Bool? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .returnCacheDataElseLoad

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            return nil
        }

        return width.doubleValue >= height.doubleValue
    }

    func setFailure(name: String, url: URL) {
        if let openStartedAt {
            ReaderPerformance.metric(
                "reader_open_failed",
                milliseconds: ReaderPerformance.milliseconds(since: openStartedAt)
            )
            self.openStartedAt = nil
        }
        failedName = name
        failedURL = url
        current = nil
        finishOpening()
    }

    /// Cancel work belonging to the current session.
    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        orientationProbeTask?.cancel()
        orientationProbeTask = nil
        stateStore.cancel()
        openStartedAt = nil
    }
}
