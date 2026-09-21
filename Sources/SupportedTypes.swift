import Foundation
import UniformTypeIdentifiers

/// Single source of truth for the formats the app handles (v1: JPEG + PNG).
/// Adding HEIC/TIFF/WebP later is a one-line change here plus the Info.plist types.
enum SupportedTypes {
    static let utTypes: [UTType] = [.jpeg, .png]
    static let extensions: Set<String> = ["jpg", "jpeg", "png"]

    /// True for a page image the viewer can display.
    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Content types the ⌘O panel should allow: page images, comic archives, and folders.
    static var openPanelTypes: [UTType] {
        let exts = extensions.union(ArchiveExtractor.extensions)
        return exts.compactMap { UTType(filenameExtension: $0) } + [.folder]
    }
}
