import Foundation
import WebKit

/// Production and fixture execution share this runtime. Each plugin has a serial worker;
/// interactive sessions never navigate a worker's WebView.
@MainActor
final class SourcePluginRuntime {
    static let shared = SourcePluginRuntime()
    enum PluginError: LocalizedError {
        case invalidPlugin(String), invalidResult, invalidResultDetail(String), oversizedResult
        case navigation(Error), javascript(Error), timeout, terminated, httpStatus(Int)
        var errorDescription: String? {
            switch self {
            case .invalidPlugin(let s): return "Invalid source plugin: \(s)"
            case .invalidResult: return "Source plugin returned invalid data."
            case .invalidResultDetail(let s): return "Invalid plugin result: \(s)"
            case .oversizedResult: return "Source plugin returned too much data."
            case .navigation(let e): return "Source page couldn't load: \(e.localizedDescription)"
            case .javascript(let e):
                let details = (e as NSError).userInfo
                let message = details["WKJavaScriptExceptionMessage"] as? String ?? e.localizedDescription
                let line = details["WKJavaScriptExceptionLineNumber"].map { " (line \($0))" } ?? ""
                return "Source JavaScript failed: \(message)\(line)"
            case .httpStatus(let status): return "Source returned HTTP \(status). Open the source browser if login or verification is required."
            case .timeout: return "Source operation timed out. The worker was reset."
            case .terminated: return "Source browser process terminated. Retry the operation."
            }
        }
    }
    struct Fixture {
        let html: String
        let baseURL: URL
        let responsesJSON: String
        let settingsJSON: String
    }
    private var workers: [String: SourcePluginWorker] = [:]
    private var browsers: [String: WKWebView] = [:]
    private var fixtures: [String: Fixture] = [:]
    private var active: [String: UUID] = [:]
    private var generations: [String: Int] = [:]

    func sessionWebView(for plugin: SourcePlugin) -> WKWebView {
        if let view = browsers[plugin.id] { return view }
        let view = WKWebView(frame: .zero)
        browsers[plugin.id] = view
        return view
    }
    func openSession(for plugin: SourcePlugin) async throws {
        guard let raw = plugin.homepage, let url = SourcePluginContract.httpURL(raw) else {
            throw PluginError.invalidPlugin("homepage must be an HTTP(S) URL")
        }
        sessionWebView(for: plugin).load(URLRequest(url: url))
    }
    func invalidate(pluginID: String) {
        generations[pluginID, default: 0] += 1
        workers.removeValue(forKey: pluginID)?.stop(CancellationError())
        PluginResourceRegistry.shared.invalidateSession(pluginID: pluginID)
    }
    func cancel(pluginID: String) { invalidate(pluginID: pluginID) }
    func setFixture(pluginID: String, html: String, baseURL: URL, responsesJSON: String, settingsJSON: String = "{}") {
        invalidate(pluginID: pluginID)
        fixtures[pluginID] = Fixture(html: html, baseURL: baseURL, responsesJSON: responsesJSON, settingsJSON: settingsJSON)
    }
    func clearFixture(pluginID: String) { invalidate(pluginID: pluginID); fixtures[pluginID] = nil }
    func fixtureRequestURLs(pluginID: String) async -> [String] {
        guard let worker = workers[pluginID] else { return [] }
        return (try? await worker.call("return globalThis.__fixtureRequests || [];")) as? [String] ?? []
    }

    func manifest(for script: String, pluginID: String? = nil) async throws -> SourcePluginManifest {
        let worker = SourcePluginWorker(persistent: false)
        let began = Date()
        do {
        let manifest = try await worker.bounded(seconds: 30) {
            try await worker.loadHTML("<!doctype html><html></html>", baseURL: nil)
            try await worker.install(script)
            let json = try await worker.json("""
            const s = globalThis.ComicViewerSource;
            if (!s || typeof s !== 'object') throw new Error('ComicViewerSource is missing');
            if (!s.manifest) throw new Error('manifest is missing');
            if (typeof s.parseCatalog !== 'function') throw new Error('parseCatalog() is missing');
            if (!['string','function'].includes(typeof s.browseURL)) throw new Error('browseURL must be a string or function');
            if ((s.manifest.capabilities || []).includes('read') && typeof s.parsePages !== 'function') throw new Error('read capability requires parsePages()');
            return JSON.stringify(s.manifest);
            """)
            return try SourcePluginContract.manifest(Data(json.utf8))
        }
        SourcePluginDiagnostics.shared.record(SourcePluginRunReport(id: UUID(), pluginID: manifest.id,
            pluginVersion: manifest.version, scriptHash: CentralStore.sha256(script), operation: "manifest",
            targetURL: nil, startedAt: began, duration: Date().timeIntervalSince(began), status: "completed", warnings: []))
        return manifest
        } catch {
            worker.stop(error)
            if let pluginID {
                SourcePluginDiagnostics.shared.record(SourcePluginRunReport(id: UUID(), pluginID: pluginID,
                    pluginVersion: "candidate", scriptHash: CentralStore.sha256(script), operation: "manifest",
                    targetURL: nil, startedAt: began, duration: Date().timeIntervalSince(began), status: "failed",
                    error: SourcePluginDiagnostics.redacted(error.localizedDescription), warnings: []))
            }
            throw error
        }
    }

    func catalog(plugin: SourcePlugin, refresh: Bool = false) async throws -> RemoteCatalog {
        try await catalog(plugin: plugin, script: installedScript(plugin), at: nil, refresh: refresh)
    }
    func catalog(plugin: SourcePlugin, at url: URL, refresh: Bool = false) async throws -> RemoteCatalog {
        try await catalog(plugin: plugin, script: installedScript(plugin), at: url, refresh: refresh)
    }
    func catalog(plugin: SourcePlugin, script: String, at explicitURL: URL?, refresh: Bool = false) async throws -> RemoteCatalog {
        try await run(plugin: plugin, script: script, operation: "catalog", target: explicitURL, refresh: refresh) { worker, report in
            if explicitURL == nil {
                try await self.prepare(worker, plugin: plugin, url: nil, script: script)
            }
            let target: URL
            if let explicitURL { target = explicitURL }
            else {
                let raw = try await worker.call("const r = ComicViewerSource.browseURL; return typeof r === 'function' ? await r() : r;")
                guard let raw = raw as? String, let url = SourcePluginContract.httpURL(raw) else { throw PluginError.invalidPlugin("browseURL must return an HTTP(S) URL") }
                target = url
            }
            try await self.prepare(worker, plugin: plugin, url: target, script: script)
            let json = try await self.invoke(worker, hook: "parseCatalog", url: target, refresh: refresh, operationID: report.id)
            report.rawJSON = json
            let normalizationStarted = Date()
            defer { report.stageDurations["normalization"] = Date().timeIntervalSince(normalizationStarted) }
            let result = try SourcePluginContract.catalog(json, plugin: plugin, baseURL: target)
            report.warnings += result.warnings
            report.normalizedJSON = result.json
            return result.catalog
        }
    }
    func pages(for plugin: SourcePlugin, comic: RemoteComic) async throws -> [URL] {
        guard comic.canRead, let url = comic.pageURL else { throw PluginError.invalidPlugin("comic is not readable") }
        return try await pages(plugin: plugin, script: installedScript(plugin), at: url)
    }
    func pages(plugin: SourcePlugin, script: String, at url: URL) async throws -> [URL] {
        try await pageResources(plugin: plugin, script: script, at: url).map(\.url)
    }
    func pageResources(for plugin: SourcePlugin, comic: RemoteComic) async throws -> [PluginResourceRequest] {
        guard comic.canRead, let url = comic.pageURL else { throw PluginError.invalidPlugin("comic is not readable") }
        return try await pageResources(plugin: plugin, script: installedScript(plugin), at: url)
    }
    func pageResources(plugin: SourcePlugin, script: String, at url: URL) async throws -> [PluginResourceRequest] {
        try await run(plugin: plugin, script: script, operation: "pages", target: url) { worker, report in
            try await self.prepare(worker, plugin: plugin, url: url, script: script)
            let json = try await self.invoke(worker, hook: "parsePages", url: url, refresh: false, operationID: report.id)
            report.rawJSON = json
            let normalizationStarted = Date()
            defer { report.stageDurations["normalization"] = Date().timeIntervalSince(normalizationStarted) }
            let result = try SourcePluginContract.pages(json, pluginID: plugin.id, baseURL: url)
            report.warnings += result.warnings
            report.normalizedJSON = result.json
            return result.resources
        }
    }
    func clearCache(for plugin: SourcePlugin) async throws {
        let script = try installedScript(plugin)
        let _: Bool = try await run(plugin: plugin, script: script, operation: "clearCache", target: nil) { worker, _ in
            try await self.prepare(worker, plugin: plugin, url: nil, script: script)
            _ = try await worker.call("if (typeof ComicViewerSource.clearCache !== 'function') throw new Error('This plugin does not support cache clearing'); await ComicViewerSource.clearCache(); return true;")
            return true
        }
    }

    /// Opt-in issue thumbnails resolve through the same page parser as the reader.
    func issueCover(for plugin: SourcePlugin, comic: RemoteComic) async throws -> PluginResourceRequest? {
        guard comic.canRead, plugin.capabilities?.contains("first-page-covers") == true,
              let url = comic.pageURL else { return comic.coverRequest }
        let key = PluginIssueCoverCache.key(plugin: plugin, url: url)
        if let cached = PluginIssueCoverCache.shared.load(key: key) {
            PluginResourceRegistry.shared.register(cached)
            return cached
        }
        guard let cover = try await pageResources(for: plugin, comic: comic).first else { return nil }
        PluginIssueCoverCache.shared.save(cover, key: key)
        return cover
    }
    private func installedScript(_ plugin: SourcePlugin) throws -> String {
        guard let script = SourcePluginStore.shared.script(for: plugin) else { throw PluginError.invalidPlugin("installed script is missing") }
        return script
    }
    private func prepare(_ worker: SourcePluginWorker, plugin: SourcePlugin, url: URL?, script: String) async throws {
        if let fixture = fixtures[plugin.id] {
            if !worker.fixtureLoaded { try await worker.loadFixture(fixture) }
        } else if plugin.capabilities?.contains("browser-session") == true {
            guard let raw = plugin.homepage, let homepage = SourcePluginContract.httpURL(raw) else { throw PluginError.invalidPlugin("browser-session requires an HTTP(S) homepage") }
            if worker.webView.url?.host != homepage.host || worker.webView.url?.scheme != homepage.scheme {
                if plugin.capabilities?.contains("static-session") == true {
                    // HTML scrapers only need a same-origin fetch/storage context. Loading
                    // the entire website also waits for ads, scripts, and other subresources.
                    try await worker.loadHTML("<!doctype html><html></html>", baseURL: homepage)
                } else {
                    try await worker.load(homepage)
                }
            }
        } else if let url { try await worker.load(url) }
        else { try await worker.loadHTML("<!doctype html><html></html>", baseURL: nil) }
        try await worker.install(script)
        let settings = fixtures[plugin.id]?.settingsJSON ?? SourcePluginSettingsStore.shared.settingsJSON(for: plugin)
        _ = try await worker.call("ComicViewerSource.settings = JSON.parse(settings); return true;", arguments: ["settings": settings])
    }
    private func invoke(_ worker: SourcePluginWorker, hook: String, url: URL, refresh: Bool, operationID: UUID) async throws -> String {
        let began = Date()
        defer { worker.timings["parse", default: 0] += Date().timeIntervalSince(began) }
        return try await worker.json("""
        const source = ComicViewerSource;
        if (typeof source[hook] !== 'function') throw new Error(hook + '() is missing');
        globalThis.__operationAbort = new AbortController();
        const context = {url, settings:source.settings, refresh, operationID,
            signal:globalThis.__operationAbort.signal,
            diagnostic: event => { if (globalThis.__pluginEvents.length < 100) globalThis.__pluginEvents.push(String(JSON.stringify(event)).slice(0,2048)); }};
        const result = await source[hook](context);
        if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error(hook + ' must return an object');
        return JSON.stringify(result);
        """, arguments: ["hook": hook, "url": url.absoluteString, "refresh": refresh, "operationID": operationID.uuidString])
    }
    private func run<T>(plugin: SourcePlugin, script: String, operation: String, target: URL?, refresh: Bool = false,
                        body: @escaping (SourcePluginWorker, inout SourcePluginRunReport) async throws -> T) async throws -> T {
        let id = UUID(), queued = Date(), generation = generations[plugin.id, default: 0]
        while active[plugin.id] != nil || active.count >= 2 {
            try Task.checkCancellation()
            guard generations[plugin.id, default: 0] == generation else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        guard generations[plugin.id, default: 0] == generation else { throw CancellationError() }
        active[plugin.id] = id
        let worker = workers[plugin.id] ?? SourcePluginWorker(persistent: fixtures[plugin.id] == nil)
        workers[plugin.id] = worker
        let began = Date()
        var report = SourcePluginRunReport(id: id, pluginID: plugin.id, pluginVersion: plugin.version,
            scriptHash: CentralStore.sha256(script), operation: operation,
            targetURL: target.map { SourcePluginDiagnostics.redacted($0.absoluteString) }, startedAt: began,
            duration: 0, status: "running", warnings: [])
        report.stageDurations["queue"] = began.timeIntervalSince(queued)
        SourcePluginDiagnostics.shared.record(report)
        defer {
            active[plugin.id] = nil
            report.duration = Date().timeIntervalSince(began)
            report.stageDurations.merge(worker.timings, uniquingKeysWith: { _, new in new })
            if !SourcePluginDiagnostics.shared.isCaptureEnabled(for: plugin.id) { report.rawJSON = nil; report.normalizedJSON = nil }
            else {
                report.rawJSON = report.rawJSON.map { String($0.prefix(65_536)) }
                report.normalizedJSON = report.normalizedJSON.map { String($0.prefix(65_536)) }
            }
            SourcePluginDiagnostics.shared.record(report)
        }
        do {
            worker.timings = [:]
            let result = try await worker.bounded(seconds: min(900, max(1, plugin.operationTimeoutSeconds ?? 60))) {
                try await body(worker, &report)
            }
            try Task.checkCancellation()
            guard generations[plugin.id, default: 0] == generation else { throw CancellationError() }
            report.console = ((try? await worker.call("return globalThis.__pluginEvents || [];")) as? [String] ?? [])
                .map { SourcePluginDiagnostics.redacted($0, limit: 2048) }
            report.status = "completed"
            return result
        } catch {
            worker.stop(error)
            if workers[plugin.id] === worker { workers[plugin.id] = nil }
            report.status = error is CancellationError ? "cancelled" : "failed"
            report.error = SourcePluginDiagnostics.redacted(error.localizedDescription)
            throw error
        }
    }
}

@MainActor
private final class SourcePluginWorker: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var fixtureLoaded = false
    var timings: [String: Double] = [:]
    private var navigation: WKNavigation?
    private var navigationCompletion: ((Result<Void, Error>) -> Void)?
    private var pending: [UUID: (Error) -> Void] = [:]
    private var terminalError: Error?
    init(persistent: Bool) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = persistent ? .default() : .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }
    func stop(_ error: Error) {
        terminalError = error
        webView.stopLoading()
        let finish = navigationCompletion; navigationCompletion = nil; navigation = nil
        finish?(.failure(error))
        let callbacks = pending.values; pending.removeAll()
        callbacks.forEach { $0(error) }
    }
    func bounded<T>(seconds: Double, operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)); self.stop(SourcePluginRuntime.PluginError.timeout) } catch {}
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation()
        } onCancel: { Task { @MainActor in self.stop(CancellationError()) } }
    }
    func load(_ url: URL) async throws {
        guard SourcePluginContract.httpURL(url.absoluteString) != nil else { throw SourcePluginRuntime.PluginError.invalidPlugin("target URL must use HTTP(S)") }
        try await navigate { self.webView.load(URLRequest(url: url)) }
    }
    func loadHTML(_ html: String, baseURL: URL?) async throws {
        try await navigate { self.webView.loadHTMLString(html, baseURL: baseURL) }
    }
    private func navigate(_ start: () -> WKNavigation?) async throws {
        if let terminalError { throw terminalError }
        let began = Date()
        defer { timings["navigation", default: 0] += Date().timeIntervalSince(began) }
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(30)); self.stop(SourcePluginRuntime.PluginError.timeout) } catch {}
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationCompletion = { continuation.resume(with: $0) }
            navigation = start()
            if navigation == nil { finish(nil, error: SourcePluginRuntime.PluginError.invalidResult) }
        }
    }
    func call(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        if let terminalError { throw terminalError }
        let id = UUID(), began = Date()
        defer { timings["javascript", default: 0] += Date().timeIntervalSince(began) }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = { continuation.resume(throwing: $0) }
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
                guard self?.pending.removeValue(forKey: id) != nil else { return }
                continuation.resume(with: result.map { $0 as Any? }.mapError { SourcePluginRuntime.PluginError.javascript($0) })
            }
        }
    }
    func json(_ script: String, arguments: [String: Any] = [:]) async throws -> String {
        guard let text = try await call(script, arguments: arguments) as? String else { throw SourcePluginRuntime.PluginError.invalidResult }
        guard text.utf8.count <= 8_000_000 else { throw SourcePluginRuntime.PluginError.oversizedResult }
        return text
    }
    func install(_ script: String) async throws {
        let began = Date()
        defer { timings["injection", default: 0] += Date().timeIntervalSince(began) }
        _ = try await call("""
        delete globalThis.ComicViewerSource;
        globalThis.__pluginEvents = [];
        if (!globalThis.__originalPluginConsole) {
            globalThis.__originalPluginConsole = {};
            for (const level of ['log','info','warn','error','debug']) {
                globalThis.__originalPluginConsole[level] = console[level].bind(console);
                console[level] = (...args) => {
                    if (globalThis.__pluginEvents.length < 100) globalThis.__pluginEvents.push(level + ': ' + args.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ').slice(0,2048));
                };
            }
        }
        \(script)
        return true;
        """)
    }
    func loadFixture(_ fixture: SourcePluginRuntime.Fixture) async throws {
        // Block external subresources. Fixture fetch is explicitly injected after loading the DOM.
        let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]
        """
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "comicviewer-fixture-block", encodedContentRuleList: rules) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? SourcePluginRuntime.PluginError.invalidResult) }
            }
        }
        webView.configuration.userContentController.add(list)
        try await loadHTML(fixture.html, baseURL: fixture.baseURL)
        _ = try await call("""
        const responses = JSON.parse(responseJSON);
        globalThis.__fixtureRequests = [];
        const cache = new Map();
        Object.defineProperty(globalThis, 'localStorage', { configurable:true, value: {
            getItem:key => cache.has(key) ? cache.get(key) : null,
            setItem:(key,value) => cache.set(String(key),String(value)),
            removeItem:key => cache.delete(key), clear:() => cache.clear(),
            key:index => Array.from(cache.keys())[index] || null,
            get length() { return cache.size; }
        }});
        globalThis.fetch = async (input, options) => {
            if (options?.signal?.aborted) throw new DOMException('Aborted','AbortError');
            const url = new URL(typeof input === 'string' ? input : input.url, document.baseURI).href;
            globalThis.__fixtureRequests.push(url);
            if (!Object.prototype.hasOwnProperty.call(responses,url)) throw new Error('Unmapped fixture request: ' + url);
            const entry = responses[url];
            const response = Array.isArray(entry) ? (entry.length > 1 ? entry.shift() : entry[0]) : entry;
            return new Response(response.body || '', {status:response.status || 200,headers:response.headers || {}});
        };
        globalThis.XMLHttpRequest = class { constructor() { throw new Error('XMLHttpRequest is unavailable in offline fixtures'); } };
        globalThis.WebSocket = class { constructor() { throw new Error('WebSocket is unavailable in offline fixtures'); } };
        return true;
        """, arguments: ["responseJSON": fixture.responsesJSON])
        fixtureLoaded = true
    }
    private func finish(_ completed: WKNavigation?, error: Error? = nil) {
        guard completed === navigation else { return }
        let callback = navigationCompletion; navigationCompletion = nil; navigation = nil
        callback?(error.map { .failure($0) } ?? .success(()))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode >= 400 {
            stop(SourcePluginRuntime.PluginError.httpStatus(response.statusCode))
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(navigation) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(navigation, error: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(navigation, error: error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { stop(SourcePluginRuntime.PluginError.terminated) }
}
