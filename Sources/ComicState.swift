import Foundation

/// Per-comic saved state, stored centrally in the app's Application Support directory as
/// `state/<sha256(path)>.json` (see `CentralStore`). Chapters are stored by file name
/// (survive reordering). `lastPage` powers resume-reading.
///
/// This also transparently reads the older in-folder `.comicviewer.json` /
/// `.landscape-chapters.json` sidecars (migrated to the central store on first load).
struct ComicState: Codable {
    var version: Int = 2
    var chapters: [String] = []
    /// Optional user-given names for manual chapters, keyed by the same page key as `chapters`
    /// (a chapter with no entry falls back to its ComicInfo bookmark name, else "Chapter N").
    /// Additive/optional so older state files still decode.
    var chapterNames: [String: String] = [:]
    var lastPage: String?
    /// Resume position as an index + total, so progress is known without re-scanning (needed for
    /// archives, whose pages aren't listed at library-scan time). Optional for older states.
    var lastIndex: Int?
    var pageCount: Int?
    /// Manual "read in rotated orientation" override, for comics whose pages were baked
    /// to landscape (so the HUD/grid rotate to match even though the files aren't portrait).
    /// Optional so older sidecars without the key still decode.
    var manualRotate: Bool?
    /// The comic's canonical path — since the central filename is a hash, this keeps the
    /// file human-readable and lets tools map a state file back to its comic. Optional so
    /// older sidecars without the key still decode.
    var path: String?
    var lastReadAt: Date?
}

extension ComicState {
    private enum CodingKeys: String, CodingKey {
        case version, chapters, chapterNames, lastPage, lastIndex, pageCount, manualRotate, path, lastReadAt
    }

    /// **Tolerant decoding**: every field falls back to its default when the key is absent. Swift's
    /// synthesized decoder throws on a missing non-optional key (it ignores default values), so
    /// adding a new field like `chapterNames` would otherwise make *older* state files fail to
    /// decode — which silently wipes chapters/progress on the next save. This guards against that
    /// for any field added now or later.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? version
        chapters = try c.decodeIfPresent([String].self, forKey: .chapters) ?? chapters
        chapterNames = try c.decodeIfPresent([String: String].self, forKey: .chapterNames) ?? chapterNames
        lastPage = try c.decodeIfPresent(String.self, forKey: .lastPage)
        lastIndex = try c.decodeIfPresent(Int.self, forKey: .lastIndex)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
        manualRotate = try c.decodeIfPresent(Bool.self, forKey: .manualRotate)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        lastReadAt = try c.decodeIfPresent(Date.self, forKey: .lastReadAt)
    }
}
