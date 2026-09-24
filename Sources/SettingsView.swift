import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Preferences (⌘,) — manage the catalog sources that populate the Online section. Add a
/// server URL, import a `.txt` of URLs, or remove sources. Changes re-query the servers.
struct SettingsView: View {
    private let sources = CatalogSourceStore.shared
    @State private var newURL = ""
    @State private var note: String?

    var body: some View {
        TabView {
            ReaderTab()
                .tabItem { Label("Reader", systemImage: "book") }
            sourcesTab
                .tabItem { Label("Sources", systemImage: "externaldrive.connected.to.line.below") }
            LibraryTab()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            ConnectTab()
                .tabItem { Label("Connect", systemImage: "network") }
            SharingTab()
                .tabItem { Label("Sharing", systemImage: "wifi") }
        }
        .frame(width: 580, height: 440)
    }

    private var sourcesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Catalog sources").font(.headline)
            Text("Each source is a URL to a JSON catalog (or OPDS feed) on your server. The app "
                 + "fetches them, normalizes the data, and shows the comics in the Online section.")
                .font(.caption).foregroundStyle(.secondary)

            List {
                if sources.sources.isEmpty {
                    Text("No sources yet.").foregroundStyle(.secondary)
                }
                ForEach(sources.sources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name).fontWeight(.medium)
                            Text(source.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) { remove(source) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 180)

            HStack {
                TextField("https://your-server/catalog.json  or  /path/to/index.json", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Button("Add", action: addTyped)
                    .disabled(CatalogSourceStore.makeURL(from: newURL) == nil)
            }

            HStack {
                Button { importTxt() } label: { Label("Import from .txt…", systemImage: "square.and.arrow.down") }
                Spacer()
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Text("The .txt lists one URL per line. Lines starting with # are ignored; an optional "
                 + "“Name | URL” sets a custom label.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
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

    /// Re-query servers so the Online section reflects the change.
    private func refresh() { Task { await CatalogAggregator.shared.loadRoots() } }
}

/// Preferences → Reader: how comics open and display.
private struct ReaderTab: View {
    @State private var settings = ReaderSettings.shared

    var body: some View {
        @Bindable var s = settings
        return VStack(alignment: .leading, spacing: 18) {
            Text("Reader").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Picker("Default view", selection: $s.defaultView) {
                    ForEach(ReaderSettings.DefaultView.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 260)
                Text("Horizontal shows pages as-is. Vertical rotates portrait pages to landscape "
                     + "(landscape pages stay as they are). Press R while reading to switch a single "
                     + "comic — it resets to this default when you leave.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Reading direction", selection: $s.readingDirection) {
                    ForEach(ReaderSettings.ReadingDirection.allCases) {
                        Text($0.label).tag($0)
                    }
                }
                .pickerStyle(.segmented).frame(maxWidth: 260)
                Text("Right to left reverses the physical page layout and horizontal navigation. "
                     + "Saved page positions and logical page order stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $s.fitWideToWidth) {
                Text("Fit pages to screen width")
                Text("In Vertical view, pages fill the full screen width and pan vertically instead of "
                     + "shrinking to fit the whole page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(s.defaultView == .horizontal)
            .opacity(s.defaultView == .horizontal ? 0.5 : 1)

            Toggle(isOn: $s.showProgressBar) {
                Text("Show chapter progress bar")
                Text("The thin bar along the bottom of the reader showing your position through the "
                     + "current chapter.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
    }
}

/// Preferences → Library: one-time maintenance to make comics stream fast.
private struct LibraryTab: View {
    @State private var library = LibraryModel.shared
    @State private var comicVineKey = ComicVine.apiKey

    private var archiveCount: Int { library.comics.filter(\.isArchive).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Library folders").font(.headline)
            Text("Folders scanned for comics. Add the folders that hold your library.")
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
