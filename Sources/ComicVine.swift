import Foundation

/// Fetches comic metadata from the ComicVine API (the de-facto standard used by Komga, Mylar, etc.)
/// for comics that don't embed a `ComicInfo.xml`. Requires a free API key (Settings → Metadata).
/// Volume-level search + details map onto `ComicInfo` so the result can be written back as a standard
/// `ComicInfo.xml` (folders) or a sidecar (archives), after which every tool reads it.
enum ComicVine {
    private static let base = "https://comicvine.gamespot.com/api"
    private static let userAgent = "ComicViewer/1.0 (macOS; comic metadata)"
    private static let apiKeyDefault = "comicvine.apikey"

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyDefault) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyDefault) }
    }
    static var hasKey: Bool { !apiKey.isEmpty }

    enum CVError: LocalizedError {
        case noKey, http(Int), api(String), decode
        var errorDescription: String? {
            switch self {
            case .noKey:        return "Add a ComicVine API key in Settings → Metadata."
            case .http(let c):  return "ComicVine returned HTTP \(c)."
            case .api(let m):   return "ComicVine: \(m)."
            case .decode:       return "Couldn't read the ComicVine response."
            }
        }
    }

    /// One volume (series) search result, for the picker.
    struct Volume: Identifiable, Hashable {
        let id: Int
        let name: String
        let year: String?
        let publisher: String?
        let issueCount: Int?
        let coverURL: URL?
        var subtitle: String {
            [year, publisher, issueCount.map { "\($0) issues" }].compactMap { $0 }.joined(separator: " · ")
        }
    }

    // MARK: - Requests

    /// Search series/volumes by title, best matches first.
    static func searchVolumes(_ query: String) async throws -> [Volume] {
        let items = [
            URLQueryItem(name: "resources", value: "volume"),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "field_list", value: "id,name,start_year,publisher,count_of_issues,image")
        ]
        let json = try await get("/search", items)
        let results = (json["results"] as? [[String: Any]]) ?? []
        return results.compactMap { r in
            guard let id = r["id"] as? Int, let name = r["name"] as? String else { return nil }
            let img = r["image"] as? [String: Any]
            let coverStr = (img?["small_url"] as? String) ?? (img?["thumb_url"] as? String)
            return Volume(
                id: id, name: name,
                year: (r["start_year"] as? String) ?? (r["start_year"] as? Int).map(String.init),
                publisher: (r["publisher"] as? [String: Any])?["name"] as? String,
                issueCount: r["count_of_issues"] as? Int,
                coverURL: coverStr.flatMap { URL(string: $0) })
        }
    }

    /// Full details for a volume, mapped to `ComicInfo` (series, year, publisher, creators,
    /// characters, summary). Creator **roles** live on issues (not volumes), so the volume's first
    /// issue is fetched for proper writer/artist credits.
    static func comicInfo(forVolume id: Int) async throws -> ComicInfo {
        let items = [URLQueryItem(name: "field_list",
                                  value: "name,start_year,publisher,description,deck,characters,count_of_issues,first_issue")]
        let json = try await get("/volume/4050-\(id)", items)
        guard let r = json["results"] as? [String: Any] else { throw CVError.decode }

        var info = ComicInfo()
        info.series = r["name"] as? String
        info.title = info.series
        info.year = (r["start_year"] as? String) ?? (r["start_year"] as? Int).map(String.init)
        info.publisher = (r["publisher"] as? [String: Any])?["name"] as? String
        info.count = r["count_of_issues"] as? Int
        let deck = (r["deck"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        info.summary = (deck?.isEmpty == false ? deck : nil) ?? stripHTML(r["description"] as? String ?? "")
        info.characters = ((r["characters"] as? [[String: Any]]) ?? [])
            .compactMap { $0["name"] as? String }.prefix(12).joined(separator: ", ").nonEmpty

        // Creator roles come from the first issue's person_credits.
        if let firstID = (r["first_issue"] as? [String: Any])?["id"] as? Int,
           let issue = try? await get("/issue/4000-\(firstID)", [URLQueryItem(name: "field_list", value: "person_credits")]),
           let ir = issue["results"] as? [String: Any] {
            let roles = mapCredits(ir["person_credits"] as? [[String: Any]] ?? [])
            func joined(_ k: String) -> String? { roles[k].map { dedup($0).joined(separator: ", ") }?.nonEmpty }
            info.writer = joined("writer")
            info.penciller = joined("penciller")
            info.inker = joined("inker")
            info.colorist = joined("colorist")
            info.letterer = joined("letterer")
            info.coverArtist = joined("cover")
            info.editor = joined("editor")
        }
        return info
    }

    /// Bucket ComicVine person credits (each `role` a comma-separated string) into ComicInfo roles.
    private static func mapCredits(_ people: [[String: Any]]) -> [String: [String]] {
        var roles: [String: [String]] = [:]
        for p in people {
            guard let name = p["name"] as? String else { continue }
            let role = (p["role"] as? String ?? "").lowercased()
            func add(_ key: String) { roles[key, default: []].append(name) }
            if role.contains("writer") || role.contains("script") { add("writer") }
            if role.contains("pencil") || role.contains("artist") || role.contains("breakdown") { add("penciller") }
            if role.contains("ink") { add("inker") }
            if role.contains("color") { add("colorist") }
            if role.contains("letter") { add("letterer") }
            if role.contains("cover") { add("cover") }
            if role.contains("editor") { add("editor") }
        }
        return roles
    }

    // MARK: - Core GET (throttled, keyed)

    private static var lastCall = Date.distantPast

    private static func get(_ path: String, _ items: [URLQueryItem]) async throws -> [String: Any] {
        guard hasKey else { throw CVError.noKey }
        // ComicVine allows ~1 req/sec — space requests out.
        let since = Date().timeIntervalSince(lastCall)
        if since < 1.1 { try? await Task.sleep(for: .seconds(1.1 - since)) }
        lastCall = Date()

        var comps = URLComponents(string: base + path)!
        comps.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json")
        ] + items
        var req = URLRequest(url: comps.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CVError.http(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CVError.decode }
        if let err = json["error"] as? String, err != "OK" { throw CVError.api(err) }
        return json
    }

    // MARK: - Helpers

    private static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>(); return xs.filter { seen.insert($0).inserted }
    }

    /// Strip ComicVine's HTML description to readable plain text.
    private static func stripHTML(_ html: String) -> String? {
        guard !html.isEmpty else { return nil }
        var s = html
        s = s.replacingOccurrences(of: "(?i)</p>|<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                        "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
