import SwiftUI

/// Displays an image fit-to-window, always in landscape. If the image is portrait,
/// the VIEW is rotated 90° clockwise (a pure GPU transform); the bitmap is untouched.
///
/// The crux is the frame-swap: `.rotationEffect` rotates the rendered view but keeps
/// the pre-rotation layout footprint, so a portrait image is given the *swapped*
/// frame (Lh × Lw) which, once rotated 90°, occupies exactly the intended on-screen
/// landscape rect (Lw × Lh) with correct aspect and no distortion.
struct RotatingImageView: View {
    let image: DisplayImage
    /// Whether to rotate a portrait page 90° to fill the landscape screen. When false, the
    /// page is shown upright (fit as-is) — right for genuine portrait comics.
    var rotate: Bool = true

    var body: some View {
        GeometryReader { geo in
            let c = geo.size
            let iw = CGFloat(image.cgImage.width)
            let ih = CGFloat(image.cgImage.height)
            // Only portrait pages are rotated, and only when rotation is enabled.
            let spin = rotate && image.isPortrait

            // The on-screen aspect (width/height): rotated portrait becomes landscape.
            let onScreenAspect = spin ? (ih / iw) : (iw / ih)
            let rect = Self.fit(aspect: onScreenAspect, in: c)
            // Pre-rotation footprint: a rotated page swaps width/height.
            let fw = spin ? rect.height : rect.width
            let fh = spin ? rect.width : rect.height

            Image(decorative: image.cgImage, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.high)
                .frame(width: fw, height: fh)
                .rotationEffect(spin ? .degrees(90) : .zero)  // +90 = clockwise
                .frame(width: c.width, height: c.height)       // center in window
        }
    }

    /// Largest rect of the given width/height `aspect` that fits inside `c`.
    static func fit(aspect: CGFloat, in c: CGSize) -> CGSize {
        guard aspect > 0, c.width > 0, c.height > 0 else { return .zero }
        let containerAspect = c.width / c.height
        if aspect >= containerAspect {           // width-limited
            return CGSize(width: c.width, height: c.width / aspect)
        } else {                                  // height-limited
            return CGSize(width: c.height * aspect, height: c.height)
        }
    }
}
