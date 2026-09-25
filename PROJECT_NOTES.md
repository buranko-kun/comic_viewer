# Comic Viewer — Project Notes

A native macOS SwiftUI **comic reader library**. You configure library folders in the app;
it scans them for comics and shows a **home grid of covers grouped by series**. Click a cover
to read: every page is shown in landscape (portrait pages rotated 90° clockwise *at display
time*, never on disk), with chapters, a thumbnail grid, zoom/pan, and resume-reading. Per-comic
state lives centrally in the app's Application Support directory.

> **v0.3 replaced the old "ecosystem".** Earlier versions relied on a background auto-processor
> (launchd agent + SwiftBar menu bar) that extracted archives and Finder-tagged every image to
> open in the viewer. That is **all removed** — browsing happens inside the app now, so files
> don't need tagging and folders stay clean. See "Removed: the old automation" below.

Environment when built: macOS 26.x, Xcode 26.x, Apple Silicon. Bundle id
`com.esteban.ComicViewer`.

---

## v0.3 — Library platform

The app is now a library, not just a single-comic reader.

- **Central state store** (`CentralStore.swift`): all per-comic state moved out of comic folders
  into `~/Library/Application Support/ComicViewer/` — `state/<sha256(comicKey)>.json` per comic
  (`comicKey` = the comic's canonical path) plus `library.json` (configured folders). Opening a
  comic still transparently **migrates** any old in-folder sidecar (`.comicviewer.json` /
  `.landscape-chapters.json`, or `<name>.comicviewer.json` beside an archive) into the central
  store and deletes the in-folder file. `ComicState` gained an optional `path` field (readability,
  since filenames are hashes).
- **Library model + scan** (`Comic.swift`, `LibraryModel.swift`): a **comic = any folder that
  directly contains ≥1 image** (its direct images are the pages) **or an archive file**. Scan walks
  each root recursively; **series = the first path component under the root**. So `Daredevil/Companion`
  and `Daredevil/Omnibus` are two comics in the "Daredevil" series; each `Cable NNN` folder is its
  own comic. Sorted `localizedStandard`. Folder covers = first page; archive covers are placeholders
  (`doc.zipper`) until first opened.
- **Library UI** (`LibraryView.swift`): up to **three levels** of browse. Level 1 is a **series
  gallery** — one 2:3 cover per series (`SeriesEntry`, cover = first issue's page) with an issue-count
  badge on multi-issue series. Clicking a **multi-issue** series drills into Level 2, a `LazyVGrid`
  of its **issues** (`CoverCell`, with a **progress badge** — thin red bar + "p.X / N" — and a
  **bookmark badge** with the chapter count). Level 3, the **chapter grid** (`ChapterCard`), appears
  when you open an issue **that has chapters**: each chapter's page thumbnail + "Chapter N / page P";
  clicking jumps the reader to that page (`AppRouter.openChapter` → `AppModel.goTo`). The chapter
  toolbar also has a **Read/Continue** button to open the comic normally. Chapters are resolved from
  the central `ComicState` (folders only; archives skip this level). Single-comic series short-circuit
  to `openIssue`, so a one-shot with chapters (e.g. Descender) jumps straight to its chapter grid.
  Toolbar: Add Folder, Rescan, rotate-orientation, Remove Folder. Empty state offers `~/Downloads/Media/Comics`.
- **Navigation** (`RootView.swift` + `AppRouter`): app opens to the **Library** series gallery,
  **maximized to the screen** (`RootView.maximizeWindow` on launch / on returning to library).
  `AppRouter.selectedSeries` (gallery ⇄ issue grid) and `selectedComic` (issue grid ⇄ chapter grid)
  drive the levels; opening an issue/chapter → Reader; **Esc** (when no overlay/fullscreen) or **⌘L**
  → back to the Library (rescans, lands back where you were). ⌘O / drag / Open-With jump straight to
  the Reader. The reader has an on-screen "‹ Library" pill (top-leading, in reading orientation).
- **Orientation**: the **Library is landscape** (upright, normal scroll) — only the reader goes
  portrait. `AppRouter.libraryPortrait` defaults `false`; a toolbar rotate button can flip it.
- **Page rotation is content-aware** (fixes portrait comics looking "rotated/squashed"): the reader
  rotates a portrait page 90° to fill the screen **only when in rotated mode**. The default per comic
  is probed from the first page — **landscape-native scans** (pre-rotated, e.g. Cable/Descender)
  default to rotated mode (image stays landscape, overlays rotate to portrait); **genuine portrait
  comics** (e.g. Deadpool `.cbr`s) default to **upright** (no image rotation, normal overlays). `R`
  toggles + persists the per-comic override (`manualRotate`); `AppModel.pagesLandscape` sets the
  default, `RotatingImageView(rotate:)` applies it.
- **Archive covers are real** now (`ArchiveCover.swift`): the library lazily extracts just the first
  image entry from a `.cbz/.cbr/…` (via `7zz l -slt` + single-entry `7zz e`, full-extract fallback)
  and caches it under `Application Support/ComicViewer/covers/<sha>.<ext>` — no more zipper placeholder.
- **ComicInfo.xml metadata** (`ComicInfo.swift`): a folder's `ComicInfo.xml` (ComicRack standard) is
  parsed for `Title/Series/Number/Summary/Writer/Year/PageCount` and `<Page Bookmark="…">` entries.
  The library uses `displayTitle` as the comic's title (e.g. "House Of M Omnibus", "Immortal Hulk #0")
  and shows series/credits/summary as a **hover tooltip** on covers. Bookmarks become **named
  chapters**: they're merged (union) with the user's manual chapters everywhere — the library chapter
  level (`ChapterRef.name`/`label`), the reader's `T` grid, the Chapters menu, and Shift+←/→. Manual
  chapters persist in `ComicState`; bookmark chapters are **derived read-only** (re-read from the XML,
  never written to state), so they can't drift. Archives get metadata only after extraction (the temp
  dir's `ComicInfo.xml` is read on open). Reading-position highlight: the chapter level red-outlines
  the chapter your resume page falls into, and the toolbar shows "Chapter N · p.X/N".
- Removed the redundant `⌘K` "Toggle Chapter Here" menu item (`C` already does it).

---

## v0.2 additions (reading + polish)

- **Open archives directly** (`.cbz/.cbr/.zip/.rar/.7z`): extracted to a temp dir via `unar`
  (7zz fallback) in `ArchiveExtractor.swift`; opened like a folder; temp dirs cleaned on quit.
  State sidecar lives **beside the archive** (`<name>.comicviewer.json`).
- **Resume reading**: last page saved per comic; opening a folder/archive (or its first page)
  resumes there with a "Resumed — N / M" toast.
- **Zoom & pan**: pinch, `+`/`−` (zoom), `0` (fit), double-click (toggle); when zoomed, **drag,
  arrow keys, or two-finger trackpad scroll pan** (arrows navigate pages only at fit); resets to
  fit on each page. `ContentView` + `KeyMonitor` (now also watches `.scrollWheel`).
- **Chapters menu**: dynamic "Chapters" menu (click to jump); toggle with `C`; alongside Shift+←/→.
- **Chapter thumbnail grid** (`T`): dimmed overlay with a paginated grid (6/page, 3×2) of each
  chapter's page image; click to jump; ←/→ or ‹ › to page; current chapter outlined red.
  `ChapterGridOverlay.swift` + `ThumbnailCache.swift` (small 500px thumbnails). The grid and the
  help overlay are wrapped in `ContentView.rotatedToRead` — for a portrait comic the whole overlay
  rotates 90° (frame-swap) to match the reading orientation, like the caption and main image.
  Cells are portrait 2:3 covers. Thumbnails **preload in the background** on comic/chapter change
  (`preloadChapterThumbs` → `ThumbnailCache.preload`, capacity 300) so the grid opens instantly.
- **Help overlay**: `?` toggles a shortcut list; `Esc` closes.
- **App icon**: generated by `tools/make_icon.py` → `Sources/Assets.xcassets/AppIcon.appiconset`.

**Per-comic state** is now unified in **`.comicviewer.json`** (`ComicState.swift`: `chapters`,
`lastPage`, `manualRotate`), replacing `.landscape-chapters.json`, which is **auto-migrated** on
first open (read, rewritten as `.comicviewer.json`, old file removed). Chapters keyed by filename.

**Overlay orientation**: the HUD / caption / chapter grid / help **default to portrait (rotated)
for every comic** — `AppModel.readingPortrait = manualRotate ?? true`. `R` toggles a per-comic
override (persisted in `manualRotate`: nil = default portrait, true = portrait, false = landscape)
for the rare genuine-landscape comic. The image itself still rotates only by its own dimensions
(portrait pages → landscape display; pre-rotated landscape files shown as-is).

**Folders with pages in a subfolder**: `openFolder` falls back to a recursive scan when a folder
has no direct images. Note a folder that contains *multiple* comic subfolders (e.g. an omnibus +
companion) will merge them into one list — open the specific subfolder for a single comic.

**⚠️ Full Disk Access**: because the app was renamed (new bundle id), and comics live in the
protected `~/Downloads`, **ComicViewer must be granted Full Disk Access** (System Settings →
Privacy & Security → Full Disk Access → add `~/Applications/ComicViewer.app`) or it can't scan
folders / write sidecars there. One-time.

Headless test hooks (run on the built binary): `--statetest <folder>` (resume + central-store
migration), `--librarytest <root>` (leaf/archive scan + series grouping), `--archivetest <archive>`
(extraction incl. nested), plus `--snapshot`, `--navtest`, `--chaptertest`. Keys: `+ − 0` zoom,
`?` help, `C` toggle chapter, `T` chapter grid, `R` rotate overlays, `⌘L`/`Esc` back to library.

---

## 1. Comic Viewer (the app)

> Renamed from "Landscape Viewer" → **Comic Viewer** (target/product `ComicViewer`, bundle id
> `com.esteban.ComicViewer`). The **source folder kept its original name** `~/Developer/LandscapeViewer`;
> only the Xcode target, product, bundle id, and installed app were renamed.

### Where it lives
- **Source project:** `~/Developer/LandscapeViewer/`  (folder name unchanged; builds `ComicViewer`)
  - `project.yml` — XcodeGen spec (the project is generated, not hand-maintained).
  - `Sources/*.swift`, `Sources/Info.plist`
  - `Tests/OrientationTests.swift`
  - `ComicViewer.xcodeproj` — generated; safe to delete and regenerate.
- **Installed app:** `~/Applications/ComicViewer.app` (Release build; this is the one
  the automation points at).

### Build / run
The project uses **XcodeGen** (`brew install xcodegen`). After editing `project.yml` or
adding/removing files under `Sources/`:
```bash
cd ~/Developer/LandscapeViewer
xcodegen generate
xcodebuild -project ComicViewer.xcodeproj -scheme ComicViewer -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/ComicViewer.app
```
Run the unit tests:
```bash
xcodebuild -project ComicViewer.xcodeproj -scheme ComicViewer test
```
Reinstall the Release build to `~/Applications` (what the automation uses):
```bash
xcodebuild -project ComicViewer.xcodeproj -scheme ComicViewer -configuration Release \
  -derivedDataPath build build
rm -rf ~/Applications/ComicViewer.app
cp -R build/Build/Products/Release/ComicViewer.app ~/Applications/
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f ~/Applications/ComicViewer.app
```
Signing is local ad-hoc (`CODE_SIGN_IDENTITY "-"`); no Apple Developer account. Deployment
target macOS 14. Non-sandboxed.

### Architecture (Sources/)
| File | Role |
|---|---|
| `LandscapeViewerApp.swift` | `@main App`; window hosts `RootView`; File▸Open (⌘O) + Library (⌘L); "Go"/"Chapters" menus; `@NSApplicationDelegateAdaptor`. Runs test hooks in `init()`. |
| `AppDelegate.swift` | `application(_:open:)` → routes Finder "Open With" / `open -a` into `AppRouter.openExternal` (→ reader). |
| `AppModel.swift` | `@MainActor @Observable`: `items`, `index`, `current`; folder/archive scan, wrapping nav, chapters, async load; central-store state via `comicKey`. `AppModel.shared`. |
| `RootView.swift` | `AppRouter` (`@Observable`: `route` library/reader, `selectedSeries`, `libraryPortrait`; `openSeries`/`openComic`/`showLibrary`) + `RootView` switching Library ⇄ Reader and maximizing the window for the library. |
| `LibraryModel.swift` | `@MainActor @Observable` library: `folders`, `comics`, `sections`, `seriesEntries`, `comics(inSeries:)`; `scan()` (leaf-folder + archive detection, series grouping). `LibraryModel.shared`. |
| `Comic.swift` | `Comic` (url, series, isArchive, coverURL, pageCount, progress), `ComicProgress`, `SeriesEntry`. |
| `LibraryView.swift` | Two-level library UI: series gallery (`SeriesCard`) → issue grid (`CoverCell`); toolbars, progress badges, empty states; landscape by default. |
| `CentralStore.swift` | Application Support paths, `sha256` keying, `stateURL(for:)`, `loadState(forKey:)`, library-config load/save. |
| `ComicInfo.swift` | `ComicInfo.xml` parser (XMLParser): book metadata + `<Page Bookmark>` → named chapters; `load(fromFolder:)`. |
| `ImageLoader.swift` | ImageIO: `probe` (dims + EXIF) and `decodeDisplay` (EXIF-upright, downsampled `CGImageSourceCreateThumbnailAtIndex`, `WithTransform: true`). |
| `Orientation.swift` | Pure EXIF logic. **The correctness core.** Values 5–8 swap W/H → `isPortrait`. Unit-tested. |
| `RotatingImageView.swift` | The display: `Image` + `.rotationEffect(90° for portrait)` + **frame-swap** so the rotated view fits the window with no distortion. |
| `ContentView.swift` | Root view; NSEvent key monitor; caption + toast overlays (center-pinned); drop target. |
| `ImageCache.swift` | `actor` LRU (cap 7) + ±1 neighbour prefetch so paging is instant. |
| `KeyMonitor.swift` | Local `NSEvent` monitor for bare keys (avoids SwiftUI focus issues). |
| `DisplayImage.swift`, `SupportedTypes.swift`, `ComicState.swift`, `ArchiveExtractor.swift` | Small model/config types + in-app archive extraction. |
| `SnapshotMode.swift`, `NavTest.swift`, `ChapterTest.swift`, `StateTest.swift`, `ArchiveTest.swift`, `LibraryTest.swift` | Headless test hooks (below). |

### The defining behavior — orientation
- Read pixel dims + `kCGImagePropertyOrientation` (1–8). **EXIF 5–8 = a 90/270 rotation**, so
  the *visual* size is W/H swapped. `isPortrait = visualHeight > visualWidth`. This is why a
  landscape-pixels file with an EXIF flag is correctly treated as portrait.
- Decode with `kCGImageSourceCreateThumbnailWithTransform: true` → the bitmap comes back
  visually upright and downsampled to the screen's long edge (sharp, low memory).
- Portrait → the SwiftUI view is rotated `+90°` (clockwise, top edge → right). The **frame-swap**
  (giving the pre-rotation view the swapped W/H) is what makes it fit without distortion.
- v1 formats: **JPEG + PNG only** (`SupportedTypes.swift`). Adding HEIC/TIFF/WebP = add the
  `UTType`s + extensions there and the matching `LSItemContentTypes` in `Info.plist`.

### Keybindings
| Key | Action |
|---|---|
| ← / ↑ | Previous image |
| → / ↓ / Space | Next image |
| Home / End | First / Last |
| ⌘← ⌘→ ⌘↑ ⌘↓ | Same, via the **Go** menu |
| **F** | Toggle fullscreen (menu bar hidden) · **Esc** exits fullscreen |
| **H** | Toggle the filename caption (off by default) |
| **C** | Toggle a **chapter** (bookmark) on the current image |
| **Shift+← / Shift+→** | Jump to previous / next chapter (wraps) |
| **T** | Chapter thumbnail grid · **R** rotate overlays · **?** help |
| **+ − 0** | Zoom in / out / fit (when zoomed: drag, arrows, or two-finger pan) |
| ⌘O | Open a file/folder/archive (→ reader) |
| **⌘L / Esc** | Back to the Library |

### Chapters
- Bookmarks stored **by filename** in the comic's central `ComicState` (survive reordering;
  missing files pruned on load).
- `C` toggles; `Shift+←/→` jump; `T` opens the thumbnail grid; the Chapters menu lists them.

### Headless test hooks (great for verifying changes without a screen)
```bash
BIN=~/Developer/LandscapeViewer/build/Build/Products/Debug/ComicViewer.app/Contents/MacOS/ComicViewer
"$BIN" --snapshot <input.jpg> <out.png> [W H]   # render the real view to a PNG
"$BIN" --navtest <file>                          # print folder order + wrap behavior
"$BIN" --chaptertest <file>                      # exercise chapter set/persist/jump
"$BIN" --statetest <folder>                      # resume + central-store migration
"$BIN" --librarytest <root>                      # scan → comics grouped by series (+ chapters)
"$BIN" --metadatatest <folder>                   # parse ComicInfo.xml (fields + bookmarks)
```
There's also a scratch Swift snippet used during dev to print the resolved handler:
`NSWorkspace.shared.urlForApplication(toOpen:)` — handy to verify "open with" bindings.

---

## Removed: the old automation (v0.3)

The whole background ecosystem was deleted once the library made it unnecessary:

- **LaunchAgent** `com.esteban.comic-autoprocess` — `launchctl bootout` + plist deleted.
- **Scripts** `~/Library/Application Support/comic-autoprocess/` (`process_comics.py`,
  `tag_comics_openwith.py`, `status.json`, `run.lock`) — removed.
- **SwiftBar plugin** `swiftbar-plugins/comic-processor.1s.py` — removed. **SwiftBar.app itself
  is left installed** (uninstall via `brew uninstall --cask swiftbar` if you don't use it for
  anything else).
- **Logs** `~/Library/Logs/comic-autoprocess.log*` — removed.
- **Un-tagging**: the per-file `com.apple.LaunchServices.OpenWith` xattr was stripped from all
  ~7.7k library images (via `ctypes` `removexattr` — Python's `os.*xattr` are Linux-only on
  macOS), so a double-click in Finder reverts to **Preview**. `killall Finder` refreshes the cache.

Archive extraction still lives **inside the app** (`ArchiveExtractor.swift`, `unar` → `7zz`), used
when you open a `.cbz/.cbr/…` — the automation is gone, not the ability to read archives.

Historical note (why `ctypes` for xattrs): Python's `os.setxattr`/`getxattr`/`listxattr`/
`removexattr` are **Linux-only and silently absent on macOS**; use `libc` via `ctypes`. To check
which app macOS will actually use for a file: `NSWorkspace.shared.urlForApplication(toOpen:)`
(the `open` CLI is unreliable — can return -128 even when Finder is fine).

---

## Dependencies (Homebrew)
- `xcodegen` — generate the Xcode project
- `unar` — primary archive extractor (RAR/zip/7z), used by the in-app opener
- `7zz` (7-Zip) — fallback extractor
- Full **Xcode** (not just Command Line Tools) — required to build the app.
- (SwiftBar / jpegtran were only for the now-removed automation.)

## Current state
- App is a **library platform** installed at `~/Applications/ComicViewer.app`; opens to the
  Library home. Add `~/Downloads/Media/Comics` (or any folder) to populate it.
- Per-comic state is central (`~/Library/Application Support/ComicViewer/`); old in-folder
  sidecars migrate on first open. The old automation + image tagging is fully removed.
- **Full Disk Access** still required (comics live in `~/Downloads`).

## Ideas / possible next steps
- Real archive covers (peek one page on first scan, cache it) instead of placeholders.
- Persist the library orientation preference; wire `R` in the library too.
- Search / filter the library; sort options (recent, unread).
- Named chapters; remember last-read comic and reopen it.
- Re-add HEIC/TIFF/WebP (one-line in `SupportedTypes.swift` + `Info.plist`).
- Animated GIF support (rotation transform would apply per frame).


## Source plugins

- Installable online scrapers: SourcePlugin.swift, SourcePluginStore.swift, and SourcePluginRuntime.swift let third-party JavaScript files be installed from Preferences → Sources. Plugins run in a WKWebView page context, return the normalized RemoteCatalog shape, and participate in the existing Online browse/search/download UI without an app fork.
- Plugins are versioned by manifest.id, can be enabled or disabled independently, and can be updated or removed from Preferences.
- Plugin child catalogs retain a sourceID, so drilled folders route back through the owning plugin.
- Headless smoke test: ComicViewer --sourceplugintest.
