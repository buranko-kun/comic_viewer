import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Observation
import SwiftTorrent

/// BitTorrent sharing and download panel.
struct TorrentsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manager = TorrentManager.shared
    @State private var showCreate = false
    @State private var showAddMagnet = false
    @State private var magnetText = ""
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))
            if manager.items.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(width: 620, height: 580)
        .background(Color.black)
        .tint(.white)
        .sheet(isPresented: $showCreate) {
            CreateTorrentSheet(sourceURL: nil)
        }
        .sheet(isPresented: $showAddMagnet) {
            AddMagnetSheet(initialText: magnetText) { value in
                Task {
                    do {
                        try await manager.addMagnet(value)
                        note = "Magnet added."
                    } catch {
                        note = "Couldn't add magnet: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Torrents").font(.headline)
                    Text(summary).font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()

                Button {
                    importTorrent()
                } label: {
                    Label("Add .torrent", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()

                Button {
                    magnetText = ""
                    showAddMagnet = true
                } label: {
                    Label("Add Magnet", systemImage: "link")
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()

                Button {
                    showCreate = true
                } label: {
                    Label("Create", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .pointingHandCursor()
            }

            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var summary: String {
        let downloading = manager.items.filter { $0.state == .downloading }.count
        let seeding = manager.items.filter { $0.state == .seeding }.count
        if downloading == 0 && seeding == 0 { return "Idle" }
        return "(downloading) downloading · (seeding) seeding"
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.35))
            Text("No torrents").font(.title3.bold())
            Text("Create a torrent from a comic to share it, or add a .torrent file / magnet link to download one.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(manager.items) { item in
                    TorrentRow(item: item)
                    Divider().overlay(.white.opacity(0.08))
                }
            }
        }
    }

    private func importTorrent() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                try await manager.importTorrent(from: url)
                note = "Torrent added."
            } catch {
                note = "Couldn't add torrent: \(error.localizedDescription)"
            }
        }
    }

    private func dismissWindow() {
        NSApp.keyWindow?.sheetParent?.endSheet(NSApp.keyWindow!)
    }
}

/// Reusable toolbar button for the torrent panel.
struct TorrentQueueButton: View {
    @State private var manager = TorrentManager.shared
    @State private var showTorrents = false

    var body: some View {
        Button {
            showTorrents = true
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .overlay(alignment: .topTrailing) {
                    if manager.activeCount > 0 {
                        Text("\(manager.activeCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .offset(x: 8, y: -8)
                    }
                }
        }
        .buttonStyle(.borderless)
        .help(manager.activeCount > 0 ? "\(manager.activeCount) active torrent\(manager.activeCount == 1 ? "" : "s")" : "Torrents")
        .pointingHandCursor()
        .sheet(isPresented: $showTorrents) {
            TorrentsView()
        }
    }
}

private struct TorrentRow: View {
    let item: TorrentManager.Item
    private let manager = TorrentManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.state == .seeding ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(item.state == .error ? .orange : .white.opacity(0.7))
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    statusText
                    if item.peers > 0 {
                        Text("\(item.peers) peers")
                    }
                    if item.totalSize > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: item.totalSize, countStyle: .file))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))

                if item.state == .downloading {
                    ProgressView(value: item.progress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(.red)
                        .frame(maxWidth: 260)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button {
                    manager.copyMagnet(item)
                } label: {
                    Image(systemName: "link")
                }
                .buttonStyle(.borderless)
                .help("Copy magnet link")
                .pointingHandCursor()

                ShareLink(item: item.magnet) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .help("Share magnet link")
                .pointingHandCursor()

                if let torrentURL = item.torrentURL {
                    ShareLink(item: torrentURL) {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Share .torrent file")
                    .pointingHandCursor()
                }

                if item.state == .downloading || item.state == .seeding {
                    Button {
                        manager.pause(item)
                    } label: {
                        Image(systemName: "pause.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Pause")
                    .pointingHandCursor()
                } else if item.state == .paused {
                    Button {
                        manager.resume(item)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Resume")
                    .pointingHandCursor()
                }

                if item.sourceURL != nil || item.torrentURL != nil {
                    Button {
                        manager.openInFinder(item)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                    .pointingHandCursor()
                }

                Button(role: .destructive) {
                    manager.remove(item)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove")
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusText: some View {
        switch item.state {
        case .downloading:
            if item.downloadRate > 0 {
                Text("Downloading · \(rate(item.downloadRate))")
            } else {
                Text("Downloading")
            }
        case .seeding:
            if item.uploadRate > 0 {
                Text("Seeding · \(rate(item.uploadRate)) up")
            } else {
                Text("Seeding")
            }
        case .paused:
            Text("Paused")
        case .error:
            Text(item.error ?? "Error")
        }
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}

struct CreateTorrentSheet: View {
    let initialSourceURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var sourceURL: URL?
    @State private var trackerText = TorrentSettingsStore.shared.trackerText
    @State private var comment = ""
    @State private var isCreating = false
    @State private var createdMagnet: String?
    @State private var createdTorrentURL: URL?
    @State private var errorText: String?

    init(sourceURL: URL?) {
        initialSourceURL = sourceURL
        _sourceURL = State(initialValue: sourceURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Torrent").font(.title3.bold())

            HStack(spacing: 10) {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceURL?.lastPathComponent ?? "No source selected")
                        .lineLimit(1)
                    if let url = sourceURL {
                        Text(url.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Button("Choose…") { chooseSource() }
                    .pointingHandCursor()
            }

            Text("Trackers").font(.headline)
            Text("One HTTP(S) or UDP tracker URL per line. The built-in ComicViewer seeder announces to HTTP(S) trackers.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $trackerText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12)))

            HStack {
                Button("Reset defaults") {
                    trackerText = TorrentSettingsStore.defaultTrackers.joined(separator: "\n")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .pointingHandCursor()
                Button("Create & Seed") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sourceURL == nil || isCreating)
                .pointingHandCursor()
            }

            if isCreating {
                ProgressView("Hashing source…")
                    .controlSize(.small)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let createdMagnet {
                Divider()
                Text("Magnet link").font(.headline)
                Text(createdMagnet)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(5)

                HStack {
                    Button("Copy Magnet") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(createdMagnet, forType: .string)
                    }
                    .pointingHandCursor()

                    ShareLink(item: createdMagnet) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .pointingHandCursor()

                    if let createdTorrentURL {
                        ShareLink(item: createdTorrentURL) {
                            Label("Share .torrent", systemImage: "square.and.arrow.up.on.square")
                        }
                        .pointingHandCursor()

                        Button("Show .torrent") {
                            NSWorkspace.shared.activateFileViewerSelecting([createdTorrentURL])
                        }
                        .pointingHandCursor()
                    }

                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .pointingHandCursor()
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Source"
        if panel.runModal() == .OK {
            sourceURL = panel.url?.standardizedFileURL
        }
    }

    private func create() {
        guard let sourceURL else { return }

        let trackers = trackerText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.canCreateDirectories = true
        let baseName = sourceURL.pathExtension.isEmpty
            ? sourceURL.lastPathComponent
            : sourceURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = baseName + ".torrent"
        panel.prompt = "Create Torrent"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isCreating = true
        errorText = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try TorrentCreator.create(
                        sourceURL: sourceURL,
                        trackers: trackers,
                        comment: comment.isEmpty ? nil : comment
                    )
                }.value

                try result.data.write(to: destination, options: .atomic)
                TorrentSettingsStore.shared.trackerText = trackers.joined(separator: "\n")
                try TorrentManager.shared.seed(created: result, torrentURL: destination)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.magnet, forType: .string)
                createdTorrentURL = destination
                createdMagnet = result.magnet
            } catch {
                errorText = error.localizedDescription
            }
            isCreating = false
        }
    }
}

private struct AddMagnetSheet: View {
    let initialText: String
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(initialText: String, onAdd: @escaping (String) -> Void) {
        self.initialText = initialText
        self.onAdd = onAdd
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Magnet").font(.title3.bold())
            TextField("magnet:?xt=urn:btih:…", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .pointingHandCursor()
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
                    .pointingHandCursor()
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var isValid: Bool {
        MagnetLink(uri: text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private func add() {
        guard isValid else { return }
        onAdd(text.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}


/// Preferences → Torrents: configure the tracker URLs embedded in newly created torrents and the
/// TCP port used by ComicViewer's built-in seeder.
struct TorrentSettingsTab: View {
    @State private var trackerText = TorrentSettingsStore.shared.trackerText
    @State private var portText = String(TorrentSettingsStore.shared.listenPort)
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Torrents").font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Seeder port").font(.body.weight(.medium))
                    HStack {
                        TextField("6881", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .onSubmit(savePort)
                        Button("Save", action: savePort)
                            .pointingHandCursor()
                    }
                    Text("ComicViewer accepts incoming BitTorrent peers on this TCP port. Router/NAT port forwarding may be required for peers outside your network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tracker URLs").font(.body.weight(.medium))
                    Text("One HTTP(S) or UDP tracker URL per line. Newly created torrents embed these URLs. The built-in seeder announces to HTTP(S) trackers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $trackerText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 150)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.white.opacity(0.12))
                        )
                        .onChange(of: trackerText) { _, value in
                            TorrentSettingsStore.shared.trackerText = value
                        }

                    HStack {
                        Button("Reset defaults") {
                            trackerText = TorrentSettingsStore.defaultTrackers.joined(separator: "\n")
                        }
                        .buttonStyle(.borderless)
                        .pointingHandCursor()

                        Spacer()

                        Button("Refresh") {
                            trackerText = TorrentSettingsStore.shared.trackerText
                            portText = String(TorrentSettingsStore.shared.listenPort)
                        }
                        .buttonStyle(.borderless)
                        .pointingHandCursor()
                    }
                }

                Text("Public tracker availability changes over time. You can replace these URLs with your own tracker or private tracker settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }

    private func savePort() {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0 else {
            note = "Port must be between 1 and 65535."
            return
        }
        TorrentSettingsStore.shared.listenPort = value
        portText = String(value)
        note = "Port saved. Restart active seeding after changing the port."
    }
}
