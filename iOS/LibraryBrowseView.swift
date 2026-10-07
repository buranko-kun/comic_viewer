import SwiftUI

/// One library level: sub-folders to drill into + comics to open. The root wraps itself in a
/// NavigationStack; deeper levels are pushed into it.
struct LibraryBrowseView: View {
    let dir: String?
    let title: String

    var body: some View {
        if dir == nil {
            NavigationStack { LibraryLevelView(dir: dir, title: title) }
        } else {
            LibraryLevelView(dir: dir, title: title)
        }
    }
}

private struct LibraryLevelView: View {
    let dir: String?
    let title: String
    @Environment(ServerConnection.self) private var connection

    @State private var level: LibraryLevel?
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14)]

    var body: some View {
        ScrollView {
            if let error {
                Text(error).foregroundStyle(.secondary).padding(.top, 60)
            }
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(level?.groups ?? []) { g in
                    NavigationLink { LibraryLevelView(dir: g.id, title: g.name) } label: {
                        FolderTile(name: g.name, count: g.count)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(level?.comics ?? []) { c in
                    NavigationLink { ReaderView(comic: c) } label: {
                        ComicTile(comic: c)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if dir == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Disconnect") { connection.disconnect() }
                }
            }
        }
        .task {
            guard let client = connection.client else { return }
            do { level = try await client.library(dir: dir) }
            catch { self.error = "Couldn't load this level." }
        }
    }
}

private struct FolderTile: View {
    let name: String
    let count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08))
                Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            Text(name).font(.caption).foregroundStyle(.white).lineLimit(2)
            Text("\(count)").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct ComicTile: View {
    let comic: ComicSummary
    @Environment(ServerConnection.self) private var connection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06))
                if let client = connection.client {
                    AsyncImage(url: client.thumbURL(comicId: comic.id)) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        case .failure: Image(systemName: comic.isArchive ? "doc.zipper" : "book.closed")
                                .foregroundStyle(.secondary)
                        default: ProgressView()
                        }
                    }
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) {
                if let p = comic.progress, p.count > 0 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.25))
                            Rectangle().fill(.red)
                                .frame(width: g.size.width * CGFloat(p.index + 1) / CGFloat(p.count))
                        }
                    }
                    .frame(height: 3)
                }
            }
            Text(comic.title).font(.caption).foregroundStyle(.white).lineLimit(2)
        }
    }
}
