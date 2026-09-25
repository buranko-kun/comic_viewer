import SwiftUI
import AppKit

/// Remembers where online downloads should be saved.
///
/// The default destination keeps the existing automatic filing behavior: the first library folder
/// is used and SeriesMapper can place the comic into a series folder. A custom destination bypasses
/// automatic series filing and saves directly into the chosen folder.
@MainActor
@Observable
final class DownloadDestinationStore {
    static let shared = DownloadDestinationStore()

    private static let defaultsKey = "downloadDestinationPath"

    private(set) var customFolder: URL?

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.defaultsKey), !path.isEmpty {
            customFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    var isCustom: Bool { customFolder != nil }

    var displayName: String {
        customFolder?.path ?? "Library (automatic)"
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Download Folder"

        if let current = customFolder {
            panel.directoryURL = current
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let folder = url.standardizedFileURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        customFolder = folder
        UserDefaults.standard.set(folder.path, forKey: Self.defaultsKey)
    }

    func resetToAutomatic() {
        customFolder = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    func openInFinder() {
        if let folder = customFolder {
            NSWorkspace.shared.open(folder)
        } else if let folder = LibraryModel.shared.folders.first {
            NSWorkspace.shared.open(folder)
        }
    }
}

/// Shared queue button used throughout the app chrome. The badge reflects downloading + queued
/// jobs and opens the same live Downloads panel from any major section.
struct DownloadQueueButton: View {
    @State private var manager = DownloadManager.shared
    @State private var showDownloads = false

    var body: some View {
        Button {
            showDownloads = true
        } label: {
            Image(systemName: "arrow.down.circle")
                .overlay(alignment: .topTrailing) {
                    if manager.activeCount > 0 {
                        Text("\(manager.activeCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .offset(x: 8, y: -8)
                    }
                }
        }
        .buttonStyle(.borderless)
        .help(manager.activeCount > 0
              ? "\(manager.activeCount) active or queued download\(manager.activeCount == 1 ? "" : "s")"
              : "Downloads")
        .pointingHandCursor()
        .sheet(isPresented: $showDownloads) {
            DownloadsView()
        }
    }
}
