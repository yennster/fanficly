import SwiftUI
import SwiftData
import UIKit

struct LibraryRow: View {
    let work: Work
    let downloaded: Bool
    @AppStorage("library.showReadingProgress") private var showReadingProgress = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// At accessibility text sizes, lines that clip to one get room to wrap.
    private var isLargeText: Bool { dynamicTypeSize.isAccessibilitySize }

    /// Show the first fandom, shortened from AO3's canonical form
    /// ("Harry Potter - J. K. Rowling" → "Harry Potter"), plus a count
    /// if the work spans more than one.
    private var fandomLabel: String {
        guard let first = work.fandoms.first else { return "" }
        let short = first.components(separatedBy: " - ").first ?? first
        let extra = work.fandoms.count - 1
        return extra > 0 ? "\(short)  +\(extra)" : short
    }

    private var metadataItems: [String] {
        var items = [work.rating]
        if work.wordCount > 0 {
            items.append("\(work.wordCount.formatted()) words")
        }
        if let total = work.totalChapters {
            items.append(work.chapterCount == total ? "\(total) ch complete" : "\(work.chapterCount)/\(total) WIP")
        } else if work.chapterCount > 0 {
            // WIP whose author hasn't declared a final chapter count (AO3 shows
            // "12/?"). Still surface progress here, mirroring the search row and
            // reader header — otherwise the chapter/WIP badge silently vanishes.
            items.append("\(work.chapterCount)/? WIP")
        }
        for folder in work.folders.sorted(by: { $0.name < $1.name }) {
            items.append(folder.name)
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(work.title)
                    .font(.headline)
                    .lineLimit(isLargeText ? 5 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                LibraryStatusBadges(
                    pinned: work.isPinned,
                    starred: work.isStarred,
                    downloaded: downloaded
                )
            }
            Text("by \(work.authorName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(isLargeText ? 3 : 1)
            if let firstFandom = work.fandoms.first {
                HStack(spacing: 4) {
                    Image(systemName: FandomCatalog.symbol(for: firstFandom)).font(.caption2)
                        .accessibilityHidden(true)
                    Text(fandomLabel).font(.caption)
                }
                .foregroundStyle(.secondary)
                .lineLimit(isLargeText ? 3 : 1)
            }

            FlowLayout(spacing: 6, lineSpacing: 5) {
                ForEach(metadataItems, id: \.self) { item in
                    let isFolder = work.folders.contains(where: { $0.name == item })
                    LibraryMetadataPill(text: item, isFolder: isFolder)
                }
                ForEach(work.personalTags, id: \.self) { tag in
                    LibraryMetadataPill(text: tag, isPersonalTag: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Your tag: \(tag)")
                }
            }

            if let note = work.note, !note.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "note.text")
                        .accessibilityHidden(true)
                    Text(note)
                        .lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Your note: \(note)")
            }

            if showReadingProgress {
                readingProgress
            }
        }
        .padding(.vertical, 6)
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
        // One VoiceOver element per row; swipe actions/context menus are unaffected.
        .accessibilityElement(children: .combine)
    }

    /// Reading-progress strip: a bar plus a "% read · Ch n · last read …" line,
    /// shown for any work the user has started. Finished works read "Finished"
    /// instead of a near-full bar.
    @ViewBuilder
    private var readingProgress: some View {
        if let raw = work.lastReadProgress, raw > 0 {
            let progress = min(max(raw, 0), 1)
            let finished = progress >= 0.99 || (work.isComplete && progress >= 0.95)
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: progress)
                    .tint(finished ? .green : .accentColor)
                    .scaleEffect(x: 1, y: 0.7, anchor: .center)
                // Stacked at accessibility sizes: one line truncated the date.
                let stripLayout = isLargeText
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(spacing: 6))
                stripLayout {
                    if finished {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .accessibilityHidden(true)
                            Text("Finished")
                        }
                        .foregroundStyle(.green)
                    } else {
                        Text("\(Int(progress * 100))% read")
                        if let chapter = work.lastReadChapter, (work.totalChapters ?? 0) > 1 {
                            Text("· Ch \(chapter)")
                        }
                    }
                    if !isLargeText { Spacer(minLength: 4) }
                    if let lastReadAt = work.lastReadAt {
                        Text(lastReadAt, format: .relative(presentation: .named))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(isLargeText ? 2 : 1)
            }
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(progressAccessibilityLabel(progress: progress, finished: finished))
        }
    }

    /// Mirrors the visible strip: percent (or Finished), chapter reached, last-read date.
    private func progressAccessibilityLabel(progress: Double, finished: Bool) -> String {
        var parts = [finished ? "Finished reading" : "\(Int(progress * 100)) percent read"]
        if !finished, let chapter = work.lastReadChapter, (work.totalChapters ?? 0) > 1 {
            parts.append("chapter \(chapter)")
        }
        if let lastReadAt = work.lastReadAt {
            parts.append("last read \(lastReadAt.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: ", ")
    }
}

private struct LibraryStatusBadges: View {
    let pinned: Bool
    let starred: Bool
    let downloaded: Bool

    var body: some View {
        HStack(spacing: 5) {
            if pinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Pinned")
            }
            if starred {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Starred")
            }
            if downloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Downloaded")
            }
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryMetadataPill: View {
    let text: String
    var isFolder = false
    var isPersonalTag = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 4) {
            if isFolder {
                Image(systemName: "folder")
                    .font(.caption2)
                    .accessibilityHidden(true)
            } else if isPersonalTag {
                Image(systemName: "tag")
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        }
        .font(.caption2)
        .foregroundStyle(isFolder ? Color.accentColor : isPersonalTag ? Color.purple : .secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            // A rounded rectangle, not a Capsule: a capsule's semicircular left
            // cap only touches the leading edge at its vertical center, so the
            // pill reads as inset from the flush title/author text. A near-
            // vertical left edge lines the pills up with the text.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isFolder ? Color.accentColor.opacity(0.12)
                      : isPersonalTag ? Color.purple.opacity(0.12)
                      : Color(.tertiarySystemFill))
        }
    }
}
