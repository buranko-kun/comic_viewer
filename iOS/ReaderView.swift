import SwiftUI

/// A paged reader: horizontal swipe between pages, pinch-to-zoom per page, resume at the saved
/// position, and progress saved back to the server as you read.
struct ReaderView: View {
    let comic: ComicSummary
    @Environment(ServerConnection.self) private var connection

    @State private var count = 0
    @State private var index = 0
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?

    private var pageWidth: Int { 1600 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if loaded, count > 0, let client = connection.client {
                TabView(selection: $index) {
                    ForEach(0..<count, id: \.self) { i in
                        ZoomablePage(url: client.pageURL(comicId: comic.id, index: i, width: pageWidth))
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
        }
        .navigationTitle(comic.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if count > 0 { Text("\(index + 1) / \(count)").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .toolbarBackground(.black, for: .navigationBar)
        .task { await load() }
        .onChange(of: index) { _, _ in scheduleSave() }
    }

    private func load() async {
        guard let client = connection.client else { return }
        if let info = try? await client.pages(comicId: comic.id) {
            count = info.count
            index = min(info.progress?.index ?? 0, max(0, info.count - 1))
        }
        loaded = true
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let i = index, c = count, id = comic.id
        saveTask = Task {
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled, c > 0, let client = connection.client else { return }
            await client.postProgress(comicId: id, index: i, count: c)
        }
    }
}

/// A single page that fits width by default and supports pinch-zoom + drag when zoomed in.
private struct ZoomablePage: View {
    let url: URL
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img):
                let z = max(1, zoom * pinch)
                img.resizable().scaledToFit()
                    .scaleEffect(z)
                    .offset(x: pan.width + drag.width, y: pan.height + drag.height)
                    .gesture(
                        MagnificationGesture()
                            .updating($pinch) { v, s, _ in s = v }
                            .onEnded { v in zoom = min(max(zoom * v, 1), 5); if zoom == 1 { pan = .zero } }
                    )
                    // Only intercept drags while zoomed in — otherwise let the TabView receive the
                    // one-finger swipe so a normal swipe turns the page.
                    .simultaneousGesture(
                        DragGesture()
                            .updating($drag) { v, s, _ in if zoom > 1 { s = v.translation } }
                            .onEnded { v in if zoom > 1 { pan.width += v.translation.width; pan.height += v.translation.height } },
                        including: zoom > 1 ? .all : .subviews
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if zoom > 1 { zoom = 1; pan = .zero } else { zoom = 2.5 }
                        }
                    }
            case .failure:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            default:
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
