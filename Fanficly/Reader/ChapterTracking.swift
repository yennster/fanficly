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
}
