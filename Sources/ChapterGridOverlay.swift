import SwiftUI

/// A dimmed overlay showing chapter thumbnails (each chapter's page image) in a paginated
/// grid. Click a thumbnail to jump there. 6 per page (3×2).
struct ChapterGridOverlay: View {
    let entries: [(ordinal: Int, page: Int, index: Int, url: URL, name: String)]
    let currentIndex: Int
    let totalPageCount: Int
    let cache: ThumbnailCache
    @Binding var pageIndex: Int
    let onSelect: (Int) -> Void
    let onClose: () -> Void
    /// Rename/delete the chapter at a page index (nil = editing not available).
    var onRename: ((Int, String) -> Void)? = nil
    var onDelete: ((Int) -> Void)? = nil

    private let perPage = 6
    private let columns = 3

    @State private var renamingIndex: Int?
    @State private var renameText = ""

    private var pageCount: Int { max(1, Int(ceil(Double(entries.count) / Double(perPage)))) }
    private var slice: ArraySlice<(ordinal: Int, page: Int, index: Int, url: URL, name: String)> {
        let start = min(pageIndex, pageCount - 1) * perPage
        return entries[start..<min(start + perPage, entries.count)]
    }

    private var currentEntry: (ordinal: Int, page: Int, index: Int, url: URL, name: String)? {
        guard let entry = entries.last(where: { $0.index <= currentIndex }) else { return nil }
        return entry
    }

    private func chapterEndIndex(for entry: (ordinal: Int, page: Int, index: Int, url: URL, name: String)) -> Int {
        entries.first(where: { $0.index > entry.index })?.index ?? totalPageCount
    }

    private var currentChapterProgress: Double? {
        guard let entry = currentEntry, totalPageCount > entry.index else { return nil }
        let end = chapterEndIndex(for: entry)
        guard end > entry.index else { return nil }
        return min(
            max(Double(currentIndex - entry.index + 1) / Double(end - entry.index), 0),
            1
        )
    }

    private var currentChapterPageText: String? {
        guard let entry = currentEntry else { return nil }
        let end = chapterEndIndex(for: entry)
        let page = min(max(currentIndex + 1, entry.page), end)
        return "p. (page - entry.page + 1) / (max(1, end - entry.index))"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .onTapGesture { onClose() }

            VStack(spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Chapters ((entries.count))")
                            .font(.title2.bold())

                        if let entry = currentEntry, let progress = currentChapterProgress {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 7, height: 7)
                                Text("Reading (entry.name)")
                                    .font(.callout.weight(.medium))
                                if let pageText = currentChapterPageText {
                                    Text("·")
                                        .foregroundStyle(.secondary)
                                    Text(pageText)
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                Text("·")
                                    .foregroundStyle(.secondary)
                                Text("\(Int((progress * 100).rounded()))%")
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    Button { onClose() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                if entries.isEmpty {
                    Spacer()
                    Text("No chapters yet — press C to add one")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns),
                        spacing: 16
                    ) {
                        ForEach(Array(slice), id: \.index) { e in
                            let end = chapterEndIndex(for: e)
                            let isCurrent = e.index <= currentIndex && currentIndex < end
                            let currentPage = isCurrent ? currentIndex - e.index + 1 : nil
                            ThumbCell(
                                entry: e,
                                isCurrent: isCurrent,
                                chapterPageCount: max(1, end - e.index),
                                currentPage: currentPage,
                                cache: cache
                            ) {
                                onSelect(e.index)
                            }
                            .contextMenu {
                                if onRename != nil {
                                    Button("Rename…") {
                                        renamingIndex = e.index
                                        renameText = e.name
                                    }
                                }
                                if let onDelete {
                                    Button("Delete", role: .destructive) { onDelete(e.index) }
                                }
                            }
                        }
                    }

                    if pageCount > 1 {
                        HStack(spacing: 18) {
                            Button { pageIndex = max(0, pageIndex - 1) } label: {
                                Image(systemName: "chevron.left")
                            }
                            .disabled(pageIndex == 0)

                            Text("Page (min(pageIndex, pageCount - 1) + 1) / (pageCount)")
                                .monospacedDigit()

                            Button { pageIndex = min(pageCount - 1, pageIndex + 1) } label: {
                                Image(systemName: "chevron.right")
                            }
                            .disabled(pageIndex >= pageCount - 1)
                        }
                        .buttonStyle(.plain)
                        .font(.title3)
                    }
                }

                Text("← / → to page · click a chapter · Esc or T to close")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(30)
            .frame(maxWidth: 940)
        }
        .alert(
            "Rename chapter",
            isPresented: Binding(
                get: { renamingIndex != nil },
                set: { if !$0 { renamingIndex = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingIndex = nil }
            Button("Save") {
                if let i = renamingIndex {
                    onRename?(i, renameText)
                }
                renamingIndex = nil
            }
        } message: {
            Text("Leave blank to reset to the default name.")
        }
    }
}

private struct ThumbCell: View {
    let entry: (ordinal: Int, page: Int, index: Int, url: URL, name: String)
    let isCurrent: Bool
    let chapterPageCount: Int
    let currentPage: Int?
    let cache: ThumbnailCache
    let action: () -> Void
    @State private var cg: CGImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.06))

                    if let cg {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .padding(5)
                    } else {
                        ProgressView()
                    }

                    if isCurrent {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.15),
                                .init(color: .black.opacity(0.78), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )

                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("READING")
                                    .font(.caption2.weight(.bold))
                                    .tracking(0.7)
                                Spacer()
                                Text("\(Int((Double(currentPage ?? 1) / Double(chapterPageCount) * 100).rounded()))%")
                                    .font(.caption2.weight(.bold))
                                    .monospacedDigit()
                            }

                            GeometryReader { geo in
                                Capsule()
                                    .fill(.white.opacity(0.28))
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(.white)
                                            .frame(
                                                width: geo.size.width * min(
                                                    max(Double(currentPage ?? 1) / Double(chapterPageCount), 0),
                                                    1
                                                )
                                            )
                                    }
                            }
                            .frame(height: 3)
                        }
                        .padding(10)
                        .foregroundStyle(.white)
                    }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isCurrent ? Color.red : .white.opacity(0.15),
                            lineWidth: isCurrent ? 3 : 1
                        )
                )

                Text(entry.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text("pp. (entry.page)–(entry.page + chapterPageCount - 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .task(id: entry.url) {
            cg = await cache.thumbnail(for: entry.url, maxPixel: 500)
        }
    }
}
