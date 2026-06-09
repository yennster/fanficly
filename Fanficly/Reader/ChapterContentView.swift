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
    /// Letter spacing (kerning) in points, already divided by the UI zoom.
    let kerning: CGFloat
    /// Render all body text bold.
    let boldText: Bool
    /// Paragraph index to emphasise while it's being read aloud (TTS karaoke),
    /// or nil when this chapter isn't the one narrating.
    var highlightParagraph: Int? = nil

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
                        .tracking(kerning)
                        .bold(boldText)
                        .lineSpacing(lineSpacing)
                        .foregroundStyle(foreground)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Karaoke highlight: a flush fill behind the paragraph's
                        // existing frame, so toggling it never reflows the text.
                        .background(
                            highlightParagraph == index ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .id(ChapterTracking.key(chapter: chapterIndex, paragraph: index))
                        .background {
                            if index % anchorStride == 0 {
                                anchorReporter(paragraph: index)
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: highlightParagraph == index)
                }
            } else {
                Text(plainFallback)
                    .font(font)
                    .tracking(kerning)
                    .bold(boldText)
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
