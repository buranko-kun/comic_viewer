import AppKit

/// Reliable bare-key handling for a single-window viewer via a local NSEvent monitor,
/// sidestepping SwiftUI first-responder/focus fragility. The handler returns true to
/// consume the event (no system beep). Keys with ⌘ are passed through so menu
/// shortcuts (⌘O, etc.) still work.
final class KeyMonitor {
    private var monitor: Any?

    func start(key: @escaping (NSEvent) -> Bool,
               scroll: ((NSEvent) -> Bool)? = nil) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { event in
            switch event.type {
            case .keyDown: return key(event) ? nil : event
            case .scrollWheel: return (scroll?(event) ?? false) ? nil : event
            default: return event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
