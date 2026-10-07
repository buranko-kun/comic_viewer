import Observation
import SwiftUI

/// App-wide transient status messages that survive navigation between sections.
/// Kept in a singleton because RootView recreates the current section view as routes change.
@MainActor
@Observable
final class AppNoticeCenter {
    static let shared = AppNoticeCenter()

    private(set) var message: String?
    private var dismissTask: Task<Void, Never>?
    private var generation = 0

    func show(_ message: String, duration: Duration = .seconds(4)) {
        generation += 1
        let current = generation
        dismissTask?.cancel()
        self.message = message
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, generation == current else { return }
            self.message = nil
            self.dismissTask = nil
        }
    }

    func dismiss() {
        generation += 1
        dismissTask?.cancel()
        dismissTask = nil
        message = nil
    }
}

/// A small app-level status bar. It stays out of the way of the content and remains visible
/// while switching between Library, Online, Collections, and other app sections.
struct AppNoticeBar: View {
    @State private var center = AppNoticeCenter.shared

    var body: some View {
        if let message = center.message {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button { center.dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            .shadow(radius: 10)
            .padding(.bottom, 14)
            .padding(.horizontal, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeOut(duration: 0.2), value: center.message)
        }
    }
}
