import Foundation

/// Codable mirrors of the desktop server's JSON API (see `ComicServerAPI` on the Mac side).

struct AppInfo: Codable { let name: String; let version: String }

struct LibraryLevel: Codable {
    let groups: [GroupSummary]
    let comics: [ComicSummary]
}

struct GroupSummary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
}

struct ComicSummary: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let isArchive: Bool
    let pageCount: Int
    let progress: Progress?
}

struct Progress: Codable, Hashable {
    let index: Int
    let count: Int
}

struct PagesInfo: Codable {
    let count: Int
    let progress: Progress?
}

struct CollectionsResponse: Codable { let collections: [ServerCollection] }

struct ServerCollection: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let items: [CollectionEntry]
}

struct CollectionEntry: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let kind: String          // "online" | "library"
    let cover: String?
    let comicId: String?      // set for library items → openable/readable
    let mustRead: Bool?
}

/// Response returned by the desktop when the human pairing code is accepted.
struct PairingResponse: Codable {
    let token: String
    let name: String
    let version: String
}
