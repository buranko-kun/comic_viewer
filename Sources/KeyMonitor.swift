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

/// Detects a two-finger horizontal "swipe right to go back" on the trackpad, like a web browser,
/// and calls `onBack` once per gesture. Feed it scroll events (see `KeyMonitor`'s `scroll:`); it
/// returns true to consume the event when it fires. Only precise (trackpad) gestures count, and
/// the motion must be clearly horizontal so vertical scrolling is never mistaken for a swipe.
final class SwipeBackDetector {
    var onBack: () -> Void = {}
    private var accX: CGFloat = 0
    private var accY: CGFloat = 0
    private var fired = false
    private let threshold: CGFloat = 55

    func handle(_ e: NSEvent) -> Bool {
        guard e.hasPreciseScrollingDeltas else { return false }
        switch e.phase {
        case .began:
            accX = 0; accY = 0; fired = false
        case .changed:
            accX += e.scrollingDeltaX
            accY += e.scrollingDeltaY
            if !fired, accX > threshold, abs(accX) > abs(accY) * 1.5 {
                fired = true
                onBack()
                return true
            }
        case .ended, .cancelled:
            fired = false
        default:
            break
        }
        return false
    }
}
