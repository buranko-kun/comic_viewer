# ComicViewer development memory

Updated: 2026-10-07. This file records shared project context. Machine-specific notes belong
in the ignored `PROJECT_NOTES.md`; library files, browser sessions, catalogues, caches,
reading history, and credentials are not repository artifacts.

## Working conventions

- Keep the app core independent of individual websites. Source-specific scraping belongs in
  installable JavaScript plugins; generic runtime capabilities connect plugins to the UI.
- Preserve source archives during reading and cover generation. Page deletion is an explicitly
  requested storage operation; routine scans must retain covers preserved before trimming.
- Build the current source before launching. Rebuilding does not erase Application Support
  caches; plugin script/version changes can invalidate their associated cached data.
- Record completed work, verification, and unresolved limitations here after substantial updates.

## Existing product decisions

- A collapsible left sidebar provides Home, Library, Online, and Collections navigation.
  Search stays centered in the content area; headings, counts, controls, and cover grids align.
- Home shows smart collections; Collections shows user-created collections. Collection display
  can use a grid or shelves, with consistent thumbnail dimensions and configurable ordering.
- Library browsing follows folders, grouping separate issue archives into series and subseries.
- Read-page deletion removes every page before the current page, including material before
  the first marked chapter. Saved covers survive this operation during ordinary browsing.
- Reading reset clears progress and removes Continue Reading / Recently Read entries.
  Chapter markers stay unless the user explicitly chooses to reset them too.
- Manual catalogue thumbnails open information; the title in that popup opens the website.
  Readable plugin thumbnails open the series or reader. Local thumbnails open local comics.

## Changes included in this update

### Online catalogues and plugin runtime

- Online has a catalogue selector instead of combining sources into a confusing root with
  next-page folders. Manual catalogue display names come from configuration, not hardcoded app logic.
- A locally installed source presents a flat catalogue with app sorting controls. Background continuation
  batches publish early, preserve ordering, resume incomplete snapshots, and retain completed
  catalogue snapshots until explicit refresh. Requests adapt after source rejection.
- `RemoteCatalog.continuationURL` and catalogue merging support progressive plugin results.
  The aggregator guards against repeated continuation URLs and stale generations, saves
  partial results on failure, and yields between batches for reader and cover operations.
- Generic `cached-catalog` and `first-page-covers` capabilities keep website behavior out of
  the app core. Capable plugins discover each issue's first page rather than repeating the series cover.
- Issue cover resources and parsed page lists have a 14-day cache. Synchronous remembered
  cover lookup prevents recycled grid cards briefly reverting to the series cover on scroll.
- Plugin test startup runs asynchronously after AppKit finishes launching, through the app
  delegate. It does not create NSApplication from the SwiftUI App initializer. Fixture progress
  is printed immediately, and offline fixtures follow continuation batches.
- CI includes JavaScript regressions and offline WebKit fixtures, using the same derived
  build directory as the macOS tests. GitHub initially rejected the workflow update;
  authorization was refreshed with workflow scope before publishing this follow-up.

### Online browsing, search, and reading history

- Saved plugin series retain their remote action and open issue listings inside the app.
  Legacy favourites resolve against cached catalogue entries when available.
- Back navigation restores the parent's search, results, sorting, window, and scroll anchor.
  Opening a series from Home or Collections preserves the previous Online session and returns
  to the originating section.
- Search history persists. First click focuses typing; a second click while focused shows
  history. Typing shows matching catalogue titles; outside clicks dismiss the dropdown.
  Native click handling makes history rows outside toolbar bounds selectable.
- Streamed issues participate in observable Continue Reading and Recently Read smart lists,
  survive relaunch, and disappear from those lists after reading reset. Local and remote
  entries are deduplicated, and remote entries reopen in the reader.
- Connection errors show a concise heading such as Error 403 with technical detail below.
  Opening the source browser and closing it retries the original operation automatically.
  Navigation cancels obsolete recovery actions. Verification challenges remain user-completed.

### Reader and local library

- Previous/next navigation connects neighbouring local issues in the same folder. Going
  backward from an issue's first page opens the previous issue's last page; forward from the
  last page opens the next issue. A negative explicit start index supports opening at the end.
- F toggles app fullscreen from every section. Escape closes overlays or navigates backward
  while preserving the window's fullscreen state. Clickable navigation controls use hand cursors;
  collapsed sidebar controls have styled delayed tooltips with labels and shortcuts.
- The native window title displays the comic title during reading, rather than a page filename.
- Reader shortcuts: 1 = first comic page, 2 = first current chapter page,
  9 = last current chapter page, 0 = last comic page. Command-C copies the displayed page
  image to the clipboard; text editing keeps its normal copy behavior.
- WebP is supported by scanners, archive covers, the reader, and open-file content types.
  Local folders can be deleted with their contents through the library context menu.
- Reset Reading now refreshes local covers and discards their old memory/disk thumbnails.
  The folder context menu resets every contained issue, including nested folders.
  Background refreshes use bounded concurrency and refresh visible cover views on completion.
- Archive cover refresh extracts into an isolated staging cache, validates the image, updates
  both normal and previously preserved covers, and retains the old cover if extraction fails.
  Cleanup compares filenames consistently across macOS /var and /private/var aliases.
  Routine scans still reuse preserved covers; explicit reset adopts the current first page.

## Verification

- Current debug app builds successfully.
- Private local plugin regression suite: 9 tests passed before repository separation.
- Cover refresh plus smart collections: 16 targeted XCTest tests pass, including saved-cover
  replacement after first-page removal, failed extraction fallback, thumbnail invalidation,
  and streamed reading reset with and without chapter removal.
- Earlier targeted checks passed for catalogue/runtime recovery (27), reader shortcuts (7),
  folder deletion (4), and reading history/state/navigation (13).
- Final full macOS XCTest suite: 124 tests pass with zero failures. The back-navigation
  regression test now exercises the current external-navigation API rather than setting the
  obsolete return-to-search flag directly.
- Private local plugin WebKit fixture suite: all 6 cases passed before repository separation, including catalogue continuation,
  warm cache, chapter ordering, lazy image discovery, and challenge-page failure reporting.

## Scope and remaining limits

- Website availability, rate limiting, and verification requirements are external; offline
  fixtures do not guarantee live access. Initial remote catalogue discovery still proceeds in batches.
- Issue covers fall back to the series image if discovery fails. Reset cover regeneration applies
  to local comics; streamed reading reset clears history without forcing remote image downloads.
- Cover generation never changes comic contents. One-off local archive cleanup and catalogue
  configuration changes are recorded only in private notes and are not uploaded.
- App updates initially used `fix-plugin-runtime-return-values`. The repository separation
  update also advances main to the cleaned code. No downloadable release is created.
- The workflow authorization issue was resolved on 2026-10-07. App improvements and memory
  were published in commit `42fc64f`; the CI workflow is included in the follow-up commit.
  CI runs on pushes to main/refactor branches and on pull requests; this working-branch push
  alone does not guarantee a new CI run.


## Repository separation — 2026-10-07

- Website-specific integrations and scraper scripts are private local files, excluded by
  `/plugins/` and `/scripts/` in `.gitignore`. Installed plugin copies, settings, sessions,
  and caches remain in local Application Support storage and are not changed by Git cleanup.
- The public repository retains the generic plugin runtime, example templates, and synthetic
  example-domain fixtures. CI must not depend on private integrations.
- Shared comments, tests, and documentation use generic source names. Private source details
  and backup locations belong in the ignored project notes.
- Historical commits and old branches can still expose removed files. Removing files from
  current branch tips does not purge Git history; destructive history cleanup requires a
  separate, reviewed step.

- Separation validation: 124 macOS tests, 4 generic JavaScript regressions, and 3 generic
  WebKit fixture cases pass. The private local plugin's 9 regressions also still pass.
  All 37 private integration files and their backup copies are byte-for-byte unchanged.
- The tracked tree contains no private integration paths or known source-specific/personal
  text matches. Cleanup commits use generic contributor attribution; earlier authorship
  and removed files remain in existing history until a separate history cleanup is approved.
