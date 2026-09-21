import SwiftUI
import WebKit

/// Proof-of-concept "Cloudflare gate". Shows the challenged site in a real `WKWebView` so the user
/// can clear the "Just a moment…" check, captures the `cf_clearance` cookie + the browser's
/// User-Agent, then verifies a **plain `URLSession`** request (same cookie + UA) can now fetch a
/// real CMS page instead of a 403. If that works, a full site connector can scrape the catalog
/// through `URLSession` without a browser for every request.
@MainActor
@Observable
final class CloudflareSession {
    /// The app-wide session. The gate sheet and the reader share one `WKWebView` (default,
    /// **persistent** data store) so a Cloudflare check solved once in the gate carries over to
    /// series/chapter fetches everywhere — its `cf_clearance` cookie lives on across app runs.
    static let shared = CloudflareSession()

    let webView: WKWebView
    var verifying = false
    private var didLoadOrigin = false

    /// High-level connection state, so the gate UI can hide the raw browser and only surface it when
    /// a challenge is genuinely up: `.checking` (probing), `.challenge` (user must tap Cloudflare's
    /// box), `.connected` (the app can reach the site). Drives a polished, app-matching gate.
    enum Status: Equatable { case checking, challenge, connected }
    var status: Status = .checking

    /// A real content page (behind Cloudflare) whose HTML lists the series' chapters.
    let target = URL(string: "https://readcomicsonline.ru/comic/spawn-1992")!

    init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    func load() { webView.load(URLRequest(url: target)); didLoadOrigin = true }

    /// Probe whether the app can currently reach the site (a same-origin fetch returns 200), and
    /// update `status`. Cheap; called on a poll so the gate auto-advances the moment the user clears
    /// the check — no "Verify" press needed.
    func refreshStatus() async {
        await ensureLoaded()
        status = (await fetchHTMLViaWebView(target) != nil) ? .connected : .challenge
    }

    /// Ensure the WebView has navigated to the site origin at least once, so the in-page `fetch`
    /// runs same-origin (carrying cookies + the cleared TLS fingerprint). Reads call this first.
    func ensureLoaded() async {
        guard !didLoadOrigin else { return }
        load()
        // Give the initial navigation a moment to settle before the first in-page fetch.
        try? await Task.sleep(for: .seconds(2))
    }

    /// Connector method: fetch a comic page through the cleared WebView and parse it. This is the
    /// UI-facing shape — callers never touch Cloudflare or the WebView.
    func fetchSeries(_ url: URL) async -> ComicSeries? {
        await ensureLoaded()
        guard let html = await fetchHTMLViaWebView(url) else { return nil }
        return ReadComicsParser.parseSeries(html, pageURL: url)
    }

    /// Like `fetchSeries` but also returns the fetched HTML byte count — 0 means the page fetch
    /// itself failed (Cloudflare/URL), non-zero with empty chapters means a parser gap. Used by the
    /// series view to explain *why* a series couldn't load.
    func fetchSeriesDiagnosed(_ url: URL) async -> (series: ComicSeries?, htmlBytes: Int) {
        await ensureLoaded()
        guard let html = await fetchHTMLViaWebView(url) else { return (nil, 0) }
        return (ReadComicsParser.parseSeries(html, pageURL: url), html.utf8.count)
    }

    /// Fetch a same-origin URL from inside the cleared WebView and return the raw HTML (nil on a
    /// non-200 or failure). This is the connector's request path — it inherits the browser's cookies
    /// *and* TLS fingerprint, so Cloudflare lets it through where a plain URLSession can't.
    private func fetchHTMLViaWebView(_ url: URL) async -> String? {
        let body = """
        const r = await fetch(url, { credentials: 'include' });
        const text = await r.text();
        return JSON.stringify({ status: r.status, url: r.url, html: text });
        """
        guard let raw = try? await webView.callAsyncJavaScript(
                body, arguments: ["url": url.absoluteString], contentWorld: .page) as? String,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? Int,
              let html = obj["html"] as? String,
              status == 200
        else { return nil }
        return html
    }

    /// Connector method: fetch a chapter page through the cleared WebView and return its exact page
    /// image URLs. UI-facing — no Cloudflare/WebView knowledge required by callers.
    func fetchChapterPages(_ url: URL) async -> [URL] {
        await ensureLoaded()
        guard let html = await fetchHTMLViaWebView(url) else { return [] }
        return ReadComicsParser.parseChapterPages(html)
    }

    /// Connector method: fetch one `/comic-list?page=N` directory page through the cleared WebView
    /// and return its series cards plus the total number of catalog pages. UI-facing.
    func fetchCatalogPage(_ page: Int) async -> (entries: [CatalogEntry], pageCount: Int) {
        await ensureLoaded()
        guard let url = URL(string: "https://readcomicsonline.ru/comic-list?page=\(page)"),
              let html = await fetchHTMLViaWebView(url) else { return ([], 0) }
        return ReadComicsParser.parseCatalog(html)
    }
}

private struct CloudflareWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// The gate sheet: solve the Cloudflare check in the embedded browser, verify the app can reach the
/// site, and mirror the full catalog. Just those two actions — everything else is automatic.
struct CloudflareGateSheet: View {
    @State private var session = CloudflareSession.shared
    @State private var catalog = ReadComicsCatalogStore.shared
    @State private var mirrorTask: Task<Void, Never>?
    let onClose: () -> Void

    /// Polls the connection state so the sheet auto-advances the instant the user clears the check.
    @State private var poll: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .onAppear { startPolling() }
        .onDisappear { poll?.cancel() }
    }

    /// Keep probing (until connected) so solving the Cloudflare box flips us to the success state on
    /// its own — no button press.
    private func startPolling() {
        session.status = .checking
        session.load()
        poll?.cancel()
        poll = Task {
            while !Task.isCancelled {
                await session.refreshStatus()
                if session.status == .connected { break }
                try? await Task.sleep(for: .seconds(1.2))
            }
        }
    }

    // MARK: Content — our chrome; the raw browser only appears during an actual challenge.

    @ViewBuilder private var content: some View {
        switch session.status {
        case .checking:
            centered {
                ProgressView().controlSize(.large)
                Text("Checking connection…").font(.callout).foregroundStyle(.secondary)
            }
        case .connected:
            centered {
                ZStack {
                    Circle().fill(.green.opacity(0.15)).frame(width: 76, height: 76)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 46)).foregroundStyle(.green)
                }
                Text("Connected to ReadComicsOnline").font(.title3.weight(.semibold))
                Text("The app can reach the site. Mirror the catalog below to browse it.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        case .challenge:
            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text("Quick security check").font(.headline)
                    Text("Tap the checkbox once to confirm you're human. This is only needed "
                         + "occasionally; the app remembers it afterward.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 18).padding(.horizontal, 24)
                // The real Cloudflare widget, framed to match the app. It can't be replaced by a
                // custom control (it's a protected cross-origin check), but we keep the chrome ours.
                CloudflareWebView(webView: session.webView)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
                    .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 12) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect to ReadComicsOnline").font(.headline)
                Text("Bring the full catalog into the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark").font(.body.weight(.medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .background(.quaternary, in: Circle())
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    // MARK: Footer — mirror the catalog (only meaningful once connected).

    private var footer: some View {
        HStack(spacing: 12) {
            mirrorControl
            Spacer()
        }
        .padding(20)
        .opacity(session.status == .connected ? 1 : 0.35)
        .disabled(session.status != .connected)
    }

    /// Mirror-the-whole-site control: a button that becomes a live progress readout while scraping,
    /// with a freshness line (count · updated-when) and a staleness nudge underneath.
    @ViewBuilder private var mirrorControl: some View {
        if let p = catalog.progress {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                        .frame(width: 160)
                    Text("\(p.done)/\(p.total) · \(p.series) series")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Stop") { mirrorTask?.cancel() }
                }
                Text("Refreshing the catalog…").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    mirrorTask = Task { await catalog.mirror(using: session) }
                } label: {
                    Label(catalog.isMirrored ? "Refresh catalog" : "Mirror full catalog",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                if catalog.isMirrored {
                    HStack(spacing: 6) {
                        Text("\(catalog.entries.count) series")
                        if let u = catalog.updatedText { Text("· \(u)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)

                    if let change = catalog.lastChangeSummary {
                        Label(change, systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.green)
                    } else if catalog.isStale {
                        Label("A while since the last update — refresh to pull in new series.",
                              systemImage: "clock.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
