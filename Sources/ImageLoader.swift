import ImageIO
import CoreGraphics
import Foundation

/// Lightweight metadata read without decoding pixels.
struct ImageInfo {
    let pixelWidth: Int
    let pixelHeight: Int
    let exif: Int
    var isPortrait: Bool {
        Orientation.isPortrait(pixelWidth: pixelWidth, pixelHeight: pixelHeight, exif: exif)
    }
}

/// ImageIO-backed loading. No manual decoding: CGImageSource reads properties and
/// produces an EXIF-upright, downsampled CGImage sized to the display.
enum ImageLoader {
    /// Read pixel dimensions + EXIF orientation cheaply (no full decode).
    static func probe(_ url: URL) -> ImageInfo? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let o = props[kCGImagePropertyOrientation] as? Int ?? 1
        guard w > 0, h > 0 else { return nil }
        return ImageInfo(pixelWidth: w, pixelHeight: h, exif: o)
    }

    /// Decode an EXIF-upright, downsampled CGImage whose long edge is ~`maxPixel`.
    /// `WithTransform: true` applies the EXIF orientation, so the returned bitmap is
    /// visually upright and `height > width` directly means portrait.
    static func decodeDisplay(_ url: URL, maxPixel: Int) -> DisplayImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decodeDisplay(source: src, maxPixel: maxPixel)
    }

    /// Same as above but from in-memory bytes — used for streamed remote pages (no file on disk).
    static func decodeDisplay(data: Data, maxPixel: Int) -> DisplayImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decodeDisplay(source: src, maxPixel: maxPixel)
    }

    private static func decodeDisplay(source src: CGImageSource, maxPixel: Int) -> DisplayImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard var cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        // ImageIO's thumbnail scaling honors the image's *physical* size, so a file with a
        // non-square DPI density (some re-encoded "SD" comic scans store DPI == pixel
        // dimensions, i.e. "1 inch × 1 inch") comes back distorted — squished toward a
        // square — which also flips the portrait/landscape verdict. Compare the thumbnail's
        // aspect to the true pixel aspect and, when they disagree, rebuild at the right one.
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let pw = props[kCGImagePropertyPixelWidth] as? Int,
           let ph = props[kCGImagePropertyPixelHeight] as? Int, pw > 0, ph > 0 {
            let exif = props[kCGImagePropertyOrientation] as? Int ?? 1
            let v = Orientation.visualSize(pixelWidth: pw, pixelHeight: ph, exif: exif)
            let want = CGFloat(v.width) / CGFloat(v.height)
            let got = CGFloat(cg.width) / CGFloat(cg.height)
            if abs(want - got) / want > 0.01, let fixed = correctingAspect(cg, to: want) {
                cg = fixed
            }
        }
        return DisplayImage(cgImage: cg, isPortrait: cg.height > cg.width)
    }

    /// Redraw a distorted thumbnail at the correct display aspect. The thumbnail is an
    /// anisotropically scaled copy of the page, so drawing it into a right-aspect rect
    /// restores true proportions. The long edge is preserved (never upscaled past `maxPixel`)
    /// and the short edge is derived from `aspect` (width / height).
    private static func correctingAspect(_ cg: CGImage, to aspect: CGFloat) -> CGImage? {
        let long = max(cg.width, cg.height)
        let (w, h): (Int, Int) = aspect >= 1
            ? (long, Int((CGFloat(long) / aspect).rounded()))
            : (Int((CGFloat(long) * aspect).rounded()), long)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
