# ComicViewer

A native **macOS** comic reader with an **iOS** companion, built in SwiftUI.

## Features

- **Reader** — paged reading, pinch/scroll zoom & pan, two-page spread, Horizontal/Vertical view
  (rotate portrait pages), content-aware fit-to-width, user-created named chapters, resume.
- **Library** — folders and archives (`.cbz`/`.cbr`/`.zip`/`.rar`/`.7z`), Continue Reading,
  Collections, `ComicInfo.xml` metadata + on-demand fetch from ComicVine.
- **Online sources** — a Cloudflare-gated ReadComicsOnline connector (mirror + stream ~9.5k series)
  and a downloadable GetComics catalog.
- **LAN sharing** — an opt-in Wi-Fi server (pairing code + Bonjour) exposing:
  - a **JSON API** consumed by the native iOS client (`iOS/`), and
  - an **OPDS catalog** any reader (KOReader, Panels, Chunky, …) can browse and download from.
  Large archives stream page-by-page (no full extraction).

## Build

The Xcode project is generated with [XcodeGen](https://github.com/yonasstephen/xcodegen) from
`project.yml`.

```bash
xcodegen generate                                   # regenerate ComicViewer.xcodeproj after edits
xcodebuild -scheme ComicViewer -configuration Debug build   # macOS app
```

Targets: `ComicViewer` (macOS), `ComicViewerMobile` (iOS), `ComicViewerTests`.

### iOS device install

```bash
xcodebuild -project ComicViewer.xcodeproj -scheme ComicViewerMobile -configuration Debug \
  -destination 'platform=iOS,id=<device-udid>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-udid> \
  "<derived-data>/Build/Products/Debug-iphoneos/Comic Viewer.app"
```

## Headless self-tests

The app runs headless test harnesses via CLI flags, e.g.:

```bash
ComicViewer --readcomicstest   # connector parser tests
ComicViewer --chaptertest <folder>
```
