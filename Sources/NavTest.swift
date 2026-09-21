import Foundation

/// Headless test hook: `ComicViewer --navtest <file>` opens the file (triggering
/// the real folder scan + sort), prints the ordered set and the starting index, then
/// exercises wrap-around next/prev using the real AppModel logic. Index updates are
/// synchronous (only decoding is async), so this validates navigation without a window.
enum NavTest {
    @MainActor
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--navtest"), i + 1 < args.count else { return }
        let file = URL(fileURLWithPath: args[i + 1])

        let model = AppModel()
        model.open(urls: [file])
        guard !model.items.isEmpty else { print("navtest: no items"); exit(2) }

        print("items (Finder-sorted):")
        for (k, u) in model.items.enumerated() {
            print("  [\(k)] \(u.lastPathComponent)" + (k == model.index ? "   <- opened" : ""))
        }
        func name() -> String { model.items[model.index].lastPathComponent }

        var seq: [String] = []
        for _ in 0..<(model.items.count + 2) {
            model.next()
            seq.append("\(model.index):\(name())")
        }
        print("next ×\(model.items.count + 2): " + seq.joined(separator: " → "))

        model.first()
        print("first → index=\(model.index) (\(name()))")
        model.prev()
        print("prev from first wraps → index=\(model.index) (\(name()))")
        exit(0)
    }
}
