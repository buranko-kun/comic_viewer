import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Headless test hook: `ComicViewer --snapshot <input> <output.png> [W H]`
/// decodes the image, renders the real `RotatingImageView` into a fixed container
/// via ImageRenderer, writes a PNG, and exits. Lets the rotation/fit be verified
/// deterministically without an on-screen window or screen-recording permission.
enum SnapshotMode {
    @MainActor
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count else { return }
        let input = URL(fileURLWithPath: args[i + 1])
        let output = URL(fileURLWithPath: args[i + 2])
        let w = (i + 3 < args.count ? Double(args[i + 3]) : nil) ?? 1200
        let h = (i + 4 < args.count ? Double(args[i + 4]) : nil) ?? 800

        guard let img = ImageLoader.decodeDisplay(input, maxPixel: 2400) else {
            fail("decode failed for \(input.path)")
        }
        let view = ZStack {
            Color.black
            RotatingImageView(image: img)
        }
        .frame(width: w, height: h)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { fail("ImageRenderer produced no image") }
        guard let dst = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fail("could not create PNG destination")
        }
        CGImageDestinationAddImage(dst, cg, nil)
        guard CGImageDestinationFinalize(dst) else { fail("PNG write failed") }
        let kind = img.isPortrait ? "portrait→rotated" : "landscape"
        let msg = "snapshot ok: \(kind) \(img.cgImage.width)x\(img.cgImage.height)"
            + " -> \(output.lastPathComponent)\n"
        FileHandle.standardError.write(Data(msg.utf8))
        exit(0)
    }

    private static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write("snapshot: \(msg)\n".data(using: .utf8)!)
        exit(2)
    }
}
