import SwiftUI
import AppKit

/// Disk Utility for the configured local library.
struct StorageView: View {
    @State private var utility = StorageUtility.shared
    @State private var sort: StorageSort = .size
    @State private var pendingDelete: StorageComic?

    private enum StorageSort: String, CaseIterable, Identifiable {
        case size
        case title
        case series

        var id: String { rawValue }

        var label: String {
            switch self {
            case .size: return "Size"
            case .title: return "Title"
            case .series: return "Series"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let error = utility.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if utility.isScanning {
                ProgressView("Scanning library…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else if let report = utility.report {
                summary(report)
                Divider()
                comicList(report)
            } else {
                ContentUnavailableView(
                    "Storage has not been scanned",
                    systemImage: "internaldrive",
                    description: Text("Scan your library to calculate the disk usage of each comic.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .task {
            if utility.report == nil {
                utility.scan()
            }
        }
        .alert(item: $pendingDelete) { item in
            Alert(
                title: Text("Move “\(item.title)” to the Trash?"),
                message: Text("\(item.displaySize) will be removed from the library and moved to the Trash. Reading state will also be removed."),
                primaryButton: .cancel(),
                secondaryButton: .destructive(Text("Move to Trash")) {
                    _ = utility.delete(item)
                }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Library Storage")
                    .font(.headline)
                Text("Disk usage for the comics currently in your local library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Sort", selection: $sort) {
                ForEach(StorageSort.allCases) {
                    Text($0.label).tag($0)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 110)

            Button {
                utility.scan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(utility.isScanning)
            .pointingHandCursor()
        }
    }

    @ViewBuilder
    private func summary(_ report: StorageReport) -> some View {
        HStack(spacing: 10) {
            metric("Library", ByteCountFormatter.string(
                fromByteCount: report.totalBytes,
                countStyle: .file
            ))
            metric("Comics", "\(report.comics.count)")

            if report.freeBytes != nil, report.totalDiskBytes != nil {
                Text("Free space is reported for the first configured library volume.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let free = report.freeBytes {
                metric("Free", ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
            }

            if let total = report.totalDiskBytes {
                metric("Disk", ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
            }

            Spacer()
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func comicList(_ report: StorageReport) -> some View {
        let groups = grouped(report.comics)

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(groups) { group in
                    DisclosureGroup {
                        ForEach(group.comics) { item in
                            storageRow(item)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "books.vertical")
                                .foregroundStyle(.secondary)
                            Text(group.series)
                                .font(.body.weight(.semibold))
                            Spacer()
                            Text(ByteCountFormatter.string(
                                fromByteCount: group.bytes,
                                countStyle: .file
                            ))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            Text("\(group.comics.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 28, alignment: .trailing)
                        }
                        .padding(.vertical, 4)
                    }
                    .padding(.horizontal, 4)
                    .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if report.comics.isEmpty {
                ContentUnavailableView(
                    "No local comics",
                    systemImage: "books.vertical",
                    description: Text("Add a local library folder and scan again.")
                )
            }
        }
    }

    private func storageRow(_ item: StorageComic) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isArchive ? "doc.zipper" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                Text(item.url.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(item.displaySize)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .pointingHandCursor()

            Button(role: .destructive) {
                pendingDelete = item
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Move to Trash")
            .pointingHandCursor()
        }
        .padding(.leading, 24)
        .padding(.vertical, 4)
    }

    private struct SeriesGroup: Identifiable {
        let series: String
        let comics: [StorageComic]
        let bytes: Int64

        var id: String { series }
    }

    private func grouped(_ comics: [StorageComic]) -> [SeriesGroup] {
        let buckets = Dictionary(grouping: comics, by: { $0.series })

        return buckets.map { series, values in
            let sorted: [StorageComic]
            switch sort {
            case .size:
                sorted = values.sorted {
                    if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            case .title:
                sorted = values.sorted {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            case .series:
                sorted = values.sorted {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            }

            return SeriesGroup(
                series: series,
                comics: sorted,
                bytes: values.reduce(Int64(0)) { $0 + $1.bytes }
            )
        }
        .sorted {
            switch sort {
            case .size:
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return $0.series.localizedStandardCompare($1.series) == .orderedAscending
            case .title, .series:
                return $0.series.localizedStandardCompare($1.series) == .orderedAscending
            }
        }
    }
}
