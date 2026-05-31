import SwiftUI

/// Renders one chapter as individual paragraphs, each a scroll anchor
/// ("c<chapter>-p<index>") so the reader can restore the exact position.
struct ChapterContentView: View {
    let chapterIndex: Int
    let html: String
    let font: Font
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let foreground: Color
    let scrollSpace: String

    @State private var paragraphs: [AttributedString]?

    /// Position is sampled every N paragraphs — enough for "resume where you
    /// left off" without a GeometryReader on every paragraph (which made
    /// scrolling stutter).
    private let anchorStride = 6

    var body: some View {
        VStack(alignment: .leading, spacing: paragraphSpacing) {
            if let paragraphs {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, para in
                    Text(para)
                        .font(font)
                        .lineSpacing(lineSpacing)
                        .foregroundStyle(foreground)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(ChapterTracking.key(chapter: chapterIndex, paragraph: index))
                        .background {
                            if index % anchorStride == 0 {
                                anchorReporter(paragraph: index)
                            }
                        }
                }
            } else {
                Text(plainFallback)
                    .font(font)
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(foreground)
            }
        }
        .task(id: html) {
            let result = await Task.detached(priority: .userInitiated) {
                HTMLToAttributed.convertParagraphs(html)
            }.value
            await MainActor.run { paragraphs = result }
        }
    }

    private func anchorReporter(paragraph: Int) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ScrollAnchorKey.self,
                value: [ChapterTracking.key(chapter: chapterIndex, paragraph: paragraph): geo.frame(in: .named(scrollSpace)).minY]
            )
        }
    }

    private var plainFallback: String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
