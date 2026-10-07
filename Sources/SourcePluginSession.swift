import SwiftUI
import WebKit

/// A browser recovery retries its original operation once when the sheet closes.
@MainActor
final class SourceSessionRecovery {
    private var operation: (() -> Void)?
    func prepare(_ operation: @escaping () -> Void) { self.operation = operation }
    func cancel() { operation = nil }
    func browserClosed() {
        let retry = operation
        operation = nil
        retry?()
    }
}

struct SourceErrorPresentation {
    let title: String
    let detail: String
    init(_ message: String) {
        detail = message
        let expression = try? NSRegularExpression(pattern: "\\bHTTP\\s+([1-5][0-9]{2})\\b", options: .caseInsensitive)
        if let match = expression?.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
           let range = Range(match.range(at: 1), in: message) {
            title = "Error " + message[range]
        } else { title = "Couldn’t connect to source" }
    }
}

/// Embedded browser session for an installed source plugin.
/// Useful for sources that require a user to complete login, cookie, or browser challenge steps.
struct SourcePluginSessionSheet: View {
    let plugin: SourcePlugin
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var canGoBack = false
    @State private var canGoForward = false

    private var webView: WKWebView {
        SourcePluginRuntime.shared.sessionWebView(for: plugin)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).font(.headline)
                    Text("Source browser session").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()

                Button {
                    webView.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoBack)
                .help("Back")

                Button {
                    webView.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoForward)
                .help("Forward")

                Button {
                    webView.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            SourcePluginWebView(webView: webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 900, minHeight: 650)
        .onReceive(webView.publisher(for: \.canGoBack)) { canGoBack = $0 }
        .onReceive(webView.publisher(for: \.canGoForward)) { canGoForward = $0 }
        .task {
            do {
                try await SourcePluginRuntime.shared.openSession(for: plugin)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct SourcePluginWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Issue-specific covers are resolved only for visible cards, with the series cover as fallback.
struct PluginComicCover: View {
    let comic: RemoteComic
    var maxPixel: Int = 320
    @State private var issueCover: (key: String, resource: PluginResourceRequest)?

    private var coverPlugin: SourcePlugin? {
        guard comic.canRead, let id = comic.sourceID,
              let plugin = SourcePluginStore.shared.plugin(id: id), plugin.enabled,
              plugin.capabilities?.contains("first-page-covers") == true else { return nil }
        return plugin
    }

    private var coverKey: String? {
        guard let plugin = coverPlugin, let url = comic.pageURL else { return nil }
        return PluginIssueCoverCache.key(plugin: plugin, url: url)
    }

    var body: some View {
        let key = coverKey
        let remembered = key.flatMap { PluginIssueCoverCache.shared.remembered(key: $0) }
        let cover = remembered ?? (issueCover?.key == key ? issueCover?.resource : nil) ?? comic.coverRequest
        CoverImage(url: cover?.url ?? comic.coverURL, maxPixel: maxPixel, resource: cover) {
            Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.white.opacity(0.4))
        }
        .task(id: key) {
            guard let key, let plugin = coverPlugin else { return }
            if let cached = PluginIssueCoverCache.shared.remembered(key: key) {
                issueCover = (key, cached)
                return
            }
            do {
                if let cached = PluginIssueCoverCache.shared.load(key: key) {
                    issueCover = (key, cached)
                    return
                }
                // Avoid starting requests for cards that merely pass through while scrolling.
                try await Task.sleep(for: .milliseconds(200))
                let resolved = try await SourcePluginRuntime.shared.issueCover(for: plugin, comic: comic)
                try Task.checkCancellation()
                if let resolved { issueCover = (key, resolved) }
            } catch { /* Keep the series thumbnail if discovery fails or scrolling cancels it. */ }
        }
    }
}

@MainActor
final class PluginIssueCoverCache {
    static let shared = PluginIssueCoverCache()
    struct Entry: Codable { let saved: Date; let resource: PluginResourceRequest }
    let directory: URL
    private var memory: [String: Entry] = [:]
    static func key(plugin: SourcePlugin, url: URL) -> String {
        plugin.id + ":" + (plugin.scriptHash ?? plugin.version) + ":" + url.absoluteString
    }
    /// Synchronous memory lookup prevents recycled grid cards displaying the series cover.
    func remembered(key: String) -> PluginResourceRequest? {
        guard let entry = memory[key], Date().timeIntervalSince(entry.saved) < 14 * 24 * 3600 else { return nil }
        return entry.resource
    }
    init(directory: URL = CentralStore.baseDir.appendingPathComponent("issue-covers")) { self.directory = directory }
    private func file(_ key: String) -> URL { directory.appendingPathComponent(CentralStore.sha256(key) + ".json") }
    func load(key: String) -> PluginResourceRequest? {
        let entry = memory[key] ?? (try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: file(key))))
        guard let entry, Date().timeIntervalSince(entry.saved) < 14 * 24 * 3600 else { return nil }
        memory[key] = entry
        return entry.resource
    }
    func save(_ resource: PluginResourceRequest, key: String) {
        let entry = Entry(saved: Date(), resource: resource)
        memory[key] = entry
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: file(key), options: .atomic) }
    }
}
