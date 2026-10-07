import Foundation
import UniformTypeIdentifiers

/// Single source of truth for page formats supported by the reader and archive scanner.
enum SupportedTypes {
    static let utTypes: [UTType] = [.jpeg, .png, .webP]
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

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
