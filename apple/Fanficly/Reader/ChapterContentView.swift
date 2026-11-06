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
        // Per-phase labels: a container-wide "Story image" would override the
        // loading and "Image unavailable" states for VoiceOver.
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Story image")
            case .failure:
                Label("Image unavailable", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .empty:
                ProgressView()
                    .accessibilityLabel("Story image, loading")
            @unknown default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.slotHeight)
    }
}

// MARK: - Author's notes (#181)

/// One labeled part of a chapter's notes: its summary, the author's notes
/// before it, or their notes after it.
struct ReaderNote: Identifiable, Equatable {
    enum Kind: String { case summary, notes, endNotes }
    let kind: Kind
    let html: String
    var id: String { kind.rawValue }

    var label: LocalizedStringKey {
        switch kind {
        case .summary: "Chapter Summary"
        case .notes: "Notes"
        case .endNotes: "End Notes"
        }
    }
}

extension AO3ChapterPayload {
    /// What AO3 shows before the chapter text: its summary and notes.
    var notesBefore: [ReaderNote] {
        [summaryHTML.map { ReaderNote(kind: .summary, html: $0) },
         notesHTML.map { ReaderNote(kind: .notes, html: $0) }].compactMap { $0 }
    }

    /// What AO3 shows after the chapter text: its end notes.
    var notesAfter: [ReaderNote] {
        endNotesHTML.map { [ReaderNote(kind: .endNotes, html: $0)] } ?? []
    }
}

/// The labeled notes, each rendered from its HTML in the reader's colors.
struct ReaderNotesContent: View {
    let notes: [ReaderNote]
    let foreground: Color
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if notes.count > 1 {
                        Text(note.label)
                            .font(.caption.smallCaps())
                            .foregroundStyle(foreground.opacity(0.55))
                    }
                    HTMLText(html: note.html)
                        .font(font)
                        .foregroundStyle(foreground.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A collapsed, themed "Notes" section shown before or after a chapter in the
/// scrolling reading modes. It sits outside `ChapterContentView`, so it never
/// adds a paragraph: positions, progress and Listen count only story text.
struct ReaderNotesDisclosure: View {
    let title: LocalizedStringKey
    let notes: [ReaderNote]
    let foreground: Color
    let font: Font
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "note.text")
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(foreground.opacity(0.75))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint(isExpanded ? Text("Hides the author's notes.") : Text("Shows the author's notes."))
            .accessibilityIdentifier("reader.notes")

            if isExpanded {
                ReaderNotesContent(notes: notes, foreground: foreground, font: font)
            }
        }
        .padding(Spacing.md)
        .background(foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Page-by-page mode's "Notes" button, on the chapter's first page. Expanding
/// notes inline would push text off a page the paginator already measured,
/// so the button has a fixed height (`height`, budgeted by
/// `ReaderPaginator.estimateChapterHeaderHeight`) and opens a sheet with all
/// of the chapter's notes.
struct ReaderNotesButton: View {
    nonisolated static let height: CGFloat = 32

    let chapter: AO3ChapterPayload
    /// The sheet's title.
    let title: Text
    let foreground: Color
    let background: Color
    /// The reader theme's scheme, so the sheet's bars match its colors.
    let colorScheme: ColorScheme
    let font: Font
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "note.text")
                    .accessibilityHidden(true)
                Text("Notes")
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground.opacity(0.75))
            .padding(.horizontal, Spacing.md)
            .frame(height: Self.height)
            .background(foreground.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityHint(Text("Shows the author's notes for this chapter."))
        .accessibilityIdentifier("reader.notes")
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                ScrollView {
                    ReaderNotesContent(notes: chapter.notesBefore + chapter.notesAfter,
                                       foreground: foreground, font: font)
                        .padding()
                }
                .background(background)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                // Never `.preferredColorScheme`: it reaches the whole window
                // and would flip the app when the sheet closes.
                .toolbarBackground(background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(colorScheme, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isPresented = false }
                    }
                }
            }
            .environment(\.colorScheme, colorScheme)
            .presentationBackground(background)
            .presentationDetents([.medium, .large])
        }
    }
}
