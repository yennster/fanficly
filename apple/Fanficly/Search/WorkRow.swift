import SwiftUI
import SwiftData

struct WorkRow: View {
    let work: AO3WorkSummary
    /// "In Library", "Finished" or a percent, from the list's one lookup per
    /// page (`.resultBadges(for:into:)`).
    var badge: ResultBadge? = nil
    /// Recently Viewed hides the button for an old entry it knows too little
    /// about to save.
    var showsBookmark = true
    @Environment(\.modelContext) private var context
    @Environment(\.readingWordsPerMinute) private var wordsPerMinute
    // Reflects the local follow ("bookmark") state; seeded on appear and
    // updated when the inline button is tapped.
    @State private var isFollowed = false
    // Saving from the inline button puts the work in the Library before the
    // list's next lookup.
    @State private var savedHere = false

    private var shownBadge: ResultBadge? {
        badge ?? (savedHere ? .inLibrary : nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(work.title).font(.headline)
                    if let shownBadge {
                        ResultBadgeView(badge: shownBadge)
                    }
                }
                Text("by \(work.author)").font(.subheadline).foregroundStyle(.secondary)
                // Wraps rather than truncating once the reading-time estimate
                // joins the row on a narrow phone.
                FlowLayout(spacing: 8, lineSpacing: 2) {
                    if !work.rating.isEmpty {
                        Text(work.rating).font(.caption).foregroundStyle(.secondary)
                    }
                    if work.wordCount > 0 {
                        Text("\(work.wordCount.formatted()) words").font(.caption).foregroundStyle(.secondary)
                    }
                    if let estimate = ReadingSpeed.estimate(words: work.wordCount, wordsPerMinute: wordsPerMinute) {
                        Text(estimate).font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel(ReadingSpeed.spokenEstimate(words: work.wordCount, wordsPerMinute: wordsPerMinute) ?? estimate)
                    }
                    if work.totalChapters != nil {
                        Text("\(work.chapterCount)/\(work.totalChapters!)").font(.caption).foregroundStyle(.secondary)
                    } else if work.chapterCount > 0 {
                        Text("\(work.chapterCount)/?").font(.caption).foregroundStyle(.secondary)
                    }
                    if work.kudos > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "heart")
                                .accessibilityHidden(true)
                            Text(work.kudos.formatted())
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                if !work.summary.isEmpty {
                    Text(work.summary).font(.callout).lineLimit(3).foregroundStyle(.primary)
                }
            }
            // Combine only the text stack, so the inline bookmark button stays
            // its own focusable element.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if showsBookmark {
                bookmarkButton
            }
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
        .onAppear { isFollowed = WorkPersistence.isFollowed(workId: work.id, in: context) }
    }

    /// Inline one-tap follow/unfollow, so a story can be saved to the Library
    /// straight from a results list without opening it. `.borderless` keeps the
    /// tap from also triggering the row's NavigationLink.
    private var bookmarkButton: some View {
        Button {
            let newState = WorkPersistence.toggleFollow(summary: work, into: context)
            withAnimation(.easeInOut(duration: 0.2)) {
                isFollowed = newState
                savedHere = true  // toggling creates the Work; unfollowing keeps it
            }
        } label: {
            Image(systemName: isFollowed ? "bookmark.fill" : "bookmark")
                .font(.body)
                .foregroundStyle(isFollowed ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .padding(.vertical, 4)
                .padding(.leading, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isFollowed ? "Remove \(work.title) from Library"
                                       : "Save \(work.title) to Library")
    }
}

/// The small capsule a result row shows for a work already read or saved.
/// It sits inside the row's combined text element, so VoiceOver reads its
/// label as part of the row.
struct ResultBadgeView: View {
    let badge: ResultBadge

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: badge.symbol)
                .accessibilityHidden(true)
            Text(badge.text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.accessibilityLabel)
    }

    private var tint: Color {
        badge == .finished ? .green : .accentColor
    }
}

extension View {
    /// Keeps `badges` current for a results list: one lookup for the whole
    /// page when the results change, and again when the list reappears
    /// (back from reading a story).
    func resultBadges(for works: [AO3WorkSummary], into badges: Binding<[Int: ResultBadge]>) -> some View {
        modifier(ResultBadgesModifier(works: works, badges: badges))
    }
}

private struct ResultBadgesModifier: ViewModifier {
    let works: [AO3WorkSummary]
    @Binding var badges: [Int: ResultBadge]
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content
            .onAppear(perform: refresh)
            .onChange(of: works.map(\.id)) { refresh() }
    }

    private func refresh() {
        badges = WorkPersistence.resultBadges(for: works, in: context)
    }
}

struct ChipView: View {
    enum Kind { case include, exclude }
    let text: String
    let kind: Kind
    var removable: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            if removable {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(0.6)
                    .accessibilityHidden(true)
            }
        }
        .font(.caption)
        .padding(.leading, 10)
        .padding(.trailing, removable ? 8 : 10)
        .padding(.vertical, 5)
        .background(background)
        .foregroundStyle(foreground)
        .clipShape(Capsule())
    }

    private var background: Color {
        switch kind {
        case .include: Color.accentColor.opacity(0.18)
        case .exclude: Color.red.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch kind {
        case .include: Color.accentColor
        case .exclude: Color.red
        }
    }
}
