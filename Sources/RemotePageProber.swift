import Foundation

/// Discovers how many pages a remote series issue has, by probing its `{page}` URL template against
/// the CDN. Pure networking — no app/UI state — so it lives on its own and is independently testable.
///
/// The hard part is throttling: a rate-limited CDN can return a transient failure that looks like a
/// 404, which would truncate an issue. So every check is **tri-state** (`exists` / `absent` /
/// `unknown`) and the count logic refuses to guess on `unknown` — it either falls back to the
/// reliable sequential probe or fails closed, never returning a wrong (short) page list.
enum RemotePageProber {
    /// Safety ceiling so a misbehaving template can't probe forever.
    static let maxRemotePages = 2000

    /// Discover a series issue's pages from a `{page}` template + zero-padding. Fast path: start at
    /// `hint`, exponential-search to bracket the 200→404 boundary, then binary-search the exact
    /// count. Any uncertain check falls back to the reliable sequential probe. Fast when the CDN is
    /// happy, correct when it isn't.
    static func probePages(template: String, pad: Int, hint: Int) async -> [URL] {
        func url(_ n: Int) -> URL? {
            URL(string: template.replacingOccurrences(
                of: "{page}", with: String(format: "%0\(max(0, pad))d", n)))
        }
        if let count = await hintedCount(url, hint: hint) {
            return count == 0 ? [] : (1...count).compactMap(url)
        }
        // An uncertain sequential probe must fail closed rather than returning a partial page list.
        return await sequentialPages(url) ?? []
    }

    /// Find the page count by probing around `hint`. Uses exponential search to find a
    /// known-missing upper bound, then binary-searches the exact boundary. Any uncertain response
    /// falls back to the sequential probe, which also distinguishes `.unknown` from `.absent`.
    private static func hintedCount(_ url: (Int) -> URL?, hint: Int) async -> Int? {
        switch await pageStatus(url(1)) {
        case .absent:  return 0
        case .unknown: return nil
        case .exists:  break
        }

        let h = max(2, min(hint, maxRemotePages))
        switch await pageStatus(url(h)) {
        case .unknown: return nil
        case .absent:
            var lo = 1
            var hi = h
            while hi - lo > 1 {
                guard !Task.isCancelled else { return nil }
                let mid = (lo + hi) / 2
                switch await pageStatus(url(mid)) {
                case .exists: lo = mid
                case .absent: hi = mid
                case .unknown: return nil
                }
            }
            return lo
        case .exists:
            var lo = h
            var step = 1
            var hi: Int?

            while lo < maxRemotePages {
                guard !Task.isCancelled else { return nil }
                let candidate = min(lo + step, maxRemotePages)
                switch await pageStatus(url(candidate)) {
                case .exists:
                    lo = candidate
                    if candidate == maxRemotePages { return lo }
                    step *= 2
                case .absent:
                    hi = candidate
                case .unknown:
                    return nil
                }
                if hi != nil { break }
            }

            guard let hi else { return lo }
            var low = lo
            var high = hi
            while high - low > 1 {
                guard !Task.isCancelled else { return nil }
                let mid = (low + high) / 2
                switch await pageStatus(url(mid)) {
                case .exists: low = mid
                case .absent: high = mid
                case .unknown: return nil
                }
            }
            return low
        }
    }

    /// Reliable fallback: probe sequentially and only stop on a confirmed missing page.
    private static func sequentialPages(_ url: (Int) -> URL?) async -> [URL]? {
        var pages: [URL] = []
        var n = 1
        while n <= maxRemotePages {
            guard !Task.isCancelled, let u = url(n) else { break }
            switch await pageStatus(u) {
            case .exists:
                pages.append(u)
                n += 1
            case .absent:
                return pages
            case .unknown:
                // pageStatus already retried; remain conservative rather than silently truncating.
                let retry = await pageStatusWithLongerBackoff(u)
                switch retry {
                case .exists:
                    pages.append(u)
                    n += 1
                case .absent:
                    return pages
                case .unknown:
                    return nil
                }
            }
        }
        return pages
    }

    enum PageStatus { case exists, absent, unknown }

    /// Tri-state page check: only a clean 404/410 means absent. Transient failures stay unknown.
    /// HEAD is used first to avoid downloading image bodies; a tiny ranged GET is the fallback for
    /// servers/CDNs that do not implement HEAD correctly.
    private static func pageStatus(_ url: URL?) async -> PageStatus {
        guard let url else { return .absent }

        for attempt in 0..<3 {
            if Task.isCancelled { return .unknown }

            var head = URLRequest(url: url)
            head.httpMethod = "HEAD"
            head.timeoutInterval = 15

            if let (_, resp) = try? await URLSession.shared.data(for: head),
               let http = resp as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) { return .exists }
                if http.statusCode == 404 || http.statusCode == 410 { return .absent }
            }

            // Some CDNs reject or mishandle HEAD. A one-byte ranged GET verifies that the actual
            // resource is reachable without intentionally fetching a whole page.
            var ranged = URLRequest(url: url)
            ranged.httpMethod = "GET"
            ranged.timeoutInterval = 15
            ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")

            if let (_, resp) = try? await URLSession.shared.data(for: ranged),
               let http = resp as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) { return .exists }
                if http.statusCode == 404 || http.statusCode == 410 { return .absent }
            }

            try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
        }
        return .unknown
    }

    private static func pageStatusWithLongerBackoff(_ url: URL) async -> PageStatus {
        for delay: UInt64 in [1_000_000_000, 2_000_000_000, 4_000_000_000] {
            guard !Task.isCancelled else { return .unknown }
            try? await Task.sleep(nanoseconds: delay)
            let status = await pageStatus(url)
            if status != .unknown { return status }
        }
        return .unknown
    }
}
