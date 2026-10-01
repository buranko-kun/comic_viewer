import Foundation
import Observation

struct SourcePluginRunReport: Identifiable, Codable {
    let id: UUID
    let pluginID: String
    let pluginVersion: String
    let scriptHash: String?
    let operation: String
    var targetURL: String?
    let startedAt: Date
    var duration: Double
    var status: String
    var error: String?
    var rawJSON: String?
    var normalizedJSON: String?
    var warnings: [String]
    var console: [String] = []
    var stageDurations: [String: Double] = [:]

    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var safe = self
        safe.rawJSON = nil; safe.normalizedJSON = nil
        safe.console = [] // Plugin-authored messages can contain arbitrary source data.
        safe.targetURL = safe.targetURL.map { SourcePluginDiagnostics.redacted($0) }
        safe.error = safe.error.map { SourcePluginDiagnostics.redacted($0) }
        return (try? encoder.encode(safe)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// In-memory, bounded diagnostics. Capture of plugin output is explicitly opt-in.
@MainActor
@Observable
final class SourcePluginDiagnostics {
    static let shared = SourcePluginDiagnostics()
    private(set) var reports: [SourcePluginRunReport] = []
    private var capturing: Set<String> = []

    func setCaptureEnabled(_ enabled: Bool, for pluginID: String) {
        if enabled { capturing.insert(pluginID) } else { capturing.remove(pluginID) }
    }

    func isCaptureEnabled(for pluginID: String) -> Bool { capturing.contains(pluginID) }
    func latestReport(for pluginID: String) -> SourcePluginRunReport? {
        reports.last { $0.pluginID == pluginID }
    }

    func record(_ report: SourcePluginRunReport) {
        if let index = reports.firstIndex(where: { $0.id == report.id }) { reports[index] = report }
        else { reports.append(report) }
        if reports.count > 50 { reports.removeFirst(reports.count - 50) }
    }

    /// Strip authentication values from URLs and JSON before any retained/exported output.
    nonisolated static func redacted(_ value: String, limit: Int = 65_536) -> String {
        var result = value
        for pattern in [
            #"([?&][A-Za-z0-9_.%~-]+=)[^&\s\"'<>]*"#,
            #"(?i)([?&](?:token|access_token|refresh_token|auth|authorization|password|secret|key|api_key|cookie|session|sessionid|signature|sig)=)[^&\s\"'<>]*"#,
            #"(?i)(\"(?:token|access_token|refresh_token|authorization|password|secret|api_key|cookie|set-cookie|sessionid)\"\s*:\s*\")[^\"]*"#,
            #"(?i)((?:authorization|cookie|set-cookie)\s*:\s*)[^\r\n]*"#
        ] {
            result = result.replacingOccurrences(of: pattern, with: "$1[REDACTED]", options: .regularExpression)
        }
        if result.count > limit { return String(result.prefix(limit)) + "\n…[truncated]" }
        return result
    }
}
