import SwiftUI
import AppKit

/// The Downloads panel: every queued, in-flight, and finished download in one place, with
/// per-item cancel / retry / open-in-browser controls. Presented as a sheet from the Online view;
/// downloads keep running whether or not it's open. Styled to match the app (black, white, red).
struct DownloadsView: View {
    @Environment(\.dismiss) private var dismiss
    private let dl = DownloadManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))
            if dl.jobs.isEmpty { empty } else { list }
        }
        .frame(width: 460, height: 520)
        .background(Color.black)
        .tint(.white)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Downloads").font(.headline).foregroundStyle(.white)
                Text(summary).font(.caption2).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if dl.hasFinished {
                Button("Clear finished") { dl.clearFinished() }
                    .buttonStyle(.borderless).pointingHandCursor()
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction).pointingHandCursor()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var summary: String {
        let active = dl.activeCount
        if active == 0 { return dl.jobs.isEmpty ? "No downloads" : "All done" }
        return "\(active) active"
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle").font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.4))
            Text("No downloads yet").font(.title3.bold()).foregroundStyle(.white)
            Text("Tap the ⬇ on any online comic to download it here.")
                .font(.callout).foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(dl.jobs) { job in
                    DownloadRow(job: job)
                    Divider().overlay(.white.opacity(0.08))
                }
            }
        }
    }
}

/// One row in the Downloads panel: cover, title/source, a status line (with a progress bar while
/// downloading), and the action that fits its state.
private struct DownloadRow: View {
    let job: DownloadManager.Job
    private let dl = DownloadManager.shared

    var body: some View {
        HStack(spacing: 12) {
            CollectionCover(item: job.item)
                .frame(width: 40, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.12), lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                Text(TitleCleaner.clean(job.item.title))
                    .font(.callout.weight(.medium)).foregroundStyle(.white).lineLimit(2)
                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            action
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    @ViewBuilder private var statusLine: some View {
        switch job.status {
        case .queued:
            Text("Queued").font(.caption2).foregroundStyle(.white.opacity(0.5))
        case .downloading(let frac):
            HStack(spacing: 8) {
                ProgressView(value: frac ?? 0, total: 1)
                    .progressViewStyle(.linear).tint(.red).frame(maxWidth: 160)
                Text(frac.map { "\(Int($0 * 100))%" } ?? "…")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            }
        case .done:
            Label("Downloaded to library", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .needsBrowser:
            Text("No direct link — open in browser")
                .font(.caption2).foregroundStyle(.orange)
        case .failed:
            Text("Failed").font(.caption2).foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var action: some View {
        switch job.status {
        case .queued, .downloading:
            iconButton("xmark.circle.fill", help: "Cancel") { dl.cancel(job.id) }
        case .failed:
            iconButton("arrow.clockwise.circle.fill", help: "Retry") { dl.retry(job.id) }
        case .needsBrowser:
            iconButton("arrow.up.forward.circle.fill", help: "Open in browser") {
                dl.openInBrowser(job.item)
            }
        case .done:
            iconButton("xmark.circle", help: "Remove from list") { dl.cancel(job.id) }
        case .idle:
            EmptyView()
        }
    }

    private func iconButton(_ system: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.title3).foregroundStyle(.white.opacity(0.8))
        }
        .buttonStyle(.plain).help(help).pointingHandCursor()
    }
}
