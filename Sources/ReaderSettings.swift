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

    /// How pages are arranged and how horizontal keyboard navigation is interpreted.
    /// Logical page order remains unchanged so saved progress continues to point at the same page.
    enum ReadingDirection: String, CaseIterable, Identifiable {
        case leftToRight, rightToLeft

        var id: String { rawValue }

        var label: String {
            switch self {
            case .leftToRight: return "Left to right"
            case .rightToLeft: return "Right to left"
            }
        }

        var isRightToLeft: Bool {
            self == .rightToLeft
        }

        /// Whether the physical right arrow advances to the next logical page.
        var rightArrowAdvances: Bool {
            !isRightToLeft
        }

        /// Arrange two logically consecutive pages for physical left/right presentation.
        func arrangeSpread<T>(_ first: T, _ second: T) -> (left: T, right: T) {
            isRightToLeft ? (second, first) : (first, second)
        }
    }

    var defaultView: DefaultView {
        didSet { UserDefaults.standard.set(defaultView.rawValue, forKey: Keys.defaultView) }
    }
    /// In **Vertical** view, wide pages fill the screen width and pan vertically instead of shrinking
    /// to fit the whole page. (No effect in Horizontal.)
    var fitWideToWidth: Bool {
        didSet { UserDefaults.standard.set(fitWideToWidth, forKey: Keys.fitWide) }
    }
    /// Show the thin reading progress timeline along the bottom of the reader.
    var showProgressBar: Bool {
        didSet { UserDefaults.standard.set(showProgressBar, forKey: Keys.progressBar) }
    }

    /// Which portion of the reader the bottom scrub timeline represents.
    enum TimelineScope: String, CaseIterable, Identifiable {
        case chapter, issue, series

        var id: String { rawValue }

        var label: String {
            switch self {
            case .chapter: return "Chapter"
            case .issue: return "Issue"
            case .series: return "Series"
            }
        }
    }

    /// Whether chapter boundaries are shown as markers on the Issue/Series timeline.
    var showChapterMarkers: Bool {
        didSet { UserDefaults.standard.set(showChapterMarkers, forKey: Keys.chapterMarkers) }
    }

    var timelineScope: TimelineScope {
        didSet { UserDefaults.standard.set(timelineScope.rawValue, forKey: Keys.timelineScope) }
    }

    /// Use two-page spread when a comic opens.
    var twoPageSpread: Bool {
        didSet { UserDefaults.standard.set(twoPageSpread, forKey: Keys.twoPageSpread) }
    }

    /// Keep the first page/cover alone when two-page spread is enabled, then pair pages 2–3, 4–5, …
    var coverAloneInSpread: Bool {
        didSet { UserDefaults.standard.set(coverAloneInSpread, forKey: Keys.coverAloneInSpread) }
    }

    /// Gap, in points, between facing pages in two-page spread mode.
    var spreadGutter: Double {
        didSet { UserDefaults.standard.set(spreadGutter, forKey: Keys.spreadGutter) }
    }

    var readingDirection: ReadingDirection {
        didSet { UserDefaults.standard.set(readingDirection.rawValue, forKey: Keys.readingDirection) }
    }

    private enum Keys {
        static let defaultView = "reader.defaultView"
        static let fitWide = "reader.fitWideToWidth"
        static let progressBar = "reader.showProgressBar"
        static let chapterMarkers = "reader.showChapterMarkers"
        static let timelineScope = "reader.timelineScope"
        static let twoPageSpread = "reader.twoPageSpread"
        static let coverAloneInSpread = "reader.coverAloneInSpread"
        static let spreadGutter = "reader.spreadGutter"
        static let readingDirection = "reader.readingDirection"
    }

    private init() {
        let d = UserDefaults.standard
        defaultView = DefaultView(rawValue: d.string(forKey: Keys.defaultView) ?? "") ?? .horizontal
        // Default the two toggles ON (their previous fixed behavior) unless the user changed them.
        fitWideToWidth = d.object(forKey: Keys.fitWide) as? Bool ?? true
        showProgressBar = d.object(forKey: Keys.progressBar) as? Bool ?? true
        showChapterMarkers = d.object(forKey: Keys.chapterMarkers) as? Bool ?? true
        timelineScope = TimelineScope(
            rawValue: d.string(forKey: Keys.timelineScope) ?? ""
        ) ?? .issue
        twoPageSpread = d.object(forKey: Keys.twoPageSpread) as? Bool ?? false
        coverAloneInSpread = d.object(forKey: Keys.coverAloneInSpread) as? Bool ?? true
        let savedGutter = d.object(forKey: Keys.spreadGutter) as? Double ?? 12
        spreadGutter = min(max(savedGutter, 0), 48)
        readingDirection = ReadingDirection(
            rawValue: d.string(forKey: Keys.readingDirection) ?? ""
        ) ?? .leftToRight
    }
}
