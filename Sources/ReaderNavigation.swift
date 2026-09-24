import Foundation

/// Owns reader navigation state and chapter semantics for the currently opened page set.
///
/// This is a value type so mutations remain visible through ReaderSession's @Observable storage
/// without introducing a second observable object graph.
struct ReaderNavigation {
    private(set) var items: [URL] = []
    private(set) var index = 0
    private(set) var spreadEnabled = false
    private(set) var chapters: Set<String> = []
    private(set) var chapterNames: [String: String] = []

    private var bookmarkNames: [String: String] = [:]
    private var folder: URL?
    private var lastPage: String?

    mutating func configure(items: [URL], folder: URL?) {
        self.items = items
        self.folder = folder
        index = 0
        spreadEnabled = false
        resetState()
        loadBookmarkChapters()
    }

    mutating func loadState(_ state: ComicState?) {
        chapters = []
        chapterNames = [:]
        lastPage = nil

        guard let state else { return }

        let present = Set(items.map { pageKey(for: $0) })

        chapters = Set(state.chapters.compactMap { key in
            if present.contains(key) {
                return key
            }
            return legacyPageKey(for: key)
        })

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
                : legacyPageKey(
                    for: saved,
                    preferredIndex: state.lastIndex
                )
        }
    }

    func resumeIndex() -> Int? {
        guard let lastPage else { return nil }
        return items.firstIndex { pageKey(for: $0) == lastPage }
    }

    func makeState(comicKey: String?) -> ComicState {
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

    // MARK: Page navigation

    @discardableResult
    mutating func next() -> Bool {
        move(spreadEnabled ? 2 : 1)
    }

    @discardableResult
    mutating func prev() -> Bool {
        move(spreadEnabled ? -2 : -1)
    }

    @discardableResult
    mutating func first() -> Bool {
        setIndex(0)
    }

    @discardableResult
    mutating func last() -> Bool {
        setIndex(items.count - 1)
    }

    @discardableResult
    mutating func goTo(index: Int) -> Bool {
        setIndex(index)
    }

    /// Toggles the two-page spread and returns the user-facing status message.
    ///
    /// When enabling spread on an odd page, the visible index is aligned to the preceding even
    /// page while the odd page remains the persisted resume target, matching the previous behavior.
    mutating func toggleSpread() -> String {
        spreadEnabled.toggle()

        if spreadEnabled, index % 2 == 1, items.indices.contains(index) {
            let resumeKey = pageKey(for: items[index])
            index -= 1
            lastPage = resumeKey
        }

        return spreadEnabled ? "Two-page spread" : "Single page"
    }

    // MARK: Chapters

    var isCurrentChapter: Bool {
        guard index < items.count else { return false }
        return chapterFiles().contains(pageKey(for: items[index]))
    }

    var orderedChapters: [(page: Int, name: String)] {
        orderedChapterIndices().enumerated().map { ordinal, idx in
            (
                page: idx + 1,
                name: chapterLabel(at: idx, ordinal: ordinal + 1)
            )
        }
    }

    var chapterEntries: [
        (ordinal: Int, page: Int, index: Int, url: URL, name: String)
    ] {
        orderedChapterIndices().enumerated().map { ordinal, idx in
            (
                ordinal: ordinal + 1,
                page: idx + 1,
                index: idx,
                url: items[idx],
                name: chapterLabel(at: idx, ordinal: ordinal + 1)
            )
        }
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
    mutating func toggleChapter() -> String {
        guard index < items.count else { return "No image" }

        let key = pageKey(for: items[index])

        if chapters.contains(key) {
            chapters.remove(key)
            return chapters.isEmpty
                ? "Chapter removed"
                : "Chapter removed  (\(chapters.count) left)"
        }

        chapters.insert(key)
        let ordered = orderedChapterIndices()
        let ordinal = (ordered.firstIndex(of: index) ?? 0) + 1
        return "Chapter \(ordinal) of \(ordered.count) set"
    }

    @discardableResult
    mutating func nextChapter() -> String {
        jumpChapter(forward: true)
    }

    @discardableResult
    mutating func prevChapter() -> String {
        jumpChapter(forward: false)
    }

    @discardableResult
    mutating func firstOfChapter() -> Bool {
        let idxs = orderedChapterIndices()
        return setIndex(idxs.last { $0 <= index } ?? 0)
    }

    @discardableResult
    mutating func jumpToChapter(orderedIndex: Int) -> Bool {
        let idxs = orderedChapterIndices()
        guard idxs.indices.contains(orderedIndex) else { return false }
        return setIndex(idxs[orderedIndex])
    }

    @discardableResult
    mutating func renameChapter(atIndex i: Int, to name: String) -> Bool {
        guard items.indices.contains(i) else { return false }

        let key = pageKey(for: items[i])
        guard chapterFiles().contains(key) else { return false }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            chapterNames[key] = nil
        } else {
            chapterNames[key] = trimmed
        }
        return true
    }

    @discardableResult
    mutating func deleteChapter(atIndex i: Int) -> Bool {
        guard items.indices.contains(i) else { return false }

        let key = pageKey(for: items[i])
        chapters.remove(key)
        chapterNames[key] = nil
        return true
    }

    // MARK: Prefetch support

    func neighbors() -> [URL] {
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

    // MARK: Identity

    func pageKey(for url: URL) -> String {
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

    func contains(_ url: URL) -> Bool {
        items.contains(url)
    }

    // MARK: Private

    private mutating func resetState() {
        chapters = []
        chapterNames = [:]
        bookmarkNames = [:]
        lastPage = nil
    }

    private mutating func loadBookmarkChapters() {
        bookmarkNames = [:]
        guard let folder, let info = ComicInfo.load(fromFolder: folder) else { return }

        for bookmark in info.bookmarks where items.indices.contains(bookmark.imageIndex) {
            bookmarkNames[
                pageKey(for: items[bookmark.imageIndex])
            ] = bookmark.name
        }
    }

    private mutating func setIndex(_ requested: Int) -> Bool {
        guard items.indices.contains(requested) else { return false }

        let normalized = spreadEnabled
            ? requested - (requested % 2)
            : requested

        guard items.indices.contains(normalized) else { return false }

        index = normalized
        lastPage = pageKey(for: items[normalized])
        return true
    }

    private mutating func move(_ delta: Int) -> Bool {
        guard !items.isEmpty else { return false }
        return setIndex(index + delta)
    }

    private mutating func jumpChapter(forward: Bool) -> String {
        let idxs = orderedChapterIndices()
        guard !idxs.isEmpty else { return "No chapters" }

        let target = forward
            ? (idxs.first { $0 > index } ?? idxs.first!)
            : (idxs.last { $0 < index } ?? idxs.last!)

        setIndex(target)

        let ordinal = (idxs.firstIndex(of: target) ?? 0) + 1
        return "Chapter \(ordinal) of \(idxs.count)"
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

    private func legacyPageKey(for basename: String, preferredIndex: Int? = nil) -> String? {
        let matches = items.enumerated().filter {
            $0.element.lastPathComponent == basename
        }

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
}
