import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct ComicViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @State private var router = AppRouter.shared
    @State private var library = LibraryModel.shared

    init() {
        SnapshotMode.runIfRequested()   // headless test path; exits if --snapshot given
        NavTest.runIfRequested()        // headless nav test; exits if --navtest given
        ChapterTest.runIfRequested()    // headless chapter test; exits if --chaptertest given
        StateTest.runIfRequested()      // headless resume/migration test; exits if --statetest
        ArchiveTest.runIfRequested()    // headless archive extract test; exits if --archivetest
        LibraryTest.runIfRequested()    // headless library scan test; exits if --librarytest
        CatalogTest.runIfRequested()    // headless catalog fetch/normalize test; exits if --catalogtest
        MetadataTest.runIfRequested()   // headless ComicInfo.xml parse test; exits if --metadatatest
        ReadComicsTest.runIfRequested() // headless connector-parser test; exits if --readcomicstest
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
                .environment(library)
                .tint(.white)   // palette: black / white / gray + red (used only for progress)
                .preferredColorScheme(.dark)   // always-black UI → keep default text light
                .frame(minWidth: 640, minHeight: 400)
        }
        .windowStyle(.hiddenTitleBar)
        Settings {
            SettingsView().preferredColorScheme(.dark)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(Self.appName)") { showAboutPanel() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openImages() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Library") { router.showLibrary() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Browse Online") { router.showBrowse() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Collections") { router.showCollections() }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { router.showShortcuts.toggle() }
                    .keyboardShortcut("/", modifiers: .command)
            }
            CommandMenu("Go") {
                Button("Next") { model.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous") { model.prev() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("First") { model.first() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Last") { model.last() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
            CommandMenu("Chapters") {
                if model.orderedChapters.isEmpty {
                    Text("No chapters")
                } else {
                    ForEach(Array(model.orderedChapters.enumerated()), id: \.offset) { i, ch in
                        Button("\(ch.name) — page \(ch.page)") {
                            model.jumpToChapter(orderedIndex: i)
                        }
                    }
                }
            }
        }
    }

    /// Bundle display name (falls back to a friendly default).
    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Comic Viewer"
    }

    /// Native About panel with the app icon, name, version, and a short credit line.
    private func showAboutPanel() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let credits = NSAttributedString(
            string: "A fast, landscape-first comic reader.\nReads folders, CBZ/CBR/ZIP archives, and browses online catalogs.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: Self.appName,
            .applicationVersion: version,
            .version: "(\(build))",
            .credits: credits,
        ])
    }

    private func openImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SupportedTypes.openPanelTypes   // images, archives, folders
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true                          // open a folder → resume
        if panel.runModal() == .OK {
            router.openExternal(panel.urls)
        }
    }
}
