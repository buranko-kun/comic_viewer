import SwiftUI
import WebKit

/// Embedded browser session for an installed source plugin.
/// Useful for sources that require a user to complete login, cookie, or browser challenge steps.
struct SourcePluginSessionSheet: View {
    let plugin: SourcePlugin
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    private var webView: WKWebView {
        SourcePluginRuntime.shared.sessionWebView
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).font(.headline)
                    Text("Source browser session").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()

                Button {
                    webView.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!webView.canGoBack)
                .help("Back")

                Button {
                    webView.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!webView.canGoForward)
                .help("Forward")

                Button {
                    webView.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            SourcePluginWebView(webView: webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 900, minHeight: 650)
        .task {
            do {
                try await SourcePluginRuntime.shared.openSession(for: plugin)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct SourcePluginWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
