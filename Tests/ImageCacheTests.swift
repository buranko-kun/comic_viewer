import XCTest
import CoreGraphics
import ImageIO

@testable import ComicViewer

final class ImageCacheTests: XCTestCase {
    func testCacheEvictsOldestImagesToStayWithinByteBudget() async throws {
        let firstURL = try makeImage(named: "first", width: 64, height: 64)
        let secondURL = try makeImage(named: "second", width: 64, height: 64)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        guard let first = ImageLoader.decodeDisplay(firstURL, maxPixel: 64) else {
            return XCTFail("Could not decode first test image")
        }
        let firstCost = ImageCache.estimatedCost(of: first)
        let cache = ImageCache(maxBytes: firstCost)

        XCTAssertNotNil(await cache.image(for: firstURL, maxPixel: 64))
        XCTAssertEqual(await cache.imageCount, 1)
        XCTAssertEqual(await cache.estimatedMemoryBytes, firstCost)

        XCTAssertNotNil(await cache.image(for: secondURL, maxPixel: 64))

        XCTAssertEqual(await cache.imageCount, 1)
        XCTAssertEqual(await cache.estimatedMemoryBytes, firstCost)
    }

    func testOversizeImageIsKeptAsTheOnlyCachedImage() async throws {
        let url = try makeImage(named: "oversize", width: 128, height: 128)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let decoded = ImageLoader.decodeDisplay(url, maxPixel: 128) else {
            return XCTFail("Could not decode test image")
        }
        let cost = ImageCache.estimatedCost(of: decoded)
        let cache = ImageCache(maxBytes: max(1, cost / 4))

        XCTAssertNotNil(await cache.image(for: url, maxPixel: 128))
        XCTAssertEqual(await cache.imageCount, 1)
        XCTAssertEqual(await cache.estimatedMemoryBytes, cost)
    }

    private func makeImage(named name: String, width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicViewerImageCache-(UUID().uuidString)-(name).png")

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "ImageCacheTests", code: 1)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ImageCacheTests", code: 2)
        }
        return url
    }
}
