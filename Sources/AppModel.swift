import Foundation
import Observation

/// Application-level facade.
///
/// Reader state and behavior live in ReaderSession. Source opening is handled by SourceOpener.
/// AppModel preserves the public API used by the UI, commands and headless tests.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private let reader: ReaderSession
    private let sourceOpener: SourceOpener

    init() {
        let reader = ReaderSession()
        self.reader = reader
        self.sourceOpener = SourceOpener(reader: reader)
    }

    var items: [URL] { reader.items }
    var index: Int { reader.index }
    var current: DisplayImage? { reader.current }
    var renderTick: Int { reader.renderTick }
    var secondary: DisplayImage? { reader.secondary }
    var spreadEnabled: Bool { reader.spreadEnabled }
    var failedName: String? { reader.failedName }
    var failedURL: URL? { reader.failedURL }
    var transientMessage: String? { reader.transientMessage }
    var isOpening: Bool { reader.isOpening }
    var openingName: String? { reader.openingName }
    var chapters: Set<String> { reader.chapters }
    var chapterNames: [String: String] { reader.chapterNames }
    var counter: String { reader.counter }
    var currentName: String? { reader.currentName }
    var readingPortrait: Bool { reader.readingPortrait }
    var openGeneration: Int { reader.openGeneration }
    var orderedChapters: [(page: Int, name: String)] { reader.orderedChapters }
    var chapterEntries: [(ordinal: Int, page: Int, index: Int, url: URL, name: String)] { reader.chapterEntries }
    var isCurrentChapter: Bool { reader.isCurrentChapter }
    var readingProgress: Double { reader.readingProgress }

    @discardableResult
    func toggleReadingRotation() -> String { reader.toggleReadingRotation() }
    func next() { reader.next() }
    func prev() { reader.prev() }
    func first() { reader.first() }
    func last() { reader.last() }

    @discardableResult
    func toggleSpread() -> String { reader.toggleSpread() }
    func goTo(index: Int) { reader.goTo(index: index) }
    func firstOfChapter() { reader.firstOfChapter() }

    @discardableResult
    func toggleChapter() -> String { reader.toggleChapter() }
    @discardableResult
    func nextChapter() -> String { reader.nextChapter() }
    @discardableResult
    func prevChapter() -> String { reader.prevChapter() }
    func jumpToChapter(orderedIndex: Int) { reader.jumpToChapter(orderedIndex: orderedIndex) }
    func renameChapter(atIndex i: Int, to name: String) { reader.renameChapter(atIndex: i, to: name) }
    func deleteChapter(atIndex i: Int) { reader.deleteChapter(atIndex: i) }

    // MARK: Opening

    func open(urls: [URL], startIndex: Int? = nil) {
        sourceOpener.open(urls: urls, startIndex: startIndex)
    }

    func openRemote(_ comic: Comic) {
        sourceOpener.openRemote(comic)
    }

    /// Cancel all in-flight work and remove archive-session directories owned by the app.
    func cleanupTempDirs() {
        sourceOpener.cancel()
        reader.cancel()
        Task { await ArchiveSessionManager.shared.cleanup() }
    }
}
