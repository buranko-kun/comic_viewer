import SwiftUI
import CoreGraphics

/// Interactive page timeline with a thumbnail preview while scrubbing.
/// The timeline is logical-page aware, supports two-page spreads, and mirrors the
/// physical direction of the reader for RTL comics.
struct PageScrubber: View {
    let urls: [URL]
    let currentIndex: Int
    let spreadEnabled: Bool
    let readingDirection: ReaderSettings.ReadingDirection
    let cache: ThumbnailCache
    let showChapterMarkers: Bool
    let chapterIndices: [Int]
    let coverAloneInSpread: Bool
    let onSelect: (Int) -> Void

    init(
        urls: [URL],
        currentIndex: Int,
        spreadEnabled: Bool,
        readingDirection: ReaderSettings.ReadingDirection,
        cache: ThumbnailCache,
        showChapterMarkers: Bool = false,
        chapterIndices: [Int] = [],
        coverAloneInSpread: Bool = false,
        onSelect: @escaping (Int) -> Void
    ) {
        self.urls = urls
        self.currentIndex = currentIndex
        self.spreadEnabled = spreadEnabled
        self.readingDirection = readingDirection
        self.cache = cache
        self.showChapterMarkers = showChapterMarkers
        self.chapterIndices = chapterIndices
        self.coverAloneInSpread = coverAloneInSpread
        self.onSelect = onSelect
    }

    @State private var isScrubbing = false
    @State private var previewIndex: Int?
    @State private var previewImage: CGImage?
    @State private var previewSecondImage: CGImage?
    @State private var previewTask: Task<Void, Never>?

    private let trackHeight: CGFloat = 8
    private let previewWidth: CGFloat = 116
    private let previewMaxPixel = 260

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color.red)
                    .frame(
                        width: geometry.size.width * progress(for: currentIndex),
                        height: trackHeight
                    )

                if showChapterMarkers {
                    ForEach(chapterIndices, id: \.self) { marker in
                        Capsule()
                            .fill(.white.opacity(0.72))
                            .frame(width: 2, height: trackHeight + 5)
                            .position(
                                x: geometry.size.width * progress(for: marker),
                                y: geometry.size.height / 2
                            )
                    }
                }

                if isScrubbing, let previewIndex {
                    previewBubble(index: previewIndex, width: geometry.size.width)
                }

                Circle()
                    .fill(.white)
                    .frame(width: isScrubbing ? 12 : 8, height: isScrubbing ? 12 : 8)
                    .shadow(radius: 2)
                    .position(
                        x: geometry.size.width * progress(for: isScrubbing ? (previewIndex ?? currentIndex) : currentIndex),
                        y: geometry.size.height / 2
                    )
            }
            .contentShape(Rectangle().inset(by: -12))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !urls.isEmpty else { return }
                        isScrubbing = true
                        let index = index(for: value.location.x, width: geometry.size.width)
                        if previewIndex != index {
                            previewIndex = index
                            loadPreview(index: index)
                        }
                    }
                    .onEnded { value in
                        guard !urls.isEmpty else { return }
                        let index = index(for: value.location.x, width: geometry.size.width)
                        isScrubbing = false
                        previewIndex = nil
                        previewTask?.cancel()
                        previewTask = nil
                        onSelect(normalizedIndex(index))
                    }
            )
        }
        .frame(height: 18)
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
        }
    }

    private func previewBubble(index: Int, width: CGFloat) -> some View {
        let x = min(max(position(for: index, width: width), previewWidth / 2 + 4), width - previewWidth / 2 - 4)

        return VStack(spacing: 5) {
            HStack(spacing: 3) {
                if let previewImage {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                if spreadEnabled, let previewSecondImage {
                    Image(decorative: previewSecondImage, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: previewWidth, height: 145)
            .padding(5)
            .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            )

            Text(spreadEnabled && (!coverAloneInSpread || index != 0) && index + 1 < urls.count
                 ? "Pages \(index + 1)–\(index + 2) of \(urls.count)"
                 : "Page \(index + 1) of \(urls.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
        }
        .fixedSize()
        .position(x: x, y: -84)
        .allowsHitTesting(false)
    }

    private func loadPreview(index: Int) {
        previewTask?.cancel()
        previewImage = nil
        previewSecondImage = nil

        guard urls.indices.contains(index) else { return }
        let firstURL = urls[index]
        let secondURL = spreadEnabled
            && (!coverAloneInSpread || index != 0)
            && urls.indices.contains(index + 1)
            ? urls[index + 1]
            : nil
        let cache = cache
        let maxPixel = previewMaxPixel

        previewTask = Task {
            let first = await cache.thumbnail(for: firstURL, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }

            var second: CGImage?
            if let secondURL {
                second = await cache.thumbnail(for: secondURL, maxPixel: maxPixel)
            }

            guard !Task.isCancelled else { return }
            previewImage = first
            previewSecondImage = second
        }
    }

    private func progress(for index: Int) -> CGFloat {
        guard urls.count > 1 else { return 0 }
        let logical = CGFloat(normalizedIndex(index))
        let fraction = logical / CGFloat(urls.count - 1)
        return readingDirection.isRightToLeft ? 1 - fraction : fraction
    }

    private func position(for index: Int, width: CGFloat) -> CGFloat {
        width * progress(for: index)
    }

    private func index(for x: CGFloat, width: CGFloat) -> Int {
        guard urls.count > 1, width > 0 else { return 0 }
        let visual = min(max(x / width, 0), 1)
        let logical = readingDirection.isRightToLeft ? 1 - visual : visual
        return Int((logical * CGFloat(urls.count - 1)).rounded())
    }

    private func normalizedIndex(_ index: Int) -> Int {
        guard !urls.isEmpty else { return 0 }
        let clamped = min(max(index, 0), urls.count - 1)
        guard spreadEnabled else { return clamped }
        if coverAloneInSpread {
            guard clamped > 0 else { return 0 }
            return 1 + ((clamped - 1) / 2) * 2
        }
        return clamped - (clamped % 2)
    }

    static func targetIndex(x: CGFloat, width: CGFloat, count: Int, direction: ReaderSettings.ReadingDirection) -> Int {
        guard count > 1, width > 0 else { return 0 }
        let visual = min(max(x / width, 0), 1)
        let logical = direction.isRightToLeft ? 1 - visual : visual
        return Int((logical * CGFloat(count - 1)).rounded())
    }

    static func normalizedTargetIndex(
        _ index: Int,
        count: Int,
        spreadEnabled: Bool,
        coverAloneInSpread: Bool = false
    ) -> Int {
        guard count > 0 else { return 0 }
        let clamped = min(max(index, 0), count - 1)
        guard spreadEnabled else { return clamped }
        if coverAloneInSpread {
            guard clamped > 0 else { return 0 }
            return 1 + ((clamped - 1) / 2) * 2
        }
        return clamped - (clamped % 2)
    }
}
