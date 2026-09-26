# Torrent sharing

ComicViewer's macOS torrent layer supports creating BitTorrent v1 `.torrent` files from a comic
archive, a folder, or an entire series directory. Created torrents can be seeded directly by
ComicViewer and shared as either a `.torrent` file or a magnet link.

## Create and seed

Right-click a local comic and choose **Create Torrent…**, or open the **Torrents** panel and press
**Create** to choose any file or folder.

The creator:

- hashes pieces incrementally, so it does not load the entire source into memory;
- creates standard BitTorrent v1 metadata;
- embeds the configured tracker URLs;
- validates the generated metadata before saving it; and
- starts the built-in seeder immediately.

The generated magnet link is copied to the clipboard automatically.

## Seeding

ComicViewer runs one TCP listener for all active seeds. The default port is **6881** and can be
changed in **Preferences → Torrents**.

The seeder serves verified torrent pieces directly from the source files. It does not copy or
modify the original comic data.

For peers outside the local network, the selected TCP port normally needs to be forwarded through
the router/firewall.

Tracker discovery for the built-in seeder currently uses HTTP(S) tracker URLs from the configured
tracker list. UDP tracker URLs can still be embedded in `.torrent` files and are supported by the
SwiftTorrent downloader.

## Downloading

The Torrents panel accepts:

- `.torrent` files;
- magnet links.

Downloaded torrent data uses the same destination selection as the existing download system:
the custom download folder when configured, otherwise the first library folder, with a
`Torrent Downloads` fallback when no library folder exists.

## Source plugins

Torrent indexes are intentionally not hard-coded into ComicViewer. A future source plugin can
return torrent or magnet metadata and hand it to this torrent layer without adding another online
architecture.

## Current limitations

This first version is macOS-first. Continuous incoming seeding is not exposed by the iOS client.

The built-in seeder currently announces to HTTP(S) trackers. DHT-based seeder discovery, automatic
NAT traversal, and torrent-index publishing are separate follow-up features.

Only install or share content you have the legal right to distribute.
