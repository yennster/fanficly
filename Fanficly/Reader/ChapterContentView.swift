import SwiftUI

/// Renders one chapter as individual paragraphs, each a scroll anchor
/// ("c<chapter>-p<index>") so the reader can restore the exact position.
struct ChapterContentView: View {
    let chapterIndex: Int
    let html: String
    let font: Font
    let lineSpacing: CGFloat
    let foreground: Color
    let scrollSpace: String

    @State private var paragraphs: [AttributedString]?

    var body: some View {
        VStack(alignment: .leading, spacing: lineSpacing + 8) {
            if let paragraphs {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, para in
                    Text(para)
                        .font(font)
                        .lineSpacing(lineSpacing)
                        .foregroundStyle(foreground)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(ChapterTracking.key(chapter: chapterIndex, paragraph: index))
                        .background(anchorReporter(paragraph: index))
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
