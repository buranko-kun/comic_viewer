import SwiftUI

/// A dimmed overlay showing chapter thumbnails (each chapter's page image) in a paginated
/// grid. Click a thumbnail to jump there. 6 per page (3×2).
struct ChapterGridOverlay: View {
    let entries: [(ordinal: Int, page: Int, index: Int, url: URL, name: String)]
    let currentIndex: Int
    let cache: ThumbnailCache
    @Binding var pageIndex: Int
    let onSelect: (Int) -> Void
    let onClose: () -> Void
    /// Rename/delete the chapter at a page index (nil = editing not available).
    var onRename: ((Int, String) -> Void)? = nil
    var onDelete: ((Int) -> Void)? = nil

    private let perPage = 6
    private let columns = 3

    // Rename dialog state (chapter page index + working text).
    @State private var renamingIndex: Int?
    @State private var renameText = ""

    private var pageCount: Int { max(1, Int(ceil(Double(entries.count) / Double(perPage)))) }
    private var slice: ArraySlice<(ordinal: Int, page: Int, index: Int, url: URL, name: String)> {
        let start = min(pageIndex, pageCount - 1) * perPage
        return entries[start..<min(start + perPage, entries.count)]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .onTapGesture { onClose() }

            VStack(spacing: 18) {
                HStack {
                    Text("Chapters (\(entries.count))").font(.title2.bold())
                    Spacer()
                    Button { onClose() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }

                if entries.isEmpty {
                    Spacer()
                    Text("No chapters yet — press C to add one").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns),
                        spacing: 16) {
                        ForEach(Array(slice), id: \.index) { e in
                            ThumbCell(entry: e, isCurrent: e.index == currentIndex, cache: cache) {
                                onSelect(e.index)
                            }
                            .contextMenu {
                                if onRename != nil {
                                    Button("Rename…") { renamingIndex = e.index; renameText = e.name }
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
                            }.disabled(pageIndex == 0)
                            Text("Page \(min(pageIndex, pageCount - 1) + 1) / \(pageCount)")
                                .monospacedDigit()
                            Button { pageIndex = min(pageCount - 1, pageIndex + 1) } label: {
                                Image(systemName: "chevron.right")
                            }.disabled(pageIndex >= pageCount - 1)
                        }
                        .buttonStyle(.plain)
                        .font(.title3)
                    }
                }

                Text("← / → to page · click a chapter · Esc or T to close")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(30)
            .frame(maxWidth: 940)
        }
        .alert("Rename chapter", isPresented: Binding(
            get: { renamingIndex != nil },
            set: { if !$0 { renamingIndex = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingIndex = nil }
            Button("Save") {
                if let i = renamingIndex { onRename?(i, renameText) }
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
    let cache: ThumbnailCache
    let action: () -> Void
    @State private var cg: CGImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06))
                    if let cg {
                        Image(decorative: cg, scale: 1)
                            .resizable().interpolation(.medium)
                            .aspectRatio(contentMode: .fit).padding(5)
                    } else {
                        ProgressView()
                    }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)   // portrait cover shape
                .frame(maxWidth: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isCurrent ? Color.red : .white.opacity(0.15),
                                lineWidth: isCurrent ? 3 : 1))
                Text(entry.name).font(.callout.weight(.semibold))
                    .lineLimit(2).multilineTextAlignment(.center)
                Text("page \(entry.page)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .task(id: entry.url) { cg = await cache.thumbnail(for: entry.url, maxPixel: 500) }
    }
}
