import Foundation

/// Headless test: `ComicViewer --statetest <folder>` verifies resume-reading and the
/// legacy in-folder sidecar → central-store migration, using the real AppModel. State now
/// lives in `~/Library/Application Support/ComicViewer/state/<hash>.json`, not in the folder.
/// Exits when done.
enum StateTest {
    @MainActor
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--statetest"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let central = CentralStore.stateURL(for: CentralStore.key(for: dir))
        let legacyNew = dir.appendingPathComponent(".comicviewer.json")
        let legacyOld = dir.appendingPathComponent(".landscape-chapters.json")
        let fm = FileManager.default
        try? fm.removeItem(at: central)
        try? fm.removeItem(at: legacyNew)
        try? fm.removeItem(at: legacyOld)

        // --- Resume + central write ---
        let m = AppModel()
        m.open(urls: [dir])
        let n = m.items.count
        print("items=\(n)  start index=\(m.index)")
        guard n >= 5 else { print("need >=5 images"); exit(2) }
        for _ in 0..<4 { m.next() }
        let landed = m.index
        // Toggling a chapter forces an immediate save, which also records lastPage.
        _ = m.toggleChapter()
        print("navigated to index \(landed), set a chapter, saved")
        print("CENTRAL WRITE: \(fm.fileExists(atPath: central.path) ? "PASS" : "FAIL")")
        print("NO IN-FOLDER SIDECAR: \(!fm.fileExists(atPath: legacyNew.path) ? "PASS" : "FAIL")")

        let m2 = AppModel()
        m2.open(urls: [dir])   // opening the folder → should resume from the central file
        print("reopened index=\(m2.index), chapters=\(m2.chapters.count)")
        print("RESUME: \(m2.index == landed ? "PASS" : "FAIL")")
        print("CHAPTERS PERSIST: \(m2.chapters.count == 1 ? "PASS" : "FAIL")")

        // --- Migration: legacy in-folder sidecar → central, then retired ---
        try? fm.removeItem(at: central)
        let name = m.items.indices.contains(2) ? m.items[2].lastPathComponent : ""
        let legacyJSON = "{\"version\":1,\"chapters\":[\"\(name)\"]}"
        try? legacyJSON.data(using: .utf8)!.write(to: legacyOld)
        let m3 = AppModel()
        m3.open(urls: [dir])
        let centralWritten = fm.fileExists(atPath: central.path)
        let legacyGone = !fm.fileExists(atPath: legacyOld.path)
        print("MIGRATION: chapters=\(m3.chapters.count) central=\(centralWritten) legacyRemoved=\(legacyGone) "
            + "\(m3.chapters.contains(name) && centralWritten && legacyGone ? "PASS" : "FAIL")")

        try? fm.removeItem(at: central)
        try? fm.removeItem(at: legacyOld)
        exit(0)
    }
}
