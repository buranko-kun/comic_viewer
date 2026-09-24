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

    /// Load the visible page pair. Remote requests can run concurrently because each network
    /// request is independent. Local archive extraction stays sequential to avoid concurrent
    /// extraction against one archive session.
    func loadVisiblePages(
        primary: URL,
        secondary: URL?,
        maxPixel: Int,
        cache: ImageCache
    ) async -> (DisplayImage?, DisplayImage?) {
        switch self {
        case .remote:
            async let first = RemotePageCache.shared.image(for: primary, maxPixel: maxPixel)
            if let secondary {
                async let second = RemotePageCache.shared.image(for: secondary, maxPixel: maxPixel)
                return await (first, second)
            }
            return await (first, nil)

        case .local(let streamer):
            let first = await loadLocalPage(
                primary,
                streamer: streamer,
                cache: cache,
                maxPixel: maxPixel
            )
            guard let secondary else {
                return (first, nil)
            }
            let second = await loadLocalPage(
                secondary,
                streamer: streamer,
                cache: cache,
                maxPixel: maxPixel
            )
            return (first, second)
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
