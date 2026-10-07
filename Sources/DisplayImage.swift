import CoreGraphics
import Foundation

/// A decoded, EXIF-upright image ready to display. `cgImage` is already rotated to
/// its visual orientation (decoded with kCGImageSourceCreateThumbnailWithTransform),
/// so `isPortrait` is simply height > width of that bitmap.
struct DisplayImage: Identifiable {
    let id = UUID()
    let cgImage: CGImage
    let isPortrait: Bool
    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
}
