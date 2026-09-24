import SwiftUI
import AppKit
import Observation
import ImageIO

/// The stateful reading session for one currently-open comic.
///
/// ReaderSession owns everything that changes while reading: pages, navigation, decoded images,
/// chapters, resume state, loading, orientation and reader caches. AppModel remains responsible for
/// deciding *how to open* a URL/source and delegates the resulting page set to this session.
@MainActor
@Observable
final class ReaderSession {
    private(set) var items: [URL] = []
    private(set) var index = 0
    private(set) var current: DisplayImage?
    private(set) var renderTick = 0
    private(set) var secondary: DisplayImage?
    private(set) var spreadEnabled = false
    private(set) var failedName: String?
    private(set) var failedURL: URL?
    private(set) var transientMessage: String?
    private(set) var isOpening = false
    private(set) var openingName: String?

    private(set) var chapters: Set<String> = []
    private(set) var chapterNames: [String: String] = [:]
    private var bookmarkNames: [String: String] = [:]

    private var folder: URL?
    private var comicKey: String?
    private var lastPage: String?
    private var manualRotate: Bool?
    private var loadTask: Task<Void, Never>?
    private var orientationProbeTask: Task<Void, Never>?
    private var pagesLandscape = true
    private var source: ReaderPageSource = .local(streamer: nil)
    private var openSeq = 0

    private let cache = ImageCache()
    private let stateStore = ReaderStateStore()
    private var loadToken = 0

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
        items = newItems
        folder = newFolder
        comicKey = newKey
        stateStore.configure(
            comicKey: newKey,
            legacyStateURLs: newLegacy
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
            if i == 0, let r = resumeIndex(), r != 0 {
                start = r
                transientMessage = "Resumed — \(r + 1) / \(items.count)"
            }
        } else if explicitStart == nil, let r = resumeIndex() {
            start = r
            if r != 0 {
                transientMessage = "Resumed — \(r + 1) / \(items.count)"
            }
        }

        setIndex(min(max(start, 0), items.count - 1))
    }

    func finishOpening() {
        isOpening = false
        openingName = nil
    }

    private func resumeIndex() -> Int? {
        guard let lastPage else { return nil }
        return items.firstIndex { pageKey(for: $0) == lastPage }
    }

    // MARK: Navigation

    func next() { move(spreadEnabled ? 2 : 1) }
    func prev() { move(spreadEnabled ? -2 : -1) }
    func first() { jump(to: 0) }
    func last() { jump(to: items.count - 1) }

    @discardableResult
    func toggleSpread() -> String {
        spreadEnabled.toggle()

        if !spreadEnabled {
            secondary = nil
        } else if index % 2 == 1 {
            let resumeKey = pageKey(for: items[index])
            index -= 1
            lastPage = resumeKey
            scheduleSaveState()
        }

        reload()
        return spreadEnabled ? "Two-page spread" : "Single page"
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let target = index + delta
        guard items.indices.contains(target) else { return }
        jump(to: target)
    }

    private func jump(to i: Int) {
        guard items.indices.contains(i) else { return }
        setIndex(i)
    }

    private func setIndex(_ requested: Int) {
        guard items.indices.contains(requested) else { return }

        let i = spreadEnabled ? requested - (requested % 2) : requested
        guard items.indices.contains(i) else { return }

        index = i
        lastPage = pageKey(for: items[i])
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
        let secondURL = (spreadEnabled && items.indices.contains(index + 1)) ? items[index + 1] : nil
        let maxPixel = Self.displayMaxPixel()
        let source = source

        loadTask = Task { [weak self] in
            guard let self else { return }

            let (img, img2) = await source.loadVisiblePages(
                primary: url,
                secondary: secondURL,
                maxPixel: maxPixel,
                cache: cache
            )

            guard !Task.isCancelled, token == loadToken else { return }
            current = img
            renderTick &+= 1
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

            let ns = neighbors()
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

    private func neighbors() -> [URL] {
        guard !items.isEmpty else { return [] }

        if spreadEnabled {
            var result: [URL] = []
            if index + 2 < items.count { result.append(items[index + 2]) }
            if index + 3 < items.count { result.append(items[index + 3]) }
            if index > 1 { result.append(items[index - 2]) }
            if index > 0 { result.append(items[index - 1]) }
            return result
        }

        var result: [URL] = []
        if index + 1 < items.count { result.append(items[index + 1]) }
        if index > 0 { result.append(items[index - 1]) }
        return result
    }

    // MARK: Page identity

    private func pageKey(for url: URL) -> String {
        if url.isFileURL, let folder {
            let base = folder.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
        }
        return url.absoluteString
    }

    private func legacyPageKey(for basename: String, preferredIndex: Int? = nil) -> String? {
        let matches = items.enumerated().filter { $0.element.lastPathComponent == basename }
        if matches.count == 1, let match = matches.first {
            return pageKey(for: match.element)
        }
        if let preferredIndex,
           items.indices.contains(preferredIndex),
           items[preferredIndex].lastPathComponent == basename {
            return pageKey(for: items[preferredIndex])
        }
        return nil
    }

    // MARK: Chapters

    var isCurrentChapter: Bool {
        guard index < items.count else { return false }
        return chapterFiles().contains(pageKey(for: items[index]))
    }

    var orderedChapters: [(page: Int, name: String)] {
        orderedChapterIndices().enumerated().map { ord, idx in
            (page: idx + 1, name: chapterLabel(at: idx, ordinal: ord + 1))
        }
    }

    var chapterEntries: [(ordinal: Int, page: Int, index: Int, url: URL, name: String)] {
        orderedChapterIndices().enumerated().map { ord, idx in
            (
                ordinal: ord + 1,
                page: idx + 1,
                index: idx,
                url: items[idx],
                name: chapterLabel(at: idx, ordinal: ord + 1)
            )
        }
    }

    func goTo(index: Int) {
        jump(to: index)
    }

    func firstOfChapter() {
        let idxs = orderedChapterIndices()
        jump(to: idxs.last { $0 <= index } ?? 0)
    }

    var readingProgress: Double {
        guard !items.isEmpty else { return 0 }
        let idxs = orderedChapterIndices()
        guard !idxs.isEmpty else {
            return Double(index + 1) / Double(items.count)
        }
        let start = idxs.last { $0 <= index } ?? 0
        let next = idxs.first { $0 > start } ?? items.count
        return Double(index - start + 1) / Double(max(1, next - start))
    }

    @discardableResult
    func toggleChapter() -> String {
        guard index < items.count else { return "No image" }
        let key = pageKey(for: items[index])

        if chapters.contains(key) {
            chapters.remove(key)
            saveState()
            return chapters.isEmpty
                ? "Chapter removed"
                : "Chapter removed  (\(chapters.count) left)"
        }

        chapters.insert(key)
        saveState()
        let ordered = orderedChapterIndices()
        let k = (ordered.firstIndex(of: index) ?? 0) + 1
        return "Chapter \(k) of \(ordered.count) set"
    }

    @discardableResult
    func nextChapter() -> String { jumpChapter(forward: true) }

    @discardableResult
    func prevChapter() -> String { jumpChapter(forward: false) }

    func jumpToChapter(orderedIndex: Int) {
        let idxs = orderedChapterIndices()
        guard idxs.indices.contains(orderedIndex) else { return }
        jump(to: idxs[orderedIndex])
    }

    private func jumpChapter(forward: Bool) -> String {
        let idxs = orderedChapterIndices()
        guard !idxs.isEmpty else { return "No chapters" }

        let target = forward
            ? (idxs.first { $0 > index } ?? idxs.first!)
            : (idxs.last { $0 < index } ?? idxs.last!)
        jump(to: target)

        let k = (idxs.firstIndex(of: target) ?? 0) + 1
        return "Chapter \(k) of \(idxs.count)"
    }

    private func loadBookmarkChapters() {
        bookmarkNames = [:]
        guard let folder, let info = ComicInfo.load(fromFolder: folder) else { return }
        for b in info.bookmarks where items.indices.contains(b.imageIndex) {
            bookmarkNames[pageKey(for: items[b.imageIndex])] = b.name
        }
    }

    private func chapterFiles() -> Set<String> {
        let present = Set(items.map { pageKey(for: $0) })
        return chapters.union(bookmarkNames.keys).intersection(present)
    }

    private func orderedChapterIndices() -> [Int] {
        let files = chapterFiles()
        return items.indices.filter { files.contains(pageKey(for: items[$0])) }
    }

    private func chapterLabel(at i: Int, ordinal: Int) -> String {
        let key = pageKey(for: items[i])
        return chapterNames[key] ?? bookmarkNames[key] ?? "Chapter \(ordinal)"
    }

    func renameChapter(atIndex i: Int, to name: String) {
        guard items.indices.contains(i) else { return }
        let key = pageKey(for: items[i])
        guard chapterFiles().contains(key) else { return }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            chapterNames[key] = nil
        } else {
            chapterNames[key] = trimmed
        }
        saveState()
    }

    func deleteChapter(atIndex i: Int) {
        guard items.indices.contains(i) else { return }
        let key = pageKey(for: items[i])
        chapters.remove(key)
        chapterNames[key] = nil
        saveState()
    }

    // MARK: Per-comic state persistence

    private func loadState() {
        chapters = []
        chapterNames = [:]
        lastPage = nil
        manualRotate = nil
        loadBookmarkChapters()

        let result = stateStore.load()
        guard let state = result.state else { return }

        let present = Set(items.map { pageKey(for: $0) })
        chapters = Set(state.chapters.compactMap { key in
            if present.contains(key) { return key }
            return legacyPageKey(for: key)
        })

        chapterNames = [:]
        for (key, name) in state.chapterNames {
            if present.contains(key) {
                chapterNames[key] = name
            } else if let mapped = legacyPageKey(for: key) {
                chapterNames[mapped] = name
            }
        }

        if let saved = state.lastPage {
            lastPage = present.contains(saved)
                ? saved
                : legacyPageKey(for: saved, preferredIndex: state.lastIndex)
        }

        if result.migratedFromLegacy {
            saveState()
            stateStore.removeLegacyStateFiles()
        }
    }

    private func scheduleSaveState() {
        stateStore.scheduleSave(makeState())
    }

    private func saveState() {
        stateStore.save(makeState())
    }

    private func makeState() -> ComicState {
        let ordered = orderedChapterIndices().map { pageKey(for: items[$0]) }
        let names = chapterNames.filter { chapters.contains($0.key) }

        return ComicState(
            version: 3,
            chapters: ordered,
            chapterNames: names,
            lastPage: lastPage,
            lastIndex: lastPage == nil ? nil : index,
            pageCount: lastPage == nil ? nil : items.count,
            manualRotate: nil,
            path: comicKey
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
    }
}
