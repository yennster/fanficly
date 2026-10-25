import SwiftUI

struct ReaderPageCell: View {
    let page: ChapterPage
    let chapter: AO3ChapterPayload
    let atoms: [ParagraphAtom]
    let showTitleHeader: Bool
    let showChapterHeader: Bool
    let titleHeaderView: AnyView?
    let chapterHeaderView: AnyView
    
    let font: Font
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let kerning: CGFloat
    let boldText: Bool
    let foreground: Color
    let highlightParagraph: Int?

    private var renderedBlocks: [RenderedBlock] {
        var blocks: [RenderedBlock] = []
        let indices = Array(page.paragraphIndices)
        guard !indices.isEmpty else { return [] }
        
        var currentOriginalIndex = atoms[indices[0]].originalParagraphIndex
        var currentAtoms: [ParagraphAtom] = [atoms[indices[0]]]
        
        for index in indices.dropFirst() {
            if index < atoms.count {
                let atom = atoms[index]
                if atom.originalParagraphIndex == currentOriginalIndex {
                    currentAtoms.append(atom)
                } else {
                    blocks.append(RenderedBlock(
                        id: currentOriginalIndex,
                        originalParagraphIndex: currentOriginalIndex,
                        text: ReaderPageCell.concatenateAtoms(currentAtoms)
                    ))
                    currentOriginalIndex = atom.originalParagraphIndex
                    currentAtoms = [atom]
                }
            }
        }
        
        if !currentAtoms.isEmpty {
            blocks.append(RenderedBlock(
                id: currentOriginalIndex,
                originalParagraphIndex: currentOriginalIndex,
                text: ReaderPageCell.concatenateAtoms(currentAtoms)
            ))
        }
        
        return blocks
    }
    
    struct RenderedBlock: Identifiable {
        let id: Int
        let originalParagraphIndex: Int
        let text: AttributedString
    }
    
    static func concatenateAtoms(_ atoms: [ParagraphAtom]) -> AttributedString {
        var result = AttributedString()
        for (i, atom) in atoms.enumerated() {
            if i > 0 {
                let prevString = String(result.characters)
                let nextString = String(atom.text.characters)
                let needsSpace = !prevString.isEmpty && 
                                 !nextString.isEmpty && 
                                 !prevString.hasSuffix(" ") && 
                                 !prevString.hasSuffix("\n") && 
                                 !nextString.hasPrefix(" ") && 
                                 !nextString.hasPrefix("\n")
                if needsSpace {
                    result.append(AttributedString(" "))
                }
            }
            result.append(atom.text)
        }
        return result
    }
    
    var body: some View {
        // Always the ScrollView, even with the UI minimized: a bare VStack in
        // the fixed-height TabView page lets SwiftUI compress the paragraph
        // Texts whenever the paginator's boundingRect estimate under-measures
        // the rendered layout (worst on Mac Catalyst), which truncated
        // mid-page paragraphs to "…". basedOnSize keeps an exact-fit page
        // inert — it only scrolls when the page genuinely overflows.
        ScrollView(.vertical, showsIndicators: false) {
            pageContent
        }
        .scrollBounceBehavior(.basedOnSize)
    }
    
    /// The page as laid out inside its scroll view. Internal so
    /// ReaderPaginationTests can check SwiftUI draws pages within the height
    /// the paginator measured them for.
    var pageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showTitleHeader, let titleHeaderView {
                titleHeaderView
                    .padding(.bottom, Spacing.lg)
            }
            if showChapterHeader {
                chapterHeaderView
                    .padding(.bottom, Spacing.sm)
            }
            
            VStack(alignment: .leading, spacing: paragraphSpacing) {
                ForEach(renderedBlocks) { block in
                    if let imageURL = HTMLToAttributed.imageAttachmentURL(in: block.text) {
                        // Renders at ReaderInlineImage.slotHeight — the same
                        // height the paginator budgeted for this block.
                        ReaderInlineImage(url: imageURL)
                    } else {
                        Text(block.text)
                            .font(font)
                            .tracking(kerning)
                            .bold(boldText)
                            .lineSpacing(lineSpacing)
                            .foregroundStyle(foreground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Story text must never ellipsize: take the full
                            // ideal height even if a parent proposes less.
                            .fixedSize(horizontal: false, vertical: true)
                            .background(
                                highlightParagraph == block.originalParagraphIndex ? Color.accentColor.opacity(0.15) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
