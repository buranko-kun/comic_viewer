import CoreGraphics

/// EXIF orientation handling. The value comes from `kCGImagePropertyOrientation`
/// (1...8). Values 5–8 carry a 90°/270° rotation, so the *visual* (display-upright)
/// dimensions are the raw pixel dimensions swapped. This is why a file whose pixels
/// are landscape can still be a portrait photo (e.g. orientation 6/8).
enum Orientation {
    /// Visual size once the image is displayed upright (EXIF applied).
    static func visualSize(pixelWidth w: Int, pixelHeight h: Int, exif: Int) -> (width: Int, height: Int) {
        switch exif {
        case 5, 6, 7, 8:
            return (h, w)          // 90°/270° → swap
        default:
            return (w, h)          // 1–4 (and anything unexpected) → unchanged
        }
    }

    /// True if the image is taller than wide *after* EXIF orientation.
    static func isPortrait(pixelWidth w: Int, pixelHeight h: Int, exif: Int) -> Bool {
        let v = visualSize(pixelWidth: w, pixelHeight: h, exif: exif)
        return v.height > v.width
    }
}
