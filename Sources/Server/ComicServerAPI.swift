import Foundation
import Swifter

/// A comic resolved from an id, safe to pass to the off-main server threads.
private struct ResolvedComic {
    let path: String
    let isArchive: Bool
}

/// Registers the LAN HTTP API on a Swifter server. Handlers run off the main actor, so anything
/// touching main-actor state (LibraryModel, CollectionStore) is fetched via `onMainSync`; image
/// decoding and archive extraction run directly on the server thread (those APIs are nonisolated).
enum ComicServerAPI {
    static func register(on s: HttpServer) {
        s["/api/ping"] = { _ in
            jsonResponse(["name": ComicServer.appName, "version": ComicServer.version])
        }

        s.POST["/api/pair"] = { req in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(req.body)) as? [String: Any],
                  let code = obj["code"] as? String else {
                return .raw(400, "Bad Request", nil, nil)
            }
            guard let token = onMainSync({
                ComicServer.shared.issueSessionToken(
                    for: code.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }) else {
                return .raw(401, "Unauthorized", nil, nil)
            }
            return jsonResponse([
                "token": token,
                "name": ComicServer.appName,
                "version": ComicServer.version
            ])
        }

        s["/api/library"] = { req in
            let dir = req.queryParams.first { $0.0 == "dir" }?.1
            guard let json = onMainSync({ libraryJSON(dirToken: dir) }) else { return .raw(404, "Not Found", nil, nil) }
            return jsonResponse(json)
        }

        s["/api/comic/:id/pages"] = { req in
            guard let id = req.params[":id"], let rc = resolve(id) else { return .raw(404, "Not Found", nil, nil) }
            let count = PageIndex.shared.pageCount(forComicPath: rc.path, isArchive: rc.isArchive)
            var json: [String: Any] = ["count": count]
            // Read the resume position straight from the state file (immediate; no rescan needed).
            if let st = CentralStore.loadState(forKey: CentralStore.key(for: URL(fileURLWithPath: rc.path))),
               let i = st.lastIndex, let c = st.pageCount {
                json["progress"] = ["index": i, "count": c]
            }
            return jsonResponse(json)
        }

        s["/api/comic/:id/page/:n"] = { req in
            guard let id = req.params[":id"], let ns = req.params[":n"], let n = Int(ns),
                  let rc = resolve(id) else { return .raw(404, "Not Found", nil, nil) }
            let w = Int(req.queryParams.first { $0.0 == "w" }?.1 ?? "") ?? 1600
            let maxPixel = max(200, min(w, 4000))
            // Streams just this page out of the archive (extract-on-demand), not the whole book.
            guard let file = PageIndex.shared.pageFile(forComicPath: rc.path, isArchive: rc.isArchive, index: n),
                  let data = ServerImage.jpegData(from: file, maxPixel: maxPixel)
            else { return .raw(404, "Not Found", nil, nil) }
            return .ok(.data(data, contentType: "image/jpeg"))
        }

        s["/api/comic/:id/thumb"] = { req in
            guard let id = req.params[":id"], let rc = resolve(id) else { return .raw(404, "Not Found", nil, nil) }
            guard let cu = PageIndex.shared.coverFile(forComicPath: rc.path, isArchive: rc.isArchive),
                  let data = ServerImage.jpegData(from: cu, maxPixel: 600)
            else { return .raw(404, "Not Found", nil, nil) }
            return .ok(.data(data, contentType: "image/jpeg"))
        }

        s["/api/collections"] = { _ in jsonResponse(onMainSync { collectionsJSON() }) }

        s.POST["/api/comic/:id/progress"] = { req in
            guard let id = req.params[":id"], let rc = resolve(id) else { return .raw(404, "Not Found", nil, nil) }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(req.body)) as? [String: Any],
                  let index = obj["index"] as? Int else { return .raw(400, "Bad Request", nil, nil) }
            let pages = PageIndex.shared.pages(forComicPath: rc.path, isArchive: rc.isArchive)
            guard pages.indices.contains(index) else { return .raw(400, "Bad Request", nil, nil) }
            // `pages` here are entry URLs (no extraction) — just their filenames for the resume key.
            ServerProgress.save(comicPath: rc.path, index: index, count: pages.count,
                                lastPage: pages[index].lastPathComponent)
            onMainSync { LibraryModel.shared.rescan() }
            return jsonResponse(["ok": true])
        }
    }

    // MARK: - Main-actor data snapshots

    /// Library level as JSON, mirroring `LibraryModel.entries(at:)`. `dirToken` must resolve to a
    /// folder under a scanned root (else nil → 404), preventing arbitrary directory listing.
    @MainActor private static func libraryJSON(dirToken: String?) -> [String: Any]? {
        let library = LibraryModel.shared
        var dir: URL?
        if let token = dirToken, let path = decodePath(token) {
            let u = URL(fileURLWithPath: path).standardizedFileURL
            guard library.folders.contains(where: { u.path.hasPrefix($0.standardizedFileURL.path) })
            else { return nil }
            dir = u
        }
        let entries = library.entries(at: dir)
        let groups = entries.groups.map { g -> [String: Any] in
            ["id": encodePath(g.url.path), "name": g.name, "count": g.count]
        }
        let comics = entries.comics.map { c -> [String: Any] in
            var d: [String: Any] = ["id": encodePath(c.url.path), "title": c.title,
                                    "isArchive": c.isArchive, "pageCount": c.pageCount]
            if let p = c.progress { d["progress"] = ["index": p.page - 1, "count": p.count] }
            return d
        }
        return ["groups": groups, "comics": comics]
    }

    @MainActor private static func collectionsJSON() -> [String: Any] {
        let cols = CollectionStore.shared.collections.map { col -> [String: Any] in
            let items = col.items.map { item -> [String: Any] in
                var d: [String: Any] = ["id": item.id, "title": item.title, "kind": item.kind.rawValue]
                if let c = item.cover { d["cover"] = c }
                if item.mustRead { d["mustRead"] = true }
                // Library items are addressable by the same encoded path as /api/library.
                if item.kind == .library, let p = item.path { d["comicId"] = encodePath(p) }
                return d
            }
            return ["id": col.id, "name": col.name, "items": items]
        }
        return ["collections": cols]
    }

    /// Validate an id against the real library (on main) and return an off-main snapshot.
    private static func resolve(_ id: String) -> ResolvedComic? {
        guard let path = decodePath(id) else { return nil }
        return onMainSync {
            guard let c = LibraryModel.shared.comics.first(where: { $0.url.path == path }) else { return nil }
            return ResolvedComic(path: c.url.path, isArchive: c.isArchive)
        }
    }
}

// MARK: - Helpers

/// Run a main-actor closure synchronously from a server (background) thread.
func onMainSync<T>(_ work: @MainActor () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated(work) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
}

func jsonResponse(_ obj: [String: Any]) -> HttpResponse {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return .raw(500, "Error", nil, nil) }
    return .ok(.data(data, contentType: "application/json"))
}

/// base64url encode/decode of a filesystem path used as a comic/folder id.
func encodePath(_ path: String) -> String {
    Data(path.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func decodePath(_ token: String) -> String? {
    var b64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let data = Data(base64Encoded: b64), let s = String(data: data, encoding: .utf8) else { return nil }
    return s
}

/// Persists a reading position from the client into the same `ComicState` the app uses.
enum ServerProgress {
    static func save(comicPath: String, index: Int, count: Int, lastPage: String) {
        let key = CentralStore.key(for: URL(fileURLWithPath: comicPath))
        var state = CentralStore.loadState(forKey: key) ?? ComicState()
        state.lastPage = lastPage
        state.lastIndex = index
        state.pageCount = count
        state.path = key
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: CentralStore.stateURL(for: key), options: .atomic)
        }
    }
}
