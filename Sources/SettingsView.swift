import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Preferences (⌘,) — manage the catalog sources that populate the Online section. Add a
/// server URL, import a `.txt` of URLs, or remove sources. Changes re-query the servers.
struct SettingsView: View {
    private let sources = CatalogSourceStore.shared
    private let plugins = SourcePluginStore.shared
    @State private var newURL = ""
    @State private var newPluginURL = ""
    @State private var note: String?

    var body: some View {
        TabView {
            ReaderTab()
                .tabItem { Label("Reader", systemImage: "book") }
            sourcesTab
                .tabItem { Label("Sources", systemImage: "externaldrive.connected.to.line.below") }
            LibraryTab()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            StorageView()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            ReadingStateBackupTab()
                .tabItem { Label("Backup", systemImage: "arrow.up.arrow.down") }
            DownloadsSettingsTab()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            TorrentSettingsTab()
                .tabItem { Label("Torrents", systemImage: "arrow.triangle.2.circlepath") }
            ConnectTab()
                .tabItem { Label("Connect", systemImage: "network") }
            SharingTab()
                .tabItem { Label("Sharing", systemImage: "wifi") }
        }
        .frame(width: 760, height: 540)
    }

    private var sourcesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Catalog sources").font(.headline)
                        Text("Catalog feeds used by the Online section.")
                            .font(.caption).foregroundStyle(.secondary)

                        if sources.sources.isEmpty {
                            Text("No catalog sources yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(sources.sources) { source in
                                HStack(spacing: 10) {
                                    Image(systemName: "externaldrive.connected.to.line.below")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.name).fontWeight(.medium)
                                        Text(source.url.absoluteString)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Button(role: .destructive) { remove(source) } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }

                        HStack {
                            TextField("https://server.example/catalog.json", text: $newURL)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addTyped)
                            Button("Add", action: addTyped)
                                .disabled(CatalogSourceStore.makeURL(from: newURL) == nil)
                        }

                        HStack {
                            Button { importTxt() } label: {
                                Label("Import from .txt…", systemImage: "square.and.arrow.down")
                            }
                            Spacer()
                        }

                        Text("One URL per line. Use Name | URL for a custom name.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Source plugins").font(.headline)
                        Text("Add JavaScript source plugins without rebuilding the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if plugins.plugins.isEmpty {
                            Text("No source plugins installed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(plugins.plugins) { plugin in
                                HStack(spacing: 10) {
                                    Toggle(
                                        "",
                                        isOn: Binding(
                                            get: {
                                                plugins.plugins.first(where: { $0.id == plugin.id })?.enabled ?? false
                                            },
                                            set: { value in
                                                plugins.setEnabled(plugin.id, enabled: value)
                                                refresh()
                                            }
                                        )
                                    )
                                    .labelsHidden()
                                    .toggleStyle(.switch)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(plugin.name).fontWeight(.medium)
                                        Text("\(plugin.id) · v\(plugin.version)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Button {
                                        Task {
                                            do {
                                                let updated = try await plugins.update(plugin)
                                                note = "Updated \(updated.name) to v\(updated.version)."
                                                refresh()
                                            } catch {
                                                note = "Couldn't update \(plugin.name): \(error.localizedDescription)"
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Update plugin")

                                    Button(role: .destructive) {
                                        plugins.remove(plugin)
                                        refresh()
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove plugin")
                                }
                            }
                        }

                        HStack {
                            TextField(
                                "https://github.com/user/repo/blob/main/source.js",
                                text: $newPluginURL
                            )
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(installPluginURL)

                            Button("Install", action: installPluginURL)
                                .disabled(SourcePluginStore.makeURL(from: newPluginURL) == nil)
                        }

                        HStack {
                            Button { installPluginFile() } label: {
                                Label("Install local .js…", systemImage: "doc.badge.plus")
                            }
                            Spacer()
                            if let note {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }

                        Text("Plugins run as JavaScript. Install only from sources you trust.")
                            .font(.caption2)
                            .foregroundStyle(.orange.opacity(0.9))
                    }
                    .padding(4)
                }
            }
            .padding(20)
        }
    }

    // MARK: Actions

    private func addTyped() {
        guard let url = CatalogSourceStore.makeURL(from: newURL) else { return }
        if sources.add(name: "", url: url) { newURL = ""; note = nil; refresh() }
    }

    private func remove(_ source: CatalogSource) { sources.remove(source); refresh() }

    private func importTxt() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let added = sources.importTextFile(file)
        note = "Imported \(added) new source\(added == 1 ? "" : "s")."
        if added > 0 { refresh() }
    }

    private func installPluginURL() {
        guard let url = SourcePluginStore.makeURL(from: newPluginURL) else { return }
        note = "Installing plugin…"
        Task {
            do {
                let plugin = try await plugins.install(from: url)
                newPluginURL = ""
                note = "Installed \(plugin.name) v\(plugin.version)."
                refresh()
            } catch {
                note = "Couldn't install plugin: \(error.localizedDescription)"
            }
        }
    }

    private func installPluginFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }

        note = "Installing plugin…"
        Task {
            do {
                let plugin = try await plugins.install(localURL: file)
                note = "Installed \(plugin.name) v\(plugin.version)."
                refresh()
            } catch {
                note = "Couldn't install plugin: \(error.localizedDescription)"
            }
        }
    }

    private func refresh() { Task { await CatalogAggregator.shared.loadRoots() } }
}

/// Preferences → Reader: how comics open and display.
private struct ReaderTab: View {
    @State private var settings = ReaderSettings.shared

    var body: some View {
        @Bindable var s = settings

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Reader")
                    .font(.title2.weight(.semibold))

                GroupBox("Reading") {
                    VStack(alignment: .leading, spacing: 12) {
                        settingPicker(
                            "Default view",
                            selection: $s.defaultView
                        )

                        Text("Horizontal keeps pages as-is. Vertical rotates portrait pages.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        settingPicker(
                            "Reading direction",
                            selection: $s.readingDirection
                        )

                        Text("Also reverses horizontal navigation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Toggle("Fit wide pages to screen width", isOn: $s.fitWideToWidth)
                            .disabled(s.defaultView == .horizontal)
                            .opacity(s.defaultView == .horizontal ? 0.5 : 1)

                        Text("Applies only in Vertical view.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                GroupBox("Progress") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Show reading timeline", isOn: $s.showProgressBar)

                        settingPicker(
                            "Timeline scope",
                            selection: $s.timelineScope
                        )

                        Text("Chapter, issue, or series.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Toggle("Show chapter markers", isOn: $s.showChapterMarkers)
                            .disabled(s.timelineScope == .chapter)

                        Text("Shown on Issue and Series timelines.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                GroupBox("Pages") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Two-page spread", isOn: $s.twoPageSpread)
                            .onChange(of: s.twoPageSpread) { _, value in
                                AppModel.shared.setSpreadEnabled(value)
                            }

                        Text("Toggle with W while reading.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Toggle("Keep cover page alone", isOn: $s.coverAloneInSpread)
                            .disabled(!s.twoPageSpread)

                        Text("Page 1 stays alone, then pages pair from 2–3.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        HStack(spacing: 12) {
                            Text("Gutter")
                            Slider(value: $s.spreadGutter, in: 0...48, step: 1)
                            Text("\(Int(s.spreadGutter.rounded())) pt")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 38, alignment: .trailing)
                        }
                    }
                    .padding(4)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func settingPicker<T: Hashable & Identifiable>(
        _ title: String,
        selection: Binding<T>
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(title)
                .frame(width: 132, alignment: .leading)

            Picker(title, selection: selection) {
                if T.self == ReaderSettings.DefaultView.self {
                    ForEach(ReaderSettings.DefaultView.allCases) {
                        Text($0.label).tag($0 as T)
                    }
                } else if T.self == ReaderSettings.ReadingDirection.self {
                    ForEach(ReaderSettings.ReadingDirection.allCases) {
                        Text($0.label).tag($0 as T)
                    }
                } else if T.self == ReaderSettings.TimelineScope.self {
                    ForEach(ReaderSettings.TimelineScope.allCases) {
                        Text($0.label).tag($0 as T)
                    }
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
        }
    }
}

/// Preferences → Backup: export/import the per-comic reading state stored by ComicViewer.
private struct ReadingStateBackupTab: View {
    @State private var note: String?
    @State private var showImportConfirmation = false
    @State private var pendingPlan: ReadingStateBackup.ImportPlan?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reading state").font(.headline)

            Text("Back up reading progress, manual chapter markers and names, and reading timestamps. "
                 + "Comic files are never copied. Reader display settings are not included.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    exportBackup()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .pointingHandCursor()

                Button {
                    importBackup()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .pointingHandCursor()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label("Portable across library moves", systemImage: "folder.badge.gearshape")
                    .font(.body.weight(.medium))
                Text("Exact comic paths are matched first. When a library root has moved, the backup "
                     + "uses the comic's relative path under the old root to find its new location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(20)
        .alert("Import Reading State?", isPresented: $showImportConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingPlan = nil
            }
            Button("Import & Replace") {
                applyPendingImport()
            }
        } message: {
            Text(importConfirmationMessage)
        }
    }

    private var importConfirmationMessage: String {
        guard let plan = pendingPlan else { return "" }

        var lines = [
            "\(plan.items.count) saved comic state\(plan.items.count == 1 ? "" : "s") will be imported.",
            "Existing reading state for those comics will be replaced."
        ]

        if plan.remappedCount > 0 {
            lines.append("\(plan.remappedCount) will be remapped to the current library roots.")
        }
        if plan.ambiguous.count > 0 {
            lines.append("\(plan.ambiguous.count) will be skipped because multiple current paths matched.")
        }
        if plan.duplicateDestinations > 0 {
            lines.append("\(plan.duplicateDestinations) duplicate destination\(plan.duplicateDestinations == 1 ? "" : "s") will be skipped.")
        }

        return lines.joined(separator: "\n")
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "ComicViewer Reading State.json"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let backup = ReadingStateBackup.makeExport()
            let data = try ReadingStateBackup.encode(backup)
            try data.write(to: url, options: .atomic)

            let count = backup.entries.count
            note = "Exported \(count) saved comic state\(count == 1 ? "" : "s")."
        } catch {
            note = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let backup = try ReadingStateBackup.decode(data)
            pendingPlan = ReadingStateBackup.makeImportPlan(
                backup: backup,
                currentLibraryRoots: LibraryModel.shared.folders
            )
            showImportConfirmation = true
        } catch {
            note = "Import failed: \(error.localizedDescription)"
        }
    }

    private func applyPendingImport() {
        guard let pendingPlan else { return }
        let result = ReadingStateBackup.apply(pendingPlan)
        self.pendingPlan = nil
        note = result.message
        LibraryModel.shared.rescan()
    }
}

/// Preferences → Library: one-time maintenance to make comics stream fast.
private struct LibraryTab: View {
    @State private var library = LibraryModel.shared
    @State private var comicVineKey = ComicVine.apiKey
    @State private var metadataRefresh = MetadataRefreshCoordinator.shared

    private var archiveCount: Int { library.comics.filter(\.isArchive).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Library folders").font(.headline)
            Text("Folders containing your comics.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                if library.folders.isEmpty {
                    Text("No folders yet.").foregroundStyle(.secondary)
                }
                ForEach(library.folders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { library.removeFolder(folder) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 120)
            Button { addFolder() } label: { Label("Add Folder…", systemImage: "plus") }

            Divider().padding(.vertical, 4)

            Text("Faster loading").font(.headline)
            Text("Comics packed as RAR (many .cbr/.cbz files) must be fully extracted before they "
                 + "open, which is slow for large books. Converting them to ZIP lets the app load "
                 + "just the pages you're viewing, so opens and chapter jumps are near-instant.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Lossless — the page images are copied unchanged; only the archive format changes. "
                 + "Files are rewritten in place under the same name, so your reading progress and "
                 + "chapters are kept. ZIP files are slightly larger. Already-ZIP comics are skipped.")
                .font(.caption).foregroundStyle(.secondary)

            if let p = library.normalizeProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    Text("Converting \(p.done) / \(p.total) · \(p.converted) rewritten")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Button {
                    library.normalizeLibraryToZip()
                } label: {
                    Label("Convert comics to streamable ZIP", systemImage: "bolt.horizontal.circle")
                }
                .disabled(archiveCount == 0)
                Text(archiveCount == 0
                     ? "No archived comics in the library."
                     : "\(archiveCount) archived comic\(archiveCount == 1 ? "" : "s") will be checked; "
                       + "only non-ZIP ones are rewritten.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 4)

            Text("Online metadata").font(.headline)
            Text("For comics without embedded ComicInfo.xml, fetch series, creators, publisher, and "
                 + "summary from ComicVine (a free key: comicvine.gamespot.com/api). The result is "
                 + "saved as a standard ComicInfo.xml, so your readers and OPDS see it too.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("ComicVine API key", text: $comicVineKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: comicVineKey) { _, v in ComicVine.apiKey = v.trimmingCharacters(in: .whitespaces) }
                Image(systemName: ComicVine.hasKey ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(ComicVine.hasKey ? .green : .secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Refresh saved metadata").font(.headline)
                    Text("Refreshes comics already linked to a ComicVine volume. Comics without a saved link are left untouched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    metadataRefresh.refreshKnownMetadata()
                } label: {
                    Label("Refresh Known", systemImage: "arrow.clockwise")
                }
                .disabled(!ComicVine.hasKey || metadataRefresh.isRunning)
                .pointingHandCursor()
            }

            if metadataRefresh.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(metadataRefresh.completed),
                                 total: Double(max(metadataRefresh.total, 1)))
                    Text(metadataRefresh.summary + (metadataRefresh.currentTitle.map { " · \($0)" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if !metadataRefresh.summary.isEmpty {
                Text(metadataRefresh.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        if panel.runModal() == .OK { panel.urls.forEach { library.addFolder($0) } }
    }
}

/// Preferences → Downloads: choose where online comics are written.
private struct DownloadsSettingsTab: View {
    @State private var destination = DownloadDestinationStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download destination").font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: destination.isCustom ? "folder.fill" : "books.vertical")
                        .foregroundStyle(destination.isCustom ? Color.accentColor : Color.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(destination.isCustom ? "Custom folder" : "Library (automatic)")
                            .font(.body.weight(.medium))
                        Text(destination.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button {
                        destination.chooseFolder()
                    } label: {
                        Label("Choose…", systemImage: "folder")
                    }
                    .pointingHandCursor()
                }
                .padding(12)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            Text(destination.isCustom
                 ? "Custom folders disable automatic series filing."
                 : "Automatic downloads use the first library folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    destination.openInFinder()
                } label: {
                    Label("Open in Finder", systemImage: "arrow.up.forward.app")
                }
                .disabled(!destination.isCustom && LibraryModel.shared.folders.isEmpty)
                .pointingHandCursor()

                if destination.isCustom {
                    Button("Use Library (automatic)") {
                        destination.resetToAutomatic()
                    }
                    .pointingHandCursor()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Queue").font(.headline)
                Text("Downloads continue in the background. Reopen the queue from the toolbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
    }
}

/// Preferences → Connect: proof-of-concept Cloudflare gate for talking to a site's CMS.
private struct ConnectTab: View {
    @State private var showGate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to a site").font(.headline)
            Text("Some sites (e.g. ReadComicsOnline) sit behind a Cloudflare check that blocks direct "
                 + "requests. This opens the site in a real browser so you can solve the check once; "
                 + "the app captures the clearance and verifies it can then reach the site itself — "
                 + "the groundwork for importing a whole series automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                showGate = true
            } label: {
                Label("Open Cloudflare gate…", systemImage: "shield.lefthalf.filled")
            }
            Spacer()
        }
        .padding(20)
        .sheet(isPresented: $showGate) {
            CloudflareGateSheet(onClose: { showGate = false })
        }
    }
}

/// Preferences → Sharing: turn the LAN comic server on/off and show how a phone connects.
private struct SharingTab: View {
    @State private var server = ComicServer.shared
    @State private var on = ComicServer.shared.isRunning

    private var connectURL: String? {
        server.primaryURL.map { "\($0)/?code=\(server.pairingCode)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share over Wi-Fi").font(.headline)
            Text("Serve this library to other devices on your local network (e.g. a phone). "
                 + "The device must be on the same Wi-Fi and enter the pairing code.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Share library over Wi-Fi", isOn: $on)
                .onChange(of: on) { _, v in server.enabled = v }
                .toggleStyle(.switch)

            if server.isRunning {
                Divider()
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        row("Address", server.primaryURL ?? "—")
                        if server.addresses.count > 1 {
                            ForEach(server.addresses.dropFirst(), id: \.self) { ip in
                                row("", "http://\(ip):\(server.port)")
                            }
                        }
                        row("Pairing code", server.pairingCode)
                        Text("Pair once on the phone; a session token is used afterward.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Running on port \(server.port).")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let link = connectURL, let qr = ServerImage.qrImage(from: link, size: 150) {
                        VStack(spacing: 6) {
                            Image(nsImage: qr).interpolation(.none).frame(width: 150, height: 150)
                            Text("Scan to connect").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        server.regeneratePairingCode()
                    } label: {
                        Label("Regenerate Pairing Code", systemImage: "key.horizontal")
                    }
                    .pointingHandCursor()

                    Text("This disconnects all paired devices.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Sharing is off.").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            Spacer()
        }
        .padding(20)
        .onAppear { on = server.isRunning }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption.weight(.semibold)).frame(width: 90, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }
}
