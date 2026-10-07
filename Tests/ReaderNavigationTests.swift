import XCTest
import SwiftUI

@testable import ComicViewer

final class ReaderNavigationTests: XCTestCase {
    func testChapterBoundaryJumpsStayWithinChapterAndHandleFrontMatter() {
        var navigation = ReaderNavigation()
        navigation.configure(items: makePages(count: 9), folder: nil)
        _ = navigation.goTo(index: 2); _ = navigation.toggleChapter()
        _ = navigation.goTo(index: 5); _ = navigation.toggleChapter()
        _ = navigation.goTo(index: 3)
        XCTAssertTrue(navigation.lastOfChapter())
        XCTAssertEqual(navigation.index, 4)
        XCTAssertTrue(navigation.firstOfChapter())
        XCTAssertEqual(navigation.index, 2)
        _ = navigation.goTo(index: 5)
        XCTAssertTrue(navigation.lastOfChapter())
        XCTAssertEqual(navigation.index, 8)
        _ = navigation.goTo(index: 0)
        XCTAssertTrue(navigation.lastOfChapter())
        XCTAssertEqual(navigation.index, 1)
        XCTAssertTrue(navigation.firstOfChapter())
        XCTAssertEqual(navigation.index, 0)
    }

    func testChapterBoundaryJumpsWithoutMarkersUseComicBoundaries() {
        var navigation = ReaderNavigation()
        navigation.configure(items: makePages(count: 4), folder: nil)
        _ = navigation.goTo(index: 1)
        XCTAssertTrue(navigation.lastOfChapter())
        XCTAssertEqual(navigation.index, 3)
        XCTAssertTrue(navigation.firstOfChapter())
        XCTAssertEqual(navigation.index, 0)
        navigation.configure(items: [], folder: nil)
        XCTAssertFalse(navigation.lastOfChapter())
    }

    @MainActor
    func testPageClipboardContainsPasteableImageWithOriginalPixelDimensions() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 20, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 20))
        let image = try XCTUnwrap(context.makeImage())
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ComicViewerTests." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(PageClipboard.copy(image, to: pasteboard))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        let png = try XCTUnwrap(pasteboard.data(forType: .png))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(decoded.pixelsWide, 12)
        XCTAssertEqual(decoded.pixelsHigh, 20)
    }

    func testPrefetchPrioritizesAdjacentPagesAndLooksAheadWithoutWrapping() {
        var navigation = ReaderNavigation()
        let pages = makePages(count: 5)
        navigation.configure(items: pages, folder: nil)
        _ = navigation.goTo(index: 2)
        XCTAssertEqual(navigation.neighbors(), [pages[3], pages[1], pages[4]])
        _ = navigation.goTo(index: 4)
        XCTAssertEqual(navigation.neighbors(), [pages[3]])
    }

    func testChapterOrderingUsesPageOrderAndCustomNames() {
        var navigation = ReaderNavigation()
        let pages = makePages(count: 5)

        navigation.configure(items: pages, folder: nil)

        XCTAssertEqual(navigation.goTo(index: 1), true)
        XCTAssertTrue(navigation.toggleChapter().contains("Chapter 1"))

        XCTAssertEqual(navigation.goTo(index: 4), true)
        XCTAssertTrue(navigation.toggleChapter().contains("Chapter 2"))

        navigation.renameChapter(atIndex: 4, to: "Finale")

        XCTAssertEqual(
            navigation.orderedChapters.map(\.name),
            ["Chapter 1", "Finale"]
        )
        XCTAssertEqual(
            navigation.chapterEntries.map(\.index),
            [1, 4]
        )
    }

    func testLoadStateMapsSavedPageAndChaptersToCurrentItems() {
        var navigation = ReaderNavigation()
        let pages = makePages(count: 3)

        let state = ComicState(
            version: 3,
            chapters: [pages[1].absoluteString],
            chapterNames: [pages[1].absoluteString: "Chapter Two"],
            lastPage: pages[2].absoluteString,
            lastIndex: 2,
            pageCount: 3,
            manualRotate: nil,
            path: nil
        )

        navigation.configure(items: pages, folder: nil)
        navigation.loadState(state)

        XCTAssertEqual(navigation.resumeIndex(), 2)
        XCTAssertEqual(navigation.orderedChapters.first?.name, "Chapter Two")
    }

    func testNavigationBoundariesDoNotMove() {
        var navigation = ReaderNavigation()
        let pages = makePages(count: 2)

        navigation.configure(items: pages, folder: nil)

        XCTAssertFalse(navigation.prev())
        XCTAssertEqual(navigation.index, 0)

        XCTAssertTrue(navigation.last())
        XCTAssertEqual(navigation.index, 1)

        XCTAssertFalse(navigation.next())
        XCTAssertEqual(navigation.index, 1)
    }

    private func makePages(count: Int) -> [URL] {
        (1...count).map {
            URL(fileURLWithPath: "/tmp/ComicViewerTests/page\($0).jpg")
        }
    }
}

@MainActor
final class AppNavigationTests: XCTestCase {
    func testHomeAlwaysReturnsToDashboard() {
        let router = AppRouter()
        router.path = [URL(fileURLWithPath: "/tmp/series")]
        router.route = .local
        router.showHome()
        XCTAssertEqual(router.route, .library)
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertNil(router.selectedComic)
    }

    func testReaderReturnsToSearchResults() {
        let router = AppRouter()
        router.route = .reader
        router.readerOrigin = .onlineSearch
        XCTAssertTrue(router.escapeBack())
        XCTAssertEqual(router.route, .onlineSearch)
        XCTAssertTrue(router.escapeBack())
        XCTAssertEqual(router.route, .browse)
    }

    func testOnlineBackPopsOneCatalogAndReturnsToSearch() {
        let router = AppRouter()
        let browse = BrowseState.shared
        let previous = browse.stack
        let previousReturn = browse.returnToSearch
        defer { browse.stack = previous; browse.returnToSearch = previousReturn }
        let root = RemoteCatalog(name: "Parent", sourceURL: URL(string: "https://example.org/parent")!, comics: [], childCatalogs: [])
        let child = RemoteCatalog(name: "Child", sourceURL: URL(string: "https://example.org/child")!, comics: [], childCatalogs: [])
        browse.beginExternal(root, returningTo: .onlineSearch)
        browse.push(child)
        router.route = .browse
        router.escapeBack()
        XCTAssertEqual(browse.stack.count, 1)
        XCTAssertEqual(router.route, .browse)
        router.escapeBack()
        XCTAssertTrue(browse.stack.isEmpty)
        XCTAssertEqual(router.route, .onlineSearch)
        XCTAssertFalse(browse.returnToSearch)
    }
}

@MainActor
final class NavigationLayoutTests: XCTestCase {
    func testSidebarKeepsSearchCenteredInContentWhenExpandedOrCollapsed() async throws {
        let suite = "ComicViewer-sidebar-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for (width, expanded) in [(640.0, true), (1200.0, true), (1200.0, false)] {
            defaults.set(expanded, forKey: "navigation.sidebarExpanded")
            var searchFrame = CGRect.zero
            let content = AppNavigationShell {
                VStack(spacing: 0) {
                    SectionToolbar {
                        Text("A long catalog name that should truncate before the search field")
                    } search: {
                        NavigationSearchField(prompt: "Search this catalog", text: .constant(""))
                            .background(GeometryReader { geometry in
                                Color.clear
                                    .onAppear { searchFrame = geometry.frame(in: .named("shell")) }
                                    .onChange(of: geometry.size) { _, _ in searchFrame = geometry.frame(in: .named("shell")) }
                            })
                    } actions: {
                        HStack { Image(systemName: "line.3.horizontal.decrease.circle"); Image(systemName: "arrow.clockwise") }
                    }
                    Spacer()
                }.background(Color.black)
            }
            .defaultAppStorage(defaults)
            .environment(AppRouter()).environment(\.colorScheme, .dark)
            .frame(width: width, height: 500)
            .coordinateSpace(name: "shell")
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            for _ in 0..<20 {
                if searchFrame.width > 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: "/tmp/comic-sidebar-\(Int(width))-\(expanded).png"))
                }
            }
            try await Task.sleep(for: .milliseconds(100))
            let sidebarWidth = width >= 900 && expanded ? 220.0 : 56.0
            XCTAssertGreaterThan(searchFrame.width, 0)
            XCTAssertEqual(searchFrame.midX, sidebarWidth + (width - sidebarWidth) / 2, accuracy: 1)
            window.orderOut(nil)
        }
    }
}
