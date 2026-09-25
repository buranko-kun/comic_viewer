import SwiftUI
import CoreGraphics

/// Series-aware timeline. Each issue occupies one equal segment, with its own reading progress.
/// Dragging within a segment opens that issue at the corresponding page when its page count is known.
struct SeriesScrubber: View {
    let comics: [Comic]
    let currentComicKey: String
    let currentIndex: Int
    let currentPageCount: Int
    let showChapterMarkers: Bool
    let chapterIndices: [Int]
    let readingDirection: ReaderSettings.ReadingDirection
    let cache: ThumbnailCache
    let onSelect: (Comic, Double) -> Void

    @State private var isScrubbing = false
    @State private var previewSegmentIndex: Int?
    @State private var previewFraction = 0.0
    @State private var previewImage: CGImage?
    @State private var previewTask: Task<Void, Never>?

    private let trackHeight: CGFloat = 8
    private let previewWidth: CGFloat = 170
    private let previewMaxPixel = 240

    var body: some View {
        GeometryReader { geometry in
            let count = comics.count
            let segmentWidth = count > 0 ? geometry.size.width / CGFloat(count) : 0
            let markerSegment = currentSegmentIndex
            let currentFraction = currentComicFraction

            ZStack(alignment: .leading) {
                if count > 0 {
                    ForEach(Array(comics.enumerated()), id: \.offset) { offset, comic in
                        let start = segmentWidth * CGFloat(offset)
                        let fill = progress(for: comic)

                        Capsule()
                            .fill(.white.opacity(0.18))
                            .frame(width: max(1, segmentWidth - 1), height: trackHeight)
                            .position(
                                x: start + segmentWidth / 2,
                                y: geometry.size.height / 2
                            )

                        Capsule()
                            .fill(Color.red)
                            .frame(width: max(0, segmentWidth * CGFloat(fill) - 1), height: trackHeight)
                            .position(
                                x: start + max(0, segmentWidth * CGFloat(fill) - 1) / 2,
                                y: geometry.size.height / 2
                            )
                    }

                    ForEach(1..<count, id: \.self) { offset in
                        Rectangle()
                            .fill(.white.opacity(0.45))
                            .frame(width: 1, height: trackHeight + 4)
                            .position(
                                x: segmentWidth * CGFloat(offset),
                                y: geometry.size.height / 2
                            )
                    }

                    if showChapterMarkers,
                       let markerSegment,
                       comics.indices.contains(markerSegment),
                       currentPageCount > 1 {
                        ForEach(chapterIndices, id: \.self) { chapterIndex in
                            let fraction = min(
                                max(Double(chapterIndex) / Double(currentPageCount - 1), 0),
                                1
                            )
                            let logical = (Double(markerSegment) + fraction) / Double(count)
                            Rectangle()
                                .fill(.white.opacity(0.78))
                                .frame(width: 2, height: trackHeight + 5)
                                .position(
                                    x: geometry.size.width * visualFraction(logical),
                                    y: geometry.size.height / 2
                                )
                        }
                    }

                    if let previewSegmentIndex, comics.indices.contains(previewSegmentIndex) {
                        previewBubble(
                            segmentIndex: previewSegmentIndex,
                            fraction: previewFraction,
                            width: geometry.size.width
                        )
                    }

                    if let markerSegment {
                        let logical = (Double(markerSegment) + currentFraction) / Double(count)
                        Circle()
                            .fill(.white)
                            .frame(width: isScrubbing ? 12 : 8, height: isScrubbing ? 12 : 8)
                            .shadow(radius: 2)
                            .position(
                                x: geometry.size.width * visualFraction(logical),
                                y: geometry.size.height / 2
                            )
                    }
                }
            }
            .contentShape(Rectangle().inset(by: -12))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !comics.isEmpty else { return }
                        isScrubbing = true
                        let target = target(at: value.location.x, width: geometry.size.width)
                        if previewSegmentIndex != target.segment {
                            previewSegmentIndex = target.segment
                            loadPreview(segmentIndex: target.segment)
                        }
                        previewFraction = target.fraction
                    }
                    .onEnded { value in
                        guard !comics.isEmpty else { return }
                        let target = target(at: value.location.x, width: geometry.size.width)
                        isScrubbing = false
                        previewSegmentIndex = nil
                        previewTask?.cancel()
                        previewTask = nil
                        onSelect(comics[target.segment], target.fraction)
                    }
            )
        }
        .frame(height: 18)
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
        }
    }

    private var currentSegmentIndex: Int? {
        comics.firstIndex { CentralStore.key(for: $0.url) == currentComicKey }
    }

    private var currentComicFraction: Double {
        guard currentPageCount > 1 else { return 0 }
        return min(
            max(Double(currentIndex) / Double(currentPageCount - 1), 0),
            1
        )
    }

    private func progress(for comic: Comic) -> Double {
        if CentralStore.key(for: comic.url) == currentComicKey {
            return currentComicFraction
        }

        guard let saved = comic.progress, saved.count > 1 else { return 0 }
        return min(
            max(Double(saved.page - 1) / Double(saved.count - 1), 0),
            1
        )
    }

    private func pageCount(for comic: Comic) -> Int {
        if CentralStore.key(for: comic.url) == currentComicKey {
            return currentPageCount
        }
        return max(comic.progress?.count ?? 0, comic.pageCount)
    }

    private func previewBubble(segmentIndex: Int, fraction: Double, width: CGFloat) -> some View {
        let comic = comics[segmentIndex]
        let logical = (Double(segmentIndex) + fraction) / Double(max(comics.count, 1))
        let x = min(
            max(width * visualFraction(logical), previewWidth / 2 + 4),
            width - previewWidth / 2 - 4
        )
        let count = pageCount(for: comic)
        let pageText = count > 1
            ? "Page \(Int((fraction * Double(count - 1)).rounded()) + 1) of \(count)"
            : "Issue"

        return VStack(spacing: 5) {
            if let previewImage {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: previewWidth, height: 112)
                    .padding(5)
                    .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    )
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "book.closed")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.5))
                    Text(comic.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: previewWidth - 18)
                }
                .frame(width: previewWidth, height: 112)
                .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
            }

            Text(comic.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text("\(pageText) • Issue \(segmentIndex + 1) of \(comics.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
        .fixedSize()
        .position(x: x, y: -92)
        .allowsHitTesting(false)
    }

    private func loadPreview(segmentIndex: Int) {
        previewTask?.cancel()
        previewImage = nil

        guard comics.indices.contains(segmentIndex),
              let cover = comics[segmentIndex].coverURL
        else { return }

        let cache = cache
        previewTask = Task {
            let image = await cache.thumbnail(for: cover, maxPixel: previewMaxPixel)
            guard !Task.isCancelled else { return }
            previewImage = image
        }
    }

    private func target(at x: CGFloat, width: CGFloat) -> (segment: Int, fraction: Double) {
        guard comics.count > 1, width > 0 else { return (0, 0) }

        let visual = min(max(x / width, 0), 1)
        let logical = readingDirection.isRightToLeft ? 1 - visual : visual
        let raw = logical * Double(comics.count)
        let segment = min(max(Int(raw.rounded(.down)), 0), comics.count - 1)
        let fraction = segment == comics.count - 1
            ? min(max(raw - Double(segment), 0), 1)
            : min(max(raw - Double(segment), 0), 1)

        return (segment, fraction)
    }

    private func visualFraction(_ logical: Double) -> CGFloat {
        let clamped = min(max(logical, 0), 1)
        return CGFloat(readingDirection.isRightToLeft ? 1 - clamped : clamped)
    }
}
