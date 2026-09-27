import Foundation

/// Describes where reader pages come from.
///
/// Keeping this as a type instead of a Boolean remoteMode makes the loading pipeline explicit
/// and gives future sources (OPDS/WebDAV/Komga/etc.) a single extension point.
enum ReaderPageSource: Sendable {
    case local(streamer: ArchiveStreamer?)
    case remote

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    /// Load one visible page from the current reader source.
    func loadVisiblePage(
        primary: URL,
        maxPixel: Int,
        cache: ImageCache
    ) async -> DisplayImage? {
        switch self {
        case .remote:
            return await RemotePageCache.shared.image(for: primary, maxPixel: maxPixel)

        case .local(let streamer):
            return await loadLocalPage(
                primary,
                streamer: streamer,
                cache: cache,
                maxPixel: maxPixel
            )
        }
    }

    func prefetch(
        _ urls: [URL],
        maxPixel: Int,
        cache: ImageCache
    ) async {
        switch self {
        case .remote:
            await RemotePageCache.shared.prefetch(urls, maxPixel: maxPixel)

        case .local(let streamer):
            for url in urls {
                guard !Task.isCancelled else { return }
                _ = await streamer?.ensure(url)
            }
            await cache.prefetch(urls, maxPixel: maxPixel)
        }
    }

    func cancelPrefetch() async {
        if isRemote {
            await RemotePageCache.shared.cancelPrefetch()
        }
    }

    private func loadLocalPage(
        _ url: URL,
        streamer: ArchiveStreamer?,
        cache: ImageCache,
        maxPixel: Int
    ) async -> DisplayImage? {
        _ = await streamer?.ensure(url)
        return await cache.image(for: url, maxPixel: maxPixel)
    }
}
