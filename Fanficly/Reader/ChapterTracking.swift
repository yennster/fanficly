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

/// Reports the top offset of each paragraph (keyed "c<chapter>-p<para>")
/// so the reader can remember the exact reading position.
struct ScrollAnchorKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ReadingAnchor: Equatable {
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
