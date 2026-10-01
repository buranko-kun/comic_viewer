import SwiftUI
import AppKit

/// The same item action is used by browse and search, including cancellation before navigation.
@MainActor
enum PluginComicOpener {
    static func open(_ comic: RemoteComic, router: AppRouter) async throws {
        guard let url = comic.pageURL else { return }
        guard let id = comic.sourceID, let plugin = SourcePluginStore.shared.plugin(id: id), plugin.enabled else {
            NSWorkspace.shared.open(url)
            return
        }
        if comic.opensCatalog {
            let catalog = try await SourcePluginRuntime.shared.catalog(plugin: plugin, at: url)
            try Task.checkCancellation()
            BrowseState.shared.clearSearch()
            BrowseState.shared.resetScroll()
            BrowseState.shared.stack = [catalog]
            BrowseState.shared.revision += 1
            router.showOnline()
        } else if comic.canRead {
            let resources = try await SourcePluginRuntime.shared.pageResources(for: plugin, comic: comic)
            let pages = resources.map { PluginResourceRegistry.shared.boundURL(for: $0) }
            try Task.checkCancellation()
            guard !pages.isEmpty else { throw SourcePluginRuntime.PluginError.invalidResult }
            let readingComic = Comic(url: url, series: comic.series ?? comic.title, isArchive: false,
                                     coverURL: comic.coverRequest.map { PluginResourceRegistry.shared.boundURL(for: $0) } ?? pages.first, pageCount: pages.count,
                                     progress: nil, chapterCount: 0, metaTitle: comic.title,
                                     tooltip: comic.description, remotePages: pages)
            RemoteReadingHistory.shared.record(readingComic)
            router.openComic(readingComic, origin: .browse)
        } else { NSWorkspace.shared.open(url) }
    }
}

/// Explicit operations against the installed copy; reload is the only source-file mutation here.
struct SourcePluginDevelopmentView: View {
    let plugin: SourcePlugin
    @Environment(\.dismiss) private var dismiss
    @State private var diagnostics = SourcePluginDiagnostics.shared
    @State private var operation = "Browse root"
    @State private var target = ""
    @State private var output = "Choose an operation and run it against the installed plugin."
    @State private var running = false
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var preview: CGImage?
    @State private var previewComics: [RemoteComic] = []
    @State private var session = false
    @State private var resultTab = "Result"
    @State private var probeReferrer = ""
    @State private var probeCookies = false
    @State private var previewPages: [PluginResourceRequest] = []

    private var current: SourcePlugin { SourcePluginStore.shared.plugin(id: plugin.id) ?? plugin }
    private var report: SourcePluginRunReport? { diagnostics.latestReport(for: plugin.id) }
    private var scriptHash: String {
        SourcePluginStore.shared.script(for: current).map { CentralStore.sha256($0) } ?? "Missing script"
    }
    private var needsURL: Bool { ["Browse URL", "Resolve pages", "Probe image"].contains(operation) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Develop source: \(current.name)").font(.title2.bold())
                Spacer()
                Button("Done") { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(current.id) · v\(current.version) · SHA-256 \(scriptHash)")
                .font(.caption.monospaced()).textSelection(.enabled)
            Text(current.sourceURL.isFileURL ? current.sourceURL.path : current.sourceURL.absoluteString)
                .font(.caption).textSelection(.enabled).lineLimit(2)
            HStack {
                Button(current.sourceURL.isFileURL ? "Reload from file" : "Update from URL") { reload() }
                    .disabled(running)
                if current.sourceURL.isFileURL {
                    Button("Reveal file") { NSWorkspace.shared.activateFileViewerSelecting([current.sourceURL]) }
                }
                Button("Open source session") { session = true }
                Spacer()
                if let report { Text("Last run: \(report.status) · \(report.duration, specifier: "%.2f") s").font(.caption) }
            }
            Divider()
            HStack {
                Picker("Operation", selection: $operation) {
                    ForEach(["Validate manifest", "Browse root", "Browse URL", "Resolve pages", "Probe image", "Clear plugin cache"], id: \.self) {
                        Text($0).tag($0)
                    }
                }.frame(width: 300).disabled(running)
                if needsURL { TextField("https://…", text: $target).textFieldStyle(.roundedBorder).disabled(running) }
                Spacer()
                Button("Run / Retry") { run() }.disabled(running || (needsURL && validTarget == nil))
                if running { ProgressView().controlSize(.small); Button("Cancel") { cancel() } }
            }
            if operation == "Probe image" {
                HStack {
                    TextField("Optional referrer URL", text: $probeReferrer).textFieldStyle(.roundedBorder)
                    Toggle("Use browser cookies", isOn: $probeCookies)
                }.disabled(running)
            }
            Text("Cache clearing requires the plugin's cache hook. Raw output may contain source data; reports redact sensitive fields.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Output", selection: $resultTab) {
                Text("Result").tag("Result")
                Text("Raw JSON").tag("Raw JSON")
                Text("Normalized JSON").tag("Normalized JSON")
                Text("Report").tag("Report")
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(displayedOutput).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if resultTab == "Result" {
                        if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit().frame(height: 200) }
                        HStack(alignment: .top) {
                            ForEach(Array(previewPages.prefix(4).enumerated()), id: \.offset) { index, request in
                                VStack {
                                    CoverImage(url: request.url, maxPixel: 240, resource: request) { Image(systemName: "photo") }
                                        .frame(width: 105, height: 145)
                                    Text("Page \(index + 1)").font(.caption)
                                }
                            }

                            ForEach(Array(previewComics.prefix(4))) { comic in
                                VStack {
                                    CoverImage(url: comic.coverURL, maxPixel: 240, resource: comic.coverRequest) { Image(systemName: "book.closed") }
                                        .frame(width: 105, height: 145)
                                    Text(comic.title).font(.caption).lineLimit(2).frame(width: 105)
                                }
                            }
                        }
                    }
                }.padding(8)
            }.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Copy displayed output") { copy(displayedOutput) }
                Button("Copy diagnostic report") { if let report { copy(report.prettyJSON) } }.disabled(report == nil)
                Spacer()
                Text("Latest \(diagnostics.reports.filter { $0.pluginID == plugin.id }.count) retained runs").font(.caption)
            }
        }
        .padding(20).frame(width: 940, height: 650)
        .onAppear { diagnostics.setCaptureEnabled(true, for: plugin.id) }
        .onDisappear { cancel(); diagnostics.setCaptureEnabled(false, for: plugin.id) }
        .sheet(isPresented: $session) { SourcePluginSessionSheet(plugin: current) }
    }

    private var validTarget: URL? {
        guard let url = URL(string: target), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    private var displayedOutput: String {
        switch resultTab {
        case "Raw JSON": return report?.rawJSON ?? "No captured raw output."
        case "Normalized JSON": return report?.normalizedJSON ?? "No normalized output."
        case "Report": return report?.prettyJSON ?? "No report yet."
        default: return output
        }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func cancel() {
        task?.cancel(); task = nil
        if running { SourcePluginRuntime.shared.cancel(pluginID: plugin.id); output = "Cancelled." }
        running = false; generation = UUID()
    }
    private func perform(_ action: @escaping @MainActor () async throws -> String) {
        cancel(); running = true; preview = nil; previewComics = []; previewPages = []
        let token = generation
        output = "Running…"
        task = Task { @MainActor in
            do {
                let value = try await action()
                guard !Task.isCancelled, generation == token else { return }
                output = value
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                output = error.localizedDescription
            }
            running = false; task = nil
        }
    }
    private func reload() {
        perform {
            let updated = try await SourcePluginStore.shared.update(current)
            await CatalogAggregator.shared.refreshPlugin(updated.id)
            return "Reloaded \(updated.name) v\(updated.version). The installed copy and source results are current."
        }
    }
    private func run() {
        let selected = operation
        let url = validTarget
        perform {
            switch selected {
            case "Validate manifest":
                guard let script = SourcePluginStore.shared.script(for: current) else { return "Installed script is missing." }
                let manifest = try await SourcePluginRuntime.shared.manifest(for: script, pluginID: current.id)
                return "Valid: \(manifest.name) v\(manifest.version)"
            case "Browse root", "Browse URL":
                let catalog: RemoteCatalog
                if selected == "Browse URL", let url {
                    catalog = try await SourcePluginRuntime.shared.catalog(plugin: current, at: url)
                } else { catalog = try await SourcePluginRuntime.shared.catalog(plugin: current) }
                try Task.checkCancellation()
                previewComics = Array(catalog.comics.prefix(4))
                return "\(catalog.name): \(catalog.comics.count) items, \(catalog.childCatalogs.count) folders."
            case "Resolve pages":
                guard let url else { return "Enter an HTTP(S) issue URL." }
                let comic = RemoteComic(id: "developer-probe", title: "Developer probe", description: nil,
                                        coverString: nil, series: nil, mirrors: [], format: nil,
                                        metadata: [:], sourceName: current.name, sourceID: current.id,
                                        pageString: url.absoluteString, canRead: true)
                let pages = try await SourcePluginRuntime.shared.pageResources(for: current, comic: comic)
                try Task.checkCancellation()
                previewPages = Array(pages.prefix(4))
                return "\(pages.count) pages\n" + pages.map { $0.url.absoluteString }.joined(separator: "\n")
            case "Clear plugin cache":
                try await SourcePluginRuntime.shared.clearCache(for: current)
                CatalogAggregator.shared.invalidatePlugin(current.id)
                return "Plugin cache cleared. Run Browse root to load current data."
            case "Probe image":
                guard let url else { return "Enter an HTTP(S) image URL." }
                let existing = PluginResourceRegistry.shared.request(for: url)
                let resource = PluginResourceRequest(url: url,
                    referrer: SourcePluginContract.httpURL(probeReferrer) ?? existing.referrer,
                    useBrowserCookies: probeCookies || existing.useBrowserCookies, pluginID: current.id)
                let probe = await PluginResourceTransport.probe(resource)
                try Task.checkCancellation()
                if probe.success { preview = await RemoteImageCache.shared.image(for: resource, maxPixel: 480) }
                return "\(probe.message)\nHTTP: \(probe.statusCode.map(String.init) ?? "unavailable")\nContent type: \(probe.contentType ?? "unavailable")\nBytes: \(probe.byteCount)"
            default: return "Choose an operation."
            }
        }
    }
}
