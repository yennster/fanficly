import SwiftUI

/// Reports the top offset of each chapter within the reader scroll view,
/// so the reader can show which chapter is currently on screen.
struct ChapterOffsetKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] { [:] }
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    /// Tag a chapter block so its top offset is reported in the named space.
    func trackChapterOffset(index: Int, in space: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ChapterOffsetKey.self,
                    value: [index: geo.frame(in: .named(space)).minY]
                )
            }
        )
    }
}

/// Whether the reader is in full screen (its controls hidden), so the
/// screen hosting it (`WorkDetailView`, `SavedWorkReader`) can drop its own
/// toolbar items: full screen leaves nothing on screen but the page.
struct ReaderFullScreenKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Whether the status bar is hidden, for the reader's full screen. RootView
/// hides it: `.statusBarHidden` on the reader did nothing, as it sits in the
/// NavigationSplitView's detail stack, which doesn't pass it up, and the
/// clock stayed on screen in full screen (over the text on iPhone Duo).
@MainActor @Observable
final class StatusBarVisibility {
    var hidden = false
}

/// Reports the top offset of each paragraph (keyed "c<chapter>-p<para>")
/// so the reader can remember the exact reading position.
struct ScrollAnchorKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ReadingAnchor: Equatable, Hashable {
    let chapter: Int
    let paragraph: Int
}

extension ChapterTracking {
    /// The topmost paragraph anchor currently at/above the threshold line.
    static func topmostAnchor(_ offsets: [String: CGFloat], threshold: CGFloat = 80) -> ReadingAnchor? {
        let passed = offsets.filter { $0.value <= threshold }
        let pick = passed.max(by: { $0.value < $1.value })
            ?? offsets.min(by: { $0.value < $1.value })
        guard let key = pick?.key else { return nil }
        return parse(key)
    }

    /// The final paragraph's anchor when the very end of the content is on
    /// screen — its top edge has entered the viewport — else nil. Topmost-anchor
    /// sampling alone can never report the true end: fully scrolled down, the
    /// last paragraphs sit *below* the viewport top, so progress tops out a
    /// screenful short of 100% and a finished work never earns its badge.
    static func endOfContentAnchor(_ offsets: [String: CGFloat],
                                   lastChapter: Int, lastParagraph: Int,
                                   viewportHeight: CGFloat) -> ReadingAnchor? {
        guard lastParagraph >= 0,
              let top = offsets[key(chapter: lastChapter, paragraph: lastParagraph)],
              top <= viewportHeight else { return nil }
        return ReadingAnchor(chapter: lastChapter, paragraph: lastParagraph)
    }

    /// `anchor` moved onto the chapters actually loaded (`order`, their
    /// indices), or nil when none are. A saved position can point past them:
    /// new-chapter notifications open the live work, so you can save a place
    /// in chapter 13 while the downloaded copy stops at 12. An anchor in a
    /// chapter that isn't loaded lands on the last paragraph of the nearest
    /// loaded chapter before it (the first chapter's top when there's none),
    /// so every mode has a chapter to show. `lastParagraph` gives a loaded
    /// chapter's final paragraph index.
    static func clampedAnchor(_ anchor: ReadingAnchor, toChapters order: [Int],
                              lastParagraph: (Int) -> Int) -> ReadingAnchor? {
        let sorted = order.sorted()
        guard let first = sorted.first else { return nil }
        if sorted.contains(anchor.chapter) { return anchor }
        guard let before = sorted.last(where: { $0 < anchor.chapter }) else {
            return ReadingAnchor(chapter: first, paragraph: 0)
        }
        return ReadingAnchor(chapter: before, paragraph: max(lastParagraph(before), 0))
    }

    /// How far through the loaded chapters (`order`) `anchor` is, 0…1: whole
    /// chapters before it plus the fraction of its chapter's paragraphs
    /// (`paragraphCount`). Nil when its chapter isn't loaded, since there's
    /// nothing to measure it against; reading that as 0 would overwrite the
    /// real progress.
    static func progressFraction(for anchor: ReadingAnchor, chapters order: [Int],
                                 paragraphCount: (Int) -> Int) -> Double? {
        let sorted = order.sorted()
        guard let chapterOffset = sorted.firstIndex(of: anchor.chapter) else { return nil }
        let count = max(paragraphCount(anchor.chapter), 1)
        let denominator = max(count - 1, 1)
        let paragraphProgress = min(max(Double(anchor.paragraph) / Double(denominator), 0), 1)
        let rawProgress = (Double(chapterOffset) + paragraphProgress) / Double(sorted.count)
        return min(max(rawProgress, 0), 1)
    }

    static func parse(_ key: String) -> ReadingAnchor? {
        // "c12-p3"
        let parts = key.dropFirst().split(separator: "-p")
        guard parts.count == 2, let c = Int(parts[0]), let p = Int(parts[1]) else { return nil }
        return ReadingAnchor(chapter: c, paragraph: p)
    }

    static func key(chapter: Int, paragraph: Int) -> String { "c\(chapter)-p\(paragraph)" }
}

enum ChapterTracking {
    /// Given each chapter's top offset (in scroll-content coordinates),
    /// return the index of the chapter currently at the top of the viewport.
    /// That's the chapter with the greatest offset still at/above the
    /// threshold line just below the navigation bar.
    static func currentChapter(offsets: [Int: CGFloat], threshold: CGFloat = 80) -> Int? {
        // Index 0 is the title header — exclude it from chapter selection.
        let chapters = offsets.filter { $0.key >= 1 }
        let passed = chapters.filter { $0.value <= threshold }
        if let top = passed.max(by: { $0.value < $1.value }) {
            return top.key
        }
        // Nothing has scrolled past yet — we're in the first chapter.
        return chapters.min(by: { $0.value < $1.value })?.key
    }

    /// The chapter index one step before/after `current` within `order`
    /// (the chapter indices in reading order), or `nil` at the ends or when
    /// `current` isn't found. Used by the reader's tap-to-turn page zones.
    static func adjacentChapter(in order: [Int], current: Int, forward: Bool) -> Int? {
        guard let pos = order.firstIndex(of: current) else { return nil }
        let target = forward ? pos + 1 : pos - 1
        guard order.indices.contains(target) else { return nil }
        return order[target]
    }
}
