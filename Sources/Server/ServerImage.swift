import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import CoreImage

/// Image helpers for the server: downsized JPEG bytes for page/cover responses (mirrors the
/// encoder in `ThumbnailCache.writeJPEG`, but returns `Data`), and a QR code for the Settings
/// pairing panel.
enum ServerImage {
    /// Downsized, EXIF-upright JPEG data for an image file, or nil if it can't be decoded.
    static func jpegData(from url: URL, maxPixel: Int) -> Data? {
        guard let cg = ImageLoader.decodeDisplay(url, maxPixel: maxPixel)?.cgImage else { return nil }
        return jpeg(cg)
    }

    static func jpeg(_ cg: CGImage, quality: CGFloat = 0.85) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// A QR code image encoding `string`, for showing a scannable connection link in Settings.
    static func qrImage(from string: String, size: CGFloat = 180) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
