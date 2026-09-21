import Foundation

/// Talks to the desktop comic server's HTTP API. JSON GETs send the pairing code as a header;
/// image URLs carry it as a query param (so they can be used directly by `AsyncImage`).
struct ServerClient {
    let baseURL: URL
    let code: String

    enum ClientError: Error { case badResponse, unauthorized }

    // MARK: JSON

    func ping() async -> AppInfo? {
        try? await get(AppInfo.self, path: "/api/ping", authed: false)
    }

    func library(dir: String?) async throws -> LibraryLevel {
        var items: [URLQueryItem] = []
        if let dir { items.append(URLQueryItem(name: "dir", value: dir)) }
        return try await get(LibraryLevel.self, path: "/api/library", query: items)
    }

    func pages(comicId: String) async throws -> PagesInfo {
        try await get(PagesInfo.self, path: "/api/comic/\(comicId)/pages")
    }

    func collections() async throws -> [ServerCollection] {
        try await get(CollectionsResponse.self, path: "/api/collections").collections
    }

    func postProgress(comicId: String, index: Int, count: Int) async {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return }
        comps.path = "/api/comic/\(comicId)/progress"
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(code, forHTTPHeaderField: "X-Comic-Auth")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["index": index, "count": count])
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: Image URLs (consumed by AsyncImage)

    func pageURL(comicId: String, index: Int, width: Int) -> URL {
        imageURL(path: "/api/comic/\(comicId)/page/\(index)", extra: [URLQueryItem(name: "w", value: String(width))])
    }

    func thumbURL(comicId: String) -> URL {
        imageURL(path: "/api/comic/\(comicId)/thumb")
    }

    private func imageURL(path: String, extra: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.path = path
        comps.queryItems = [URLQueryItem(name: "code", value: code)] + extra
        return comps.url!
    }

    // MARK: Core GET

    private func get<T: Decodable>(_ type: T.Type, path: String,
                                   query: [URLQueryItem] = [], authed: Bool = true) async throws -> T {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.path = path
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw ClientError.badResponse }
        var req = URLRequest(url: url)
        if authed { req.setValue(code, forHTTPHeaderField: "X-Comic-Auth") }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw ClientError.unauthorized }
            guard (200...299).contains(http.statusCode) else { throw ClientError.badResponse }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
