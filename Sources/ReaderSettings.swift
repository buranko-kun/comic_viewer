import Foundation

/// User-facing reader preferences, persisted in `UserDefaults`. Read by the reader (`ContentView`)
/// and the page model (`AppModel`); editable in Settings → Reader.
@MainActor
@Observable
final class ReaderSettings {
    static let shared = ReaderSettings()

    /// How a comic opens by default.
    /// - `horizontal`: everything shown as-is (portrait pages upright, landscape pages landscape).
    /// - `vertical`: portrait pages spun 90° to landscape; landscape pages shown as-is. (This is the
    ///   mode where "fit to width" applies — every page ends up wide.)
    enum DefaultView: String, CaseIterable, Identifiable {
        case horizontal, vertical
        var id: String { rawValue }
        var label: String { self == .horizontal ? "Horizontal" : "Vertical" }
        /// `readingPortrait` value: vertical spins portrait pages to landscape; horizontal doesn't.
        var rotated: Bool { self == .vertical }
    }

    var defaultView: DefaultView {
        didSet { UserDefaults.standard.set(defaultView.rawValue, forKey: Keys.defaultView) }
    }
    /// In **Vertical** view, wide pages fill the screen width and pan vertically instead of shrinking
    /// to fit the whole page. (No effect in Horizontal.)
    var fitWideToWidth: Bool {
        didSet { UserDefaults.standard.set(fitWideToWidth, forKey: Keys.fitWide) }
    }
    /// Show the thin chapter/reading progress bar along the bottom of the reader.
    var showProgressBar: Bool {
        didSet { UserDefaults.standard.set(showProgressBar, forKey: Keys.progressBar) }
    }

    private enum Keys {
        static let defaultView = "reader.defaultView"
        static let fitWide = "reader.fitWideToWidth"
        static let progressBar = "reader.showProgressBar"
    }

    private init() {
        let d = UserDefaults.standard
        defaultView = DefaultView(rawValue: d.string(forKey: Keys.defaultView) ?? "") ?? .horizontal
        // Default the two toggles ON (their previous fixed behavior) unless the user changed them.
        fitWideToWidth = d.object(forKey: Keys.fitWide) as? Bool ?? true
        showProgressBar = d.object(forKey: Keys.progressBar) as? Bool ?? true
    }
}
