import XCTest
import CoreGraphics
import ImageIO
@testable import ComicViewer

/// Safety net for the archive layer — the code that streams pages out of comics and, crucially,
/// **rewrites comic files on disk** (`normalizeToZip`). These tests build throwaway archives in a
/// temp dir (never touching a real library) and assert the lossless / on-demand guarantees hold.
///
/// The archive tools (`7zz`/`unar`) are required; tests skip cleanly on a machine without them.
final class ArchiveTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(ArchiveExtractor.sevenz == nil, "7zz not available on this machine")
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: - normalizeToZip (destructive — the most important to cover)

    func testNormalizeConvertsNonZipToZipLosslessly() throws {
        let src = tmp.appendingPathComponent("src")
        let names = ["001.jpg", "002.jpg", "003.jpg"]
        let original = try writePages(src, names: names)
        try "<ComicInfo/>".write(to: src.appendingPathComponent("ComicInfo.xml"),
                                 atomically: true, encoding: .utf8)
        // A .cbz whose *contents* are 7z (like the RAR-in-.cbz files in the wild). 7z is used
        // because `7zz` can create it; the conversion path (any non-zip → zip) is identical.
        let archive = tmp.appendingPathComponent("comic.cbz")
        makeArchive(from: src, out: archive, type: "7z")
        XCTAssertEqual(ArchiveExtractor.list(archive)?.type.lowercased(), "7z")

        XCTAssertTrue(ArchiveExtractor.normalizeToZip(archive))

        let listing = try XCTUnwrap(ArchiveExtractor.list(archive))
        XCTAssertEqual(listing.type.lowercased(), "zip", "file is now a ZIP")
        let imageBasenames = Set(listing.entries
            .filter { $0.lowercased().hasSuffix(".jpg") }
            .map { ($0 as NSString).lastPathComponent })
        XCTAssertEqual(imageBasenames, Set(names), "every page survived, none added")
        XCTAssertTrue(listing.entries.contains { $0.lowercased().hasSuffix("comicinfo.xml") },
                      "ComicInfo.xml preserved")

        // Lossless: every page's bytes are byte-for-byte identical to the originals.
        let out = tmp.appendingPathComponent("verify")
        XCTAssertTrue(ArchiveExtractor.extractAllInto(archive, dir: out))
        for n in names {
            let data = try Data(contentsOf: out.appendingPathComponent(n))
            XCTAssertEqual(data, original[n], "page \(n) bytes unchanged by repackaging")
        }
    }

    func testNormalizeLeavesAnAlreadyZipFileUntouched() throws {
        let src = tmp.appendingPathComponent("src")
        _ = try writePages(src, names: ["a.jpg", "b.jpg"])
        let archive = tmp.appendingPathComponent("z.cbz")
        makeArchive(from: src, out: archive, type: "zip")
        let before = try Data(contentsOf: archive)

        XCTAssertTrue(ArchiveExtractor.normalizeToZip(archive), "no-op still reports success")

        XCTAssertEqual(try Data(contentsOf: archive), before,
                       "an already-ZIP file is not rewritten")
    }

    func testNormalizeFailsSafelyAndLeavesOriginalIntact() throws {
        let archive = tmp.appendingPathComponent("bad.cbz")
        let garbage = Data("this is not an archive".utf8)
        try garbage.write(to: archive)

        XCTAssertFalse(ArchiveExtractor.normalizeToZip(archive), "unreadable archive → failure")

        XCTAssertEqual(try Data(contentsOf: archive), garbage,
                       "the original file must survive a failed conversion")
    }

    // MARK: - listing / ordering / selective extraction

    func testListPagesSortNaturally() throws {
        let src = tmp.appendingPathComponent("src")
        // Deliberately out of lexical order: p10 must land after p2, not after p1.
        _ = try writePages(src, names: ["p1.jpg", "p2.jpg", "p10.jpg", "p11.jpg", "p20.jpg"])
        let archive = tmp.appendingPathComponent("order.cbz")
        makeArchive(from: src, out: archive, type: "zip")

        let ordered = try XCTUnwrap(ArchiveExtractor.list(archive)).entries
            .filter { $0.lowercased().hasSuffix(".jpg") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        XCTAssertEqual(ordered, ["p1.jpg", "p2.jpg", "p10.jpg", "p11.jpg", "p20.jpg"])
    }

    func testExtractEntriesPullsOnlyRequestedPages() throws {
        let src = tmp.appendingPathComponent("src")
        let original = try writePages(src, names: ["001.jpg", "002.jpg", "003.jpg"])
        let archive = tmp.appendingPathComponent("e.cbz")
        makeArchive(from: src, out: archive, type: "zip")
        let dest = tmp.appendingPathComponent("dest")

        XCTAssertTrue(ArchiveExtractor.extractEntries(archive, ["002.jpg"], into: dest))

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("002.jpg").path))
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("001.jpg").path),
                       "unrequested pages are not extracted")
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("002.jpg")),
                       original["002.jpg"])
    }

    // MARK: - Performance baselines

    func testMeasureArchiveListingPerformance() throws {
        let src = tmp.appendingPathComponent("benchmark-list-src")
        _ = try writeBenchmarkPages(src, count: 128)

        let archive = tmp.appendingPathComponent("benchmark-list.cbz")
        makeArchive(from: src, out: archive, type: "zip")

        measure(metrics: [XCTClockMetric()]) {
            _ = ArchiveExtractor.list(archive)
        }
    }

    func testMeasureSelectiveExtractionPerformance() throws {
        let src = tmp.appendingPathComponent("benchmark-extract-src")
        _ = try writeBenchmarkPages(src, count: 128)

        let archive = tmp.appendingPathComponent("benchmark-extract.cbz")
        makeArchive(from: src, out: archive, type: "zip")
        let entries = (1...8).map { String(format: "%03d.jpg", $0) }

        measure(metrics: [XCTClockMetric()]) {
            let dest = tmp.appendingPathComponent("measure-\(UUID().uuidString)")
            _ = ArchiveExtractor.extractEntries(
                archive,
                entries,
                into: dest
            )
            try? FileManager.default.removeItem(at: dest)
        }
    }

    // MARK: - ArchiveStreamer (on-demand page extraction)

    func testStreamerEnsureExtractsPageOnDemand() async throws {
        let src = tmp.appendingPathComponent("src")
        let original = try writePages(src, names: ["001.jpg", "002.jpg"])
        let archive = tmp.appendingPathComponent("s.cbz")
        makeArchive(from: src, out: archive, type: "zip")

        let dir = tmp.appendingPathComponent("stream")
        let pages = ["001.jpg", "002.jpg"].map { (url: dir.appendingPathComponent($0), entry: $0) }
        let streamer = ArchiveStreamer(archive: archive, dir: dir, pages: pages)

        let target = pages[1].url
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "not extracted yet")

        let ok = await streamer.ensure(target)
        XCTAssertTrue(ok)
        XCTAssertEqual(try Data(contentsOf: target), original["002.jpg"],
                       "the requested page is extracted with correct bytes")

        // A second call is a cheap no-op success (already on disk).
        let again = await streamer.ensure(target)
        XCTAssertTrue(again)
    }

    func testRefreshReplacesCachedAndPreservedCoversAfterFirstPageRemoval() async throws {
        let src = tmp.appendingPathComponent("cover-src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try writeCover(src.appendingPathComponent("001.png"), red: 1, blue: 0)
        try writeCover(src.appendingPathComponent("002.png"), red: 0, blue: 1)
        let archive = tmp.appendingPathComponent("cover.cbz")
        let cache = tmp.appendingPathComponent("covers")
        makeArchive(from: src, out: archive, type: "zip")
        let oldCover = try XCTUnwrap(ArchiveCover.makeSync(for: archive, cacheDirectory: cache))
        let oldBytes = try Data(contentsOf: oldCover)
        let preserved = await ArchiveCover.preserveThumbnail(for: archive, cacheDirectory: cache)
        XCTAssertTrue(preserved)
        let preservedURL = try XCTUnwrap(ArchiveCover.makeSync(for: archive, cacheDirectory: cache))
        let preservedBytes = try Data(contentsOf: preservedURL)

        try FileManager.default.removeItem(at: src.appendingPathComponent("001.png"))
        try FileManager.default.removeItem(at: archive)
        makeArchive(from: src, out: archive, type: "zip")
        let archiveBytes = try Data(contentsOf: archive)
        // Normal viewing keeps the saved cover; only an explicit reset replaces it.
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(ArchiveCover.makeSync(for: archive, cacheDirectory: cache))), preservedBytes)
        let refreshed = try XCTUnwrap(ArchiveCover.refreshSync(for: archive, cacheDirectory: cache))
        XCTAssertEqual(refreshed, preservedURL)
        XCTAssertNotEqual(try Data(contentsOf: refreshed), preservedBytes)
        XCTAssertNotEqual(try Data(contentsOf: oldCover), oldBytes)
        XCTAssertEqual(try Data(contentsOf: oldCover), try Data(contentsOf: src.appendingPathComponent("002.png")))
        XCTAssertEqual(try Data(contentsOf: archive), archiveBytes, "refresh never rewrites the comic")
    }

    func testFailedRefreshKeepsSavedCover() throws {
        let src = tmp.appendingPathComponent("cover-src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try writeCover(src.appendingPathComponent("001.png"), red: 1, blue: 0)
        let archive = tmp.appendingPathComponent("cover.cbz")
        let cache = tmp.appendingPathComponent("covers")
        makeArchive(from: src, out: archive, type: "zip")
        let cover = try XCTUnwrap(ArchiveCover.makeSync(for: archive, cacheDirectory: cache))
        let saved = try Data(contentsOf: cover)
        try Data("not an archive".utf8).write(to: archive)
        XCTAssertNil(ArchiveCover.refreshSync(for: archive, cacheDirectory: cache))
        XCTAssertEqual(try Data(contentsOf: cover), saved)
        XCTAssertEqual(ArchiveCover.makeSync(for: archive, cacheDirectory: cache), cover)
    }

    func testThumbnailInvalidationClearsMemoryAndDiskAfterCoverReplacement() async throws {
        let image = tmp.appendingPathComponent("cover.png")
        let disk = tmp.appendingPathComponent("thumbs")
        let cache = ThumbnailCache(cacheDirectory: disk)
        try writeCover(image, red: 1, blue: 0)
        let firstResult = await cache.thumbnail(for: image, maxPixel: 100)
        let first = try XCTUnwrap(firstResult)
        let diskFiles = try FileManager.default.contentsOfDirectory(at: disk, includingPropertiesForKeys: nil)
        XCTAssertEqual(diskFiles.count, 1)
        try writeCover(image, red: 0, blue: 1)
        await cache.invalidate(image)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: disk, includingPropertiesForKeys: nil).isEmpty)
        let nextResult = await cache.thumbnail(for: image, maxPixel: 100)
        let next = try XCTUnwrap(nextResult)
        XCTAssertNotEqual(first.dataProvider?.data as Data?, next.dataProvider?.data as Data?)
    }

    private func writeCover(_ url: URL, red: CGFloat, blue: CGFloat) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = try XCTUnwrap(context.makeImage())
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
    }

    // MARK: - helpers

    /// Write `names` into `dir` as files of unique random bytes; return name → bytes for comparison.
    private func writePages(_ dir: URL, names: [String]) throws -> [String: Data] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var bytes: [String: Data] = [:]
        for n in names {
            let data = Data((0..<128).map { _ in UInt8.random(in: 0...255) })
            try data.write(to: dir.appendingPathComponent(n))
            bytes[n] = data
        }
        return bytes
    }

    private func writeBenchmarkPages(_ dir: URL, count: Int) throws -> [String: Data] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var bytes: [String: Data] = [:]
        let payload = Data(repeating: 0x41, count: 4096)
        for n in 1...count {
            let name = String(format: "%03d.jpg", n)
            try payload.write(to: dir.appendingPathComponent(name))
            bytes[name] = payload
        }
        return bytes
    }

    /// Archive `dir`'s contents (relative paths preserved) into `out` as `type` (e.g. "zip", "7z").
    private func makeArchive(from dir: URL, out: URL, type: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ArchiveExtractor.sevenz!)
        p.arguments = ["a", "-t\(type)", "--", out.path, "."]
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "creating \(type) archive")
    }
}
