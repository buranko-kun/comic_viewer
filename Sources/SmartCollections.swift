import SwiftUI
import AppKit
import CoreGraphics

/// Built-in, dynamic collections derived from the current local library.
/// Smart collections are intentionally not persisted: their contents always reflect current library state.
enum SmartCollectionKind: String, CaseIterable, Identifiable {
    case continueReading
    case recentlyRead
    case unread
    case completed
    case withChapters
    case recentlyAdded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .continueReading: return "Continue Reading"
        case .recentlyRead: return "Recently Read"
        case .unread: return "Unread"
        case .completed: return "Completed"
        case .withChapters: return "With Chapters"
        case .recentlyAdded: return "Recently Added"
        }
    }

    var icon: String {
        switch self {
        case .continueReading: return "play.circle.fill"
        case .recentlyRead: return "clock.arrow.circlepath"
        case .unread: return "circle"
        case .completed: return "checkmark.circle.fill"
        case .withChapters: return "bookmark.fill"
        case .recentlyAdded: return "sparkles"
        }
    }

    var subtitle: String {
        switch self {
        case .continueReading: return "Pick up where you left off"
        case .recentlyRead: return "Your latest reading activity"
        case .unread: return "Never started"
        case .completed: return "Finished comics"
        case .withChapters: return "Comics with chapter markers"
        case .recentlyAdded: return "Newest files in your library"
        }
    }

    @MainActor
    func comics(in library: LibraryModel) -> [Comic] {
        let local = library.comics.filter { !$0.isRemote }

        switch self {
        case .continueReading:
            return library.continueReading.filter { !$0.isRemote }

        case .recentlyRead:
            return library.recentlyRead.filter { !$0.isRemote }

        case .unread:
            return local
                .filter { comic in
                    guard let progress = comic.progress else { return true }
                    return progress.count <= 0 || progress.page <= 1
                }
                .sorted(by: titleSort)

        case .completed:
            return local
                .filter { comic in
                    guard let progress = comic.progress, progress.count > 0 else { return false }
                    return progress.page >= progress.count
                }
                .sorted(by: titleSort)

        case .withChapters:
            return local
                .filter { $0.chapterCount > 0 }
                .sorted(by: titleSort)

        case .recentlyAdded:
            return local
                .sorted { creationDate(for: $0.url) > creationDate(for: $1.url) }
        }
    }

    private func titleSort(_ lhs: Comic, _ rhs: Comic) -> Bool {
        lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func creationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}

/// One Smart Collection tile.
struct SmartCollectionFolderCard: View {
    let kind: SmartCollectionKind
    let comics: [Comic]
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                CoverTile {
                    mosaic
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: kind.icon)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))

                        Text(kind.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }

                    Text("\(comics.count) item\(comics.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
        .brightness(hovering ? 0.08 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                hovering = true
                NSCursor.pointingHand.set()
            case .ended:
                hovering = false
                NSCursor.arrow.set()
            }
        }
    }

    @ViewBuilder
    private var mosaic: some View {
        if comics.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: kind.icon)
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.35))
                Text(kind.subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                let gap: CGFloat = 2

                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        comicCover(at: 0)
                        comicCover(at: 1)
                    }
                    HStack(spacing: gap) {
                        comicCover(at: 2)
                        comicCover(at: 3)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    @ViewBuilder
    private func comicCover(at index: Int) -> some View {
        if comics.indices.contains(index) {
            let comic = comics[index]
            Group {
                if let cover = comic.coverURL {
                    LocalComicCover(url: cover, archive: nil)
                } else if comic.isArchive {
                    LocalComicCover(url: nil, archive: comic.url)
                } else {
                    Image(systemName: "book.closed")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.25))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
            Color.clear
        }
    }
}

/// Minimal local cover renderer used by Smart Collection mosaics.
struct LocalComicCover: View {
    let url: URL?
    let archive: URL?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                Image(systemName: "book.closed")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: (url?.path ?? "") + (archive?.path ?? "")) {
            if let url {
                image = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: 320)
            } else if let archive {
                let source = await ArchiveCover.make(for: archive)
                if let source {
                    image = await ThumbnailCache.shared.thumbnail(for: source, maxPixel: 320)
                }
            }
        }
    }
}

/// The items inside a Smart Collection. The parent Collections screen owns the toolbar and
/// back navigation; this view only renders the dynamic grid.
struct SmartCollectionItemsView: View {
    let kind: SmartCollectionKind
    @State private var library = LibraryModel.shared

    private var comics: [Comic] {
        kind.comics(in: library)
    }

    var body: some View {
        Group {
            if comics.isEmpty {
                emptyState
            } else {
                GeometryReader { geo in
                    ScrollView {
                        LazyVGrid(
                            columns: GridStyle.columns(geo.size.width),
                            alignment: .center,
                            spacing: GridStyle.rowSpacing
                        ) {
                            ForEach(comics) { comic in
                            Button {
                                AppRouter.shared.readerOrigin = .collections
                                AppModel.shared.open(urls: [comic.url])
                                AppRouter.shared.route = .reader
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    CoverTile {
                                        if let cover = comic.coverURL {
                                            LocalComicCover(url: cover, archive: nil)
                                        } else if comic.isArchive {
                                            LocalComicCover(url: nil, archive: comic.url)
                                        } else {
                                            Image(systemName: "book.closed")
                                                .font(.largeTitle)
                                                .foregroundStyle(.white.opacity(0.25))
                                        }
                                    }

                                    Text(TitleCleaner.clean(comic.title))
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.white)
                                        .lineLimit(2, reservesSpace: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Read") {
                                    AppRouter.shared.readerOrigin = .collections
                                    AppModel.shared.open(urls: [comic.url])
                                    AppRouter.shared.route = .reader
                                }
                                Button("Open in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([comic.url])
                                }
                            }
                            }
                        }
                        .padding(.horizontal, GridStyle.hPadding)
                        .padding(.top, 24)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .onAppear {
            library.rescan()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: kind.icon)
                .font(.system(size: 42))
                .foregroundStyle(.white.opacity(0.35))

            Text(kind.title)
                .font(.title2.bold())

            Text(kind.subtitle)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
