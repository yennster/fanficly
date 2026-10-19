import SwiftUI

struct ChapterPage: Identifiable, Hashable {
    let id: String
    let chapterIndex: Int
    let pageIndex: Int
    let paragraphIndices: Range<Int>
    /// A two-page spread opens on this page: the page a re-pagination kept
    /// in place (see PageStart), when pairing from the chapter's start would
    /// put it on the right.
    var startsSpread = false
}

/// Where a page's text begins, in terms that survive re-paginating: the
/// paragraph, the sentence in it, and the character offset into that
/// sentence (a page can start mid-sentence). Re-paginating breaks a page
/// exactly here, so the page on screen keeps its first line.
struct PageStart: Equatable {
    let chapter: Int
    let paragraph: Int
    let sentence: Int
    let offset: Int
}

struct ParagraphAtom: Identifiable, Hashable {
    let id = UUID()
    let originalParagraphIndex: Int
    let text: AttributedString
    let isContinuation: Bool
    /// The sentence this atom comes from, and where in it the atom starts
    /// (the rest of a sentence split across pages starts past 0). See PageStart.
    var sentenceIndex = 0
    var sentenceOffset = 0

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: ParagraphAtom, rhs: ParagraphAtom) -> Bool {
        lhs.id == rhs.id
    }
}

struct PaginationResult {
    let pages: [ChapterPage]
    let atoms: [Int: [ParagraphAtom]]
    /// The page kept in place, when pagination started from a PageStart.
    var keptPageId: String? = nil
}

/// Page-by-page's pagination: splits chapters into pages that fit a page
/// area. Pure (no view state), so it's unit-tested across device sizes and
/// reader settings (ReaderPaginationTests). Main-actor like the reader that
/// runs it: it measures with ReaderPageCell's own helpers.
@MainActor
enum ReaderPaginator {
    /// A chapter's paragraphs as sentence atoms, the unit pages are packed in.
    /// `includeImages` must match the reader's images setting, or paragraph
    /// indices drift between modes.
    static func atoms(fromChapterHTML html: String, includeImages: Bool) -> [ParagraphAtom] {
        let paragraphs = HTMLToAttributed.convertParagraphs(html, includeImages: includeImages)
        var atoms: [ParagraphAtom] = []
        for (pIndex, para) in paragraphs.enumerated() {
            let sentences = HTMLToAttributed.splitIntoSentences(para)
            for (sIndex, sentence) in sentences.enumerated() {
                atoms.append(ParagraphAtom(
                    originalParagraphIndex: pIndex,
                    text: sentence,
                    isContinuation: sIndex > 0,
                    sentenceIndex: sIndex
                ))
            }
        }
        return atoms
    }

    /// Where `page`'s text begins, given its chapter's atoms (nil for the
    /// work's title page).
    static func start(of page: ChapterPage, atoms: [ParagraphAtom]) -> PageStart? {
        guard !page.paragraphIndices.isEmpty, page.paragraphIndices.lowerBound < atoms.count else { return nil }
        let atom = atoms[page.paragraphIndices.lowerBound]
        return PageStart(chapter: page.chapterIndex, paragraph: atom.originalParagraphIndex,
                         sentence: atom.sentenceIndex, offset: atom.sentenceOffset)
    }

    /// Splits `atom` (a sentence) so its first part, laid out after `leading`
    /// (atoms of the same paragraph already on the page), fits in `budget`.
    /// It keeps the longest run of whole words that fits, which is exactly
    /// where a line ends, so the page fills to its last line and the sentence
    /// carries on at the top of the next one, like a printed book. Returns nil
    /// when not even one word fits, or for an image slot.
    static func splitAtomToFit(_ atom: ParagraphAtom, after leading: [ParagraphAtom], budget: CGFloat,
                                measure: (AttributedString) -> CGFloat) -> (ParagraphAtom, ParagraphAtom)? {
        guard HTMLToAttributed.imageAttachmentURL(in: atom.text) == nil else { return nil }
        let chars = Array(atom.text.characters)
        // Candidate break points: just before each space (the space is dropped).
        let breaks = chars.indices.filter { chars[$0] == " " && $0 > 0 }
        guard !breaks.isEmpty else { return nil }
        func head(_ k: Int) -> AttributedString {
            let end = atom.text.characters.index(atom.text.startIndex, offsetBy: breaks[k])
            return AttributedString(atom.text[atom.text.startIndex..<end])
        }
        func fits(_ k: Int) -> Bool {
            let part = ParagraphAtom(originalParagraphIndex: atom.originalParagraphIndex, text: head(k),
                                     isContinuation: atom.isContinuation)
            return measure(ReaderPageCell.concatenateAtoms(leading + [part])) <= budget
        }
        guard fits(0) else { return nil }
        var lo = 0, hi = breaks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(mid) { lo = mid } else { hi = mid - 1 }
        }
        return splitAtom(atom, at: breaks[lo] + 1)
    }

    /// Splits `atom` so its second part starts at character `k`; a space
    /// just before `k` is dropped, as at a line end. Nil when either part
    /// would be empty.
    static func splitAtom(_ atom: ParagraphAtom, at k: Int) -> (ParagraphAtom, ParagraphAtom)? {
        let chars = Array(atom.text.characters)
        guard k > 0, k < chars.count else { return nil }
        let headEnd = chars[k - 1] == " " ? k - 1 : k
        guard headEnd > 0 else { return nil }
        let text = atom.text
        let head = AttributedString(text[text.startIndex..<text.characters.index(text.startIndex, offsetBy: headEnd)])
        let rest = AttributedString(text[text.characters.index(text.startIndex, offsetBy: k)...])
        return (ParagraphAtom(originalParagraphIndex: atom.originalParagraphIndex, text: head,
                              isContinuation: atom.isContinuation,
                              sentenceIndex: atom.sentenceIndex, sentenceOffset: atom.sentenceOffset),
                ParagraphAtom(originalParagraphIndex: atom.originalParagraphIndex, text: rest,
                              isContinuation: true,
                              sentenceIndex: atom.sentenceIndex, sentenceOffset: atom.sentenceOffset + k))
    }

    static func calculateHeight(
        for attributedString: AttributedString,
        width: CGFloat,
        fontSize: CGFloat,
        fontFamily: ReaderFontFamily,
        lineSpacing: CGFloat,
        kerning: CGFloat,
        boldText: Bool
    ) -> CGFloat {
        // An image slot renders as a fixed-height image cell, not text, so its
        // measured height is that fixed height — text measurement of the
        // placeholder character would badly under-count it.
        if HTMLToAttributed.imageAttachmentURL(in: attributedString) != nil {
            return ReaderInlineImage.slotHeight
        }
        let ns = NSAttributedString(attributedString)
        let mutableNs = NSMutableAttributedString(attributedString: ns)

        mutableNs.enumerateAttribute(.font, in: NSRange(location: 0, length: mutableNs.length), options: []) { value, range, _ in
            let originalFont = value as? UIFont ?? UIFont.systemFont(ofSize: fontSize)
            // `boldText` forces every run bold; bold glyphs are wider, so the
            // measurement must match the rendered `.bold()` or pages overflow.
            let isBold = boldText || originalFont.fontDescriptor.symbolicTraits.contains(.traitBold)
            let isItalic = originalFont.fontDescriptor.symbolicTraits.contains(.traitItalic)
            
            var targetFont = fontFamily.uiFont(size: fontSize)
            var traits = UIFontDescriptor.SymbolicTraits()
            if isBold { traits.insert(.traitBold) }
            if isItalic { traits.insert(.traitItalic) }
            if !traits.isEmpty {
                if let desc = targetFont.fontDescriptor.withSymbolicTraits(traits) {
                    targetFont = UIFont(descriptor: desc, size: fontSize)
                }
            }
            mutableNs.addAttribute(.font, value: targetFont, range: range)
        }
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        mutableNs.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: mutableNs.length))

        // Mirror the rendered `.tracking(kerning)`: wider tracking wraps sooner,
        // so the height estimate has to include it too.
        if kerning != 0 {
            mutableNs.addAttribute(.kern, value: kerning, range: NSRange(location: 0, length: mutableNs.length))
        }

        let constraintSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        let rect = mutableNs.boundingRect(with: constraintSize, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(rect.height)
    }

    static func estimateChapterHeaderHeight(
        title: String,
        width: CGFloat,
        fontSize: CGFloat,
        fontFamily: ReaderFontFamily
    ) -> CGFloat {
        var height: CGFloat = 42 + 15
        if !title.isEmpty {
            let titleFont = fontFamily.uiFont(size: fontSize + 5)
            let constraintSize = CGSize(width: width, height: .greatestFiniteMagnitude)
            let attrString = NSAttributedString(string: title, attributes: [.font: titleFont])
            let rect = attrString.boundingRect(with: constraintSize, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            height += ceil(rect.height) + 10
        }
        return height
    }

    static func estimateTitleHeaderHeight(
        title: String,
        author: String,
        authorUsername: String,
        summary: AO3WorkSummary?,
        width: CGFloat,
        fontSize: CGFloat,
        fontFamily: ReaderFontFamily
    ) -> CGFloat {
        var height: CGFloat = 0
        
        let titleFont = fontFamily.uiFont(size: fontSize + 14)
        let titleRect = NSAttributedString(string: title, attributes: [.font: titleFont])
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        height += ceil(titleRect.height) + 14
        
        if !author.isEmpty {
            let authorFont = UIFont.systemFont(ofSize: fontSize)
            let authorRect = NSAttributedString(string: "by \(author)", attributes: [.font: authorFont])
                .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            height += ceil(authorRect.height) + 14
        }
        
        height += 80

        // "Part N of <series> ›" per series (caption, up to two lines), and
        // "Next in series →" beside it or on a line of its own (SeriesPartRow).
        if let series = summary?.series, !series.isEmpty {
            let caption = UIFont.preferredFont(forTextStyle: .caption1)
            let line = ceil(caption.lineHeight)
            func size(_ text: String, _ maxWidth: CGFloat) -> CGSize {
                NSAttributedString(string: text, attributes: [.font: caption])
                    .boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
            }
            let icons: CGFloat = 36   // books + chevron symbols and their spacing
            for part in series {
                let label = size("Part \(part.position) of \(part.title)", max(1, width - icons))
                var rowHeight = min(ceil(label.height), line * 2)
                if part.nextWorkId != nil {
                    let next = ceil(size("Next in series", .greatestFiniteMagnitude).width) + 18
                    if ceil(label.width) + icons + 12 + next > width { rowHeight += 6 + line }
                }
                height += rowHeight + 10
            }
        }
        
        if let summary, !summary.summary.isEmpty {
            height += 15 + 4
            let plainSummary = summary.summary.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let summaryFont = fontFamily.uiFont(size: fontSize - 1)
            let summaryRect = NSAttributedString(string: plainSummary, attributes: [.font: summaryFont])
                .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            height += ceil(summaryRect.height) + 14
        }
        
        height += 10
        
        return height
    }

    static func paginateChapter(
        chapterIndex: Int,
        atoms: inout [ParagraphAtom],
        width: CGFloat,
        viewportHeight: CGFloat,
        titleHeaderHeight: CGFloat,
        chapterHeaderHeight: CGFloat,
        isFirstChapter: Bool,
        showChapterHeader: Bool,
        fontSize: CGFloat,
        fontFamily: ReaderFontFamily,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        kerning: CGFloat,
        boldText: Bool,
        drawnHeight: DrawnHeight? = nil,
        startingAt start: PageStart? = nil
    ) -> [ChapterPage] {
        var pages: [ChapterPage] = []

        var startIndex = 0
        var pageIndex = 0

        // Re-paginating with a page on screen (the controls shown or hidden,
        // the narration bar, a resize): a page starts exactly where that one
        // did, so its first line stays put and the new room shows at its
        // foot. The page before it may come out short.
        var keptID: UUID?
        if let start, let i = atoms.firstIndex(where: {
            $0.originalParagraphIndex == start.paragraph && $0.sentenceIndex == start.sentence
                && start.offset >= $0.sentenceOffset
                && start.offset < $0.sentenceOffset + $0.text.characters.count
        }) {
            let k = start.offset - atoms[i].sentenceOffset
            if k > 0, let (head, tail) = splitAtom(atoms[i], at: k) {
                atoms[i] = head
                atoms.insert(tail, at: i + 1)
                keptID = tail.id
            } else {
                keptID = atoms[i].id
            }
        }
        var reachedKept = keptID == nil

        let measure: (AttributedString) -> CGFloat = { text in
            calculateHeight(for: text, width: width, fontSize: fontSize, fontFamily: fontFamily,
                            lineSpacing: lineSpacing, kerning: kerning, boldText: boldText)
        }
        // One line of body text.
        let oneLine = fontFamily.uiFont(size: fontSize).lineHeight
        
        if isFirstChapter {
            // Page 0 is a dedicated cover/metadata page with no story text.
            pages.append(ChapterPage(
                id: "c\(chapterIndex)-p0",
                chapterIndex: chapterIndex,
                pageIndex: 0,
                paragraphIndices: 0..<0
            ))
            pageIndex = 1
        }
        
        while startIndex < atoms.count {
            var pageMaxHeight = viewportHeight
            
            // Check if this page should display the chapter header
            let displaysChapterHeader = showChapterHeader && (
                isFirstChapter ? (pageIndex == 1) : (pageIndex == 0)
            )
            
            if displaysChapterHeader {
                pageMaxHeight = max(0, viewportHeight - chapterHeaderHeight)
            }

            let reserve = drawnHeight == nil ? Self.uncheckedReserve(pageMaxHeight) : Self.reserve
            let isKept = atoms[startIndex].id == keptID
            if isKept { reachedKept = true }
            // Pages before the kept one stop short of it.
            let stop = reachedKept ? nil : keptID
            var endIndex = startIndex
            var includedAny = false
            if pageMaxHeight > 40, let drawnHeight {
                endIndex = fitPage(&atoms, from: startIndex, pageHeight: pageMaxHeight, reserve: reserve,
                                   paragraphSpacing: paragraphSpacing, oneLine: oneLine,
                                   measure: measure, drawnHeight: drawnHeight, stoppingBefore: stop)
                includedAny = true
            } else if pageMaxHeight > 40 {
                endIndex = packPage(&atoms, from: startIndex, budget: pageMaxHeight - reserve,
                                    paragraphSpacing: paragraphSpacing, oneLine: oneLine, measure: measure,
                                    stoppingBefore: stop)
                includedAny = true
            }

            let range: Range<Int>
            if includedAny {
                range = startIndex..<(endIndex + 1)
                startIndex = endIndex + 1
            } else {
                range = startIndex..<startIndex
            }

            pages.append(ChapterPage(
                id: "c\(chapterIndex)-p\(pageIndex)",
                chapterIndex: chapterIndex,
                pageIndex: pageIndex,
                paragraphIndices: range,
                // Spreads pair pages from the chapter's first: an odd page sits
                // on the right, so the kept page opens a spread of its own.
                startsSpread: isKept && includedAny && pageIndex % 2 == 1
            ))
            pageIndex += 1
        }
        
        if pages.isEmpty {
            pages.append(ChapterPage(
                id: "c\(chapterIndex)-p0",
                chapterIndex: chapterIndex,
                pageIndex: 0,
                paragraphIndices: 0..<0
            ))
        }
        
        return pages
    }

    /// A page's text as SwiftUI draws it: the height of atoms[range] laid out
    /// in ReaderPageCell's own view.
    typealias DrawnHeight = @MainActor (_ atoms: [ParagraphAtom], _ range: Range<Int>) -> CGFloat

    /// What pages checked against SwiftUI's layout (fitPage) are packed short
    /// of their area by: nothing. The check measures the page exactly as it's
    /// drawn, and even a 2 pt margin cost the page a last line now and then.
    static let reserve: CGFloat = 0

    /// Pages not checked against SwiftUI's layout keep headroom for
    /// boundingRect measuring differently (2% of the page, 8–24 pt). On every
    /// page it left a line blank at the foot of many of them.
    static func uncheckedReserve(_ pageHeight: CGFloat) -> CGFloat {
        min(24, max(8, pageHeight * 0.02))
    }

    /// Whether the chapters either side of the one being read are checked
    /// against SwiftUI's layout too. They're paginated so page turns run on
    /// into them, and re-paginated, checked, as soon as one is reached;
    /// checking them up front too cost ~1.5 ms a page on iOS (a 9,000-word
    /// chapter: 250 ms instead of 100). On the Mac boundingRect runs short of
    /// SwiftUI's layout, so an unchecked page could put a line under the
    /// footer while you turn into it, and Macs are quick: it checks them all.
    static var checksAdjacentChapters: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// Measures pages with ReaderPageCell's view, reusing one hosting controller.
    static func drawnHeightMeasure(width: CGFloat, fontSize: CGFloat, fontFamily: ReaderFontFamily,
                                   lineSpacing: CGFloat, paragraphSpacing: CGFloat, kerning: CGFloat,
                                   boldText: Bool) -> DrawnHeight {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        let chapter = AO3ChapterPayload(index: 0, title: "", bodyHTML: "")
        let font = fontFamily.font(size: fontSize)
        return { atoms, range in
            let cell = ReaderPageCell(
                page: ChapterPage(id: "measure", chapterIndex: 0, pageIndex: 0, paragraphIndices: range),
                chapter: chapter, atoms: atoms, showTitleHeader: false, showChapterHeader: false,
                titleHeaderView: nil, chapterHeaderView: AnyView(EmptyView()),
                font: font, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing,
                kerning: kerning, boldText: boldText, foreground: .primary, highlightParagraph: nil)
            host.rootView = AnyView(cell.pageContent
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true))
            return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
    }

    /// Packs a page with boundingRect, then checks it against SwiftUI's
    /// layout, and when the two disagree packs it again with a corrected
    /// budget until the page is as full as it can be without running past it.
    /// boundingRect is close but not exact: under the Mac's text metrics New
    /// York lines draw a point taller and small text fits more words a line,
    /// and on iOS a long paragraph can wrap to one line fewer than boundingRect
    /// counts. Either way pages came out a line or more short, or ran a line
    /// past the footer. Most pages need one SwiftUI measurement; a misjudged
    /// one bisects the budget between the fullest packing that fit and the
    /// smallest that ran past. Returns the page's last atom.
    private static func fitPage(_ atoms: inout [ParagraphAtom], from start: Int, pageHeight: CGFloat, reserve: CGFloat,
                                paragraphSpacing: CGFloat, oneLine: CGFloat,
                                measure: (AttributedString) -> CGFloat, drawnHeight: DrawnHeight,
                                stoppingBefore stop: UUID? = nil) -> Int {
        let unpacked = atoms
        let limit = pageHeight - reserve
        var budget = limit
        var fullest: (atoms: [ParagraphAtom], end: Int, budget: CGFloat)?
        var overflowing: CGFloat?
        var latest: (atoms: [ParagraphAtom], end: Int) = (unpacked, start)
        for _ in 0..<8 {
            var trial = unpacked
            let end = packPage(&trial, from: start, budget: budget, paragraphSpacing: paragraphSpacing,
                               oneLine: oneLine, measure: measure, stoppingBefore: stop)
            latest = (trial, end)
            let drawn = drawnHeight(trial, start..<(end + 1))
            if drawn > limit {
                // Any budget down to what boundingRect measured this packing
                // at packs the very same lines (it left them slack under the
                // budget), so that's the bound to go below, not the budget.
                let packed = packedHeight(trial, start...end, paragraphSpacing: paragraphSpacing, measure: measure)
                overflowing = min(overflowing ?? budget, min(budget, packed))
            } else {
                if budget >= (fullest?.budget ?? -1) { fullest = (trial, end, budget) }
                // Done when there's nothing left to add or no room for a line.
                if end + 1 >= trial.count || trial[end + 1].id == stop || limit - drawn < oneLine { break }
            }
            switch (fullest?.budget, overflowing) {
            case let (fit?, over?):
                guard over - fit > 1 else { break }
                budget = (fit + over) / 2
                continue
            case let (fit?, nil):
                budget = fit + (limit - drawn)
                continue
            case let (nil, over?):
                budget = over - (drawn - limit) - 1
                continue
            case (nil, nil):
                break
            }
            break
        }
        // Nothing fit (a page of one unbreakable sentence): take the last try.
        let chosen = fullest.map { (atoms: $0.atoms, end: $0.end) } ?? latest
        atoms = chosen.atoms
        return chosen.end
    }

    /// The height boundingRect measures atoms[range] at, laid out as a page:
    /// each paragraph's sentences joined, paragraphs spaced apart.
    private static func packedHeight(_ atoms: [ParagraphAtom], _ range: ClosedRange<Int>, paragraphSpacing: CGFloat,
                                     measure: (AttributedString) -> CGFloat) -> CGFloat {
        var blocks: [[ParagraphAtom]] = []
        for atom in atoms[range] {
            if let last = blocks.last?.last, last.originalParagraphIndex == atom.originalParagraphIndex {
                blocks[blocks.count - 1].append(atom)
            } else {
                blocks.append([atom])
            }
        }
        return blocks.map { measure(ReaderPageCell.concatenateAtoms($0)) }.reduce(0, +)
            + paragraphSpacing * CGFloat(max(0, blocks.count - 1))
    }

    /// Fills a page from `startIndex` with as much as `budget` holds, by
    /// boundingRect, never taking the atom `stop` (where a kept page starts).
    /// May split a sentence at a line end (the rest becomes a new atom right
    /// after it). Returns the page's last atom.
    private static func packPage(_ atoms: inout [ParagraphAtom], from startIndex: Int, budget packingBudget: CGFloat,
                                 paragraphSpacing: CGFloat, oneLine: CGFloat,
                                 measure: (AttributedString) -> CGFloat, stoppingBefore stop: UUID? = nil) -> Int {
        var endIndex = startIndex
        var currentBlockParaIndex = atoms[startIndex].originalParagraphIndex
        var currentBlockAtoms: [ParagraphAtom] = [atoms[startIndex]]
        var currentBlockHeight = measure(ReaderPageCell.concatenateAtoms(currentBlockAtoms))
        // A single sentence taller than the page: break it at a line
        // end rather than letting the page overflow.
        if currentBlockHeight > packingBudget,
           let (head, tail) = splitAtomToFit(atoms[startIndex], after: [], budget: packingBudget, measure: measure) {
            atoms[startIndex] = head
            atoms.insert(tail, at: startIndex + 1)
            currentBlockAtoms = [head]
            currentBlockHeight = measure(head.text)
        }

        var currentHeight = currentBlockHeight
        var completedBlocksHeight: CGFloat = 0

        while endIndex + 1 < atoms.count, atoms[endIndex + 1].id != stop {
            let nextAtom = atoms[endIndex + 1]

            if nextAtom.originalParagraphIndex == currentBlockParaIndex {
                let proposedBlockAtoms = currentBlockAtoms + [nextAtom]
                let proposedBlockHeight = measure(ReaderPageCell.concatenateAtoms(proposedBlockAtoms))
                let potentialHeight = completedBlocksHeight + proposedBlockHeight
                if potentialHeight <= packingBudget {
                    endIndex += 1
                    currentBlockAtoms = proposedBlockAtoms
                    currentBlockHeight = proposedBlockHeight
                    currentHeight = potentialHeight
                } else {
                    // Fill the page to its last line, like a printed
                    // book: the sentence continues on the next page.
                    if let (head, tail) = splitAtomToFit(nextAtom, after: currentBlockAtoms,
                                                         budget: packingBudget - completedBlocksHeight,
                                                         measure: measure) {
                        atoms[endIndex + 1] = head
                        atoms.insert(tail, at: endIndex + 2)
                        endIndex += 1
                    }
                    break
                }
            } else {
                let proposedBlockAtoms = [nextAtom]
                let proposedBlockHeight = measure(ReaderPageCell.concatenateAtoms(proposedBlockAtoms))
                let potentialHeight = currentHeight + paragraphSpacing + proposedBlockHeight
                if potentialHeight <= packingBudget {
                    endIndex += 1
                    completedBlocksHeight += currentBlockHeight + paragraphSpacing
                    currentBlockParaIndex = nextAtom.originalParagraphIndex
                    currentBlockAtoms = proposedBlockAtoms
                    currentBlockHeight = proposedBlockHeight
                    currentHeight = potentialHeight
                } else {
                    // Start the paragraph here with as many lines as fit,
                    // even one, so the page fills to its last line. (Holding
                    // back a lone opening line, as books do, left up to two
                    // lines blank at the foot of a page.)
                    let room = packingBudget - currentHeight - paragraphSpacing
                    if room >= oneLine,
                       let (head, tail) = splitAtomToFit(nextAtom, after: [], budget: room, measure: measure) {
                        atoms[endIndex + 1] = head
                        atoms.insert(tail, at: endIndex + 2)
                        endIndex += 1
                    }
                    break
                }
            }
        }
        return endIndex
    }
}
