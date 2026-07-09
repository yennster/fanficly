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
    /// Render embedded `<img>` tags as inline images (the "Show images in
    /// stories" setting). Off keeps the historical text-only rendering.
    var showImages: Bool = false

    @State private var paragraphs: [AttributedString]?

    /// `.task(id:)` key — re-converts when the chapter or the images setting
    /// changes (the two settings produce different paragraph arrays).
    private struct ContentKey: Equatable {
        let html: String
        let showImages: Bool
    }

    /// Position is sampled every N paragraphs — enough for "resume where you
    /// left off" without a GeometryReader on every paragraph (which made
    /// scrolling stutter).
    static let anchorStride = 6

    /// Whether paragraph `index` of `count` carries a scroll-anchor reporter:
    /// every `anchorStride`-th one, plus always the final paragraph. Without
    /// the final anchor the end of a chapter is invisible to progress
    /// tracking, so a work read to the last line could never reach 100%
    /// (see `ChapterTracking.endOfContentAnchor`).
    static func isAnchorIndex(_ index: Int, count: Int) -> Bool {
        index % anchorStride == 0 || index == count - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: paragraphSpacing) {
            if let paragraphs {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, para in
                    Group {
                        if let imageURL = HTMLToAttributed.imageAttachmentURL(in: para) {
                            // An image slot occupies a paragraph index (so
                            // anchors and TTS stay aligned) but renders as an
                            // image, not text. No karaoke highlight — it's
                            // never spoken.
                            ReaderInlineImage(url: imageURL)
                        } else {
                            Text(para)
                                .font(font)
                                .tracking(kerning)
                                .bold(boldText)
                                .lineSpacing(lineSpacing)
                                .foregroundStyle(foreground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Karaoke highlight: a flush fill behind the paragraph's
                                // existing frame, so toggling it never reflows the text.
                                .background(
                                    highlightParagraph == index ? Color.accentColor.opacity(0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                                .animation(.easeInOut(duration: 0.2), value: highlightParagraph == index)
                        }
                    }
                    .id(ChapterTracking.key(chapter: chapterIndex, paragraph: index))
                    .background {
                        if Self.isAnchorIndex(index, count: paragraphs.count) {
                            anchorReporter(paragraph: index)
                        }
                    }
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
        .task(id: ContentKey(html: html, showImages: showImages)) {
            let include = showImages
            let result = await Task.detached(priority: .userInitiated) {
                HTMLToAttributed.convertParagraphs(html, includeImages: include)
            }.value
            // The detached conversion doesn't observe cancellation, so a
            // rapid setting flip could land results out of order — drop any
            // result whose task(id:) has already been superseded.
            guard !Task.isCancelled else { return }
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

/// One embedded story image (the opt-in "Show images in stories" setting).
/// Loads via AsyncImage — images live on external hosts, not AO3, so they
/// don't go through the AO3 throttle. Not saved with downloaded works
/// (offline reading stays text-only), though the system URL cache may keep
/// recently viewed images temporarily.
struct ReaderInlineImage: View {
    let url: URL

    /// Every image slot occupies exactly this height, in every reading mode.
    /// Page-by-page measures page layouts up front, and the flowing modes
    /// restore a saved scroll position right away — if a slot grew when its
    /// image finished loading, everything below would shift, shoving the
    /// restored paragraph off-screen and letting the anchor sampler silently
    /// regress saved progress. A fixed slot makes loading layout-neutral.
    static let slotHeight: CGFloat = 240

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            case .failure:
                Label("Image unavailable", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .empty:
                ProgressView()
            @unknown default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.slotHeight)
        .accessibilityLabel("Story image")
    }
}
