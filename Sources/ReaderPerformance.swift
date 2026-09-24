import Foundation
import os.log

/// Unified performance instrumentation for the reader.
///
/// Events are measurement-only: they do not affect loading decisions or cache policy.
/// Use Console/Instruments with subsystem `com.esteban.ComicViewer` and category `Performance`.
enum ReaderPerformance {
    static let subsystem = "com.esteban.ComicViewer"
    static let log = OSLog(subsystem: subsystem, category: "Performance")

    @discardableResult
    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }

    static func event(_ message: String) {
        log.info("\(message, privacy: .public)")
    }

    static func metric(_ name: String, milliseconds: Double) {
        log.info("\(name, privacy: .public) duration_ms=\(String(format: "%.1f", milliseconds), privacy: .public)")
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000.0
    }

    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
