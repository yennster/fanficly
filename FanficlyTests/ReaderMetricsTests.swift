import XCTest
import SwiftUI
@testable import Fanficly

/// The reading column: phone settings cap line length on wide layouts (a Pro
/// Max in landscape, iPhone Duo unfolded); iPad and Mac keep the plain
/// percentage the user chose.
final class ReaderMetricsTests: XCTestCase {
    func test_narrowPhone_usesThePercentage() {
        let w = ReaderMetrics.textColumnWidth(containerWidth: 402, widthPercent: 90, fontSize: 18, limitLineLength: true)
        XCTAssertEqual(w, 361.8, accuracy: 0.01)
    }

    func test_widePhoneLayout_capsAtAbout80Characters() {
        let w = ReaderMetrics.textColumnWidth(containerWidth: 951, widthPercent: 90, fontSize: 18, limitLineLength: true)
        XCTAssertEqual(w, 18 * ReaderMetrics.maxLineLengthEm)
    }

    func test_capScalesWithTextSize() {
        let big = ReaderMetrics.textColumnWidth(containerWidth: 951, widthPercent: 100, fontSize: 24, limitLineLength: true)
        XCTAssertEqual(big, min(951, 24 * ReaderMetrics.maxLineLengthEm))
    }

    func test_ipadAndMac_keepThePercentage() {
        let w = ReaderMetrics.textColumnWidth(containerWidth: 1366, widthPercent: 70, fontSize: 18, limitLineLength: false)
        XCTAssertEqual(w, 956.2, accuracy: 0.01)
    }
}

/// Page-by-page's two-page spread: when it kicks in, where the gutter goes,
/// and how pages pair up.
final class ReaderSpreadTests: XCTestCase {
    private func page(_ chapter: Int, _ index: Int) -> ChapterPage {
        ChapterPage(id: "c\(chapter)-p\(index)", chapterIndex: chapter, pageIndex: index, paragraphIndices: 0..<1)
    }

    func test_portraitPhone_staysOnePage() {
        XCTAssertNil(ReaderSpread.layout(containerSize: CGSize(width: 402, height: 800), fold: nil))
    }

    func test_iPadPortrait_staysOnePage() {
        // Wide enough, but taller than it is wide.
        XCTAssertNil(ReaderSpread.layout(containerSize: CGSize(width: 1032, height: 1300), fold: nil))
    }

    func test_landscape_splitsAroundTheCenter() throws {
        let layout = try XCTUnwrap(ReaderSpread.layout(containerSize: CGSize(width: 1000, height: 700), fold: nil))
        XCTAssertEqual((layout.gutter.lowerBound + layout.gutter.upperBound) / 2, 500)
        XCTAssertEqual(layout.gutter.upperBound - layout.gutter.lowerBound, ReaderSpread.minimumGutter)
        XCTAssertEqual(layout.leftX + layout.pageWidth, layout.gutter.lowerBound)
        XCTAssertLessThanOrEqual(layout.gutter.upperBound + layout.pageWidth, 1000)
    }

    func test_duoFold_becomesTheGutter() throws {
        // A fold slightly off center: the gutter follows it, and both pages
        // keep the same width (they paginate identically).
        let fold = CGRect(x: 470, y: 0, width: 20, height: 700)
        let layout = try XCTUnwrap(ReaderSpread.layout(containerSize: CGSize(width: 1000, height: 700), fold: fold))
        XCTAssertEqual((layout.gutter.lowerBound + layout.gutter.upperBound) / 2, fold.midX)
        XCTAssertEqual(layout.pageWidth, floor(min(layout.gutter.lowerBound, 1000 - layout.gutter.upperBound)))
    }

    func test_horizontalOrEdgeRegion_isNotTreatedAsTheFold() throws {
        let sideways = CGRect(x: 0, y: 340, width: 1000, height: 20)
        let edge = CGRect(x: 960, y: 0, width: 40, height: 700)
        for region in [sideways, edge] {
            let layout = try XCTUnwrap(ReaderSpread.layout(containerSize: CGSize(width: 1000, height: 700), fold: region))
            XCTAssertEqual((layout.gutter.lowerBound + layout.gutter.upperBound) / 2, 500)
        }
    }

    func test_pagesPairWithinEachChapter() {
        let pages = [page(1, 0), page(1, 1), page(1, 2), page(2, 0), page(2, 1)]
        let spreads = ReaderSpread.spreads(from: pages)
        XCTAssertEqual(spreads.map(\.left.id), ["c1-p0", "c1-p2", "c2-p0"])
        XCTAssertEqual(spreads.map { $0.right?.id }, ["c1-p1", nil, "c2-p1"])
    }

    func test_spreadFindsEitherOfItsPages() {
        let spread = ReaderSpread.spreads(from: [page(1, 0), page(1, 1)])[0]
        XCTAssertTrue(spread.contains("c1-p0"))
        XCTAssertTrue(spread.contains("c1-p1"))
        XCTAssertFalse(spread.contains("c1-p2"))
        XCTAssertEqual(spread.id, "c1-p0")
    }
}


/// Page-by-page's page height: pages fit the area with the controls up, shrink
/// at once and grow back only once the area settles. The heights are an
/// iPhone's page area: 700 with the controls up, 784 with them hidden.
final class PageAreaTrackerTests: XCTestCase {
    func test_shrinksAtOnce() {
        var tracker = PageAreaTracker()
        tracker.reset(to: 700)
        tracker.observe(650)
        XCTAssertEqual(tracker.pageHeight, 650)
    }

    func test_aMomentsSmallerArea_growsBackOnceSettled() {
        // A short first layout (a transition) used to stick for good, leaving
        // blank space at the foot of every page.
        var tracker = PageAreaTracker()
        tracker.reset(to: 530)
        tracker.observe(700)
        XCTAssertEqual(tracker.pageHeight, 530, "growing waits for the area to settle")
        tracker.settle(700, controlsUp: true)
        XCTAssertEqual(tracker.pageHeight, 700)
    }

    func test_togglingTheControls_keepsThePageHeight() {
        var tracker = PageAreaTracker()
        tracker.reset(to: 700)
        tracker.settle(700, controlsUp: true)
        tracker.observe(784)
        tracker.settle(784, controlsUp: false)
        XCTAssertEqual(tracker.pageHeight, 700, "pages must still fit once the controls return")
        tracker.observe(700)
        tracker.settle(700, controlsUp: true)
        XCTAssertEqual(tracker.pageHeight, 700)
    }

    func test_controlsHidden_growsBackToTheControlsUpArea() {
        var tracker = PageAreaTracker()
        tracker.reset(to: 700)
        tracker.settle(700, controlsUp: true)
        tracker.observe(400)  // e.g. a keyboard inset while reading
        tracker.settle(784, controlsUp: false)
        XCTAssertEqual(tracker.pageHeight, 700)
    }

    func test_narrationBar_shrinksPagesUntilItCloses() {
        var tracker = PageAreaTracker()
        tracker.reset(to: 700)
        tracker.settle(700, controlsUp: true)
        tracker.observe(660)
        tracker.settle(660, controlsUp: true)
        XCTAssertEqual(tracker.pageHeight, 660)
        tracker.observe(700)
        tracker.settle(700, controlsUp: true)
        XCTAssertEqual(tracker.pageHeight, 700)
    }

    func test_newWindowSize_forgetsTheControlsUpArea() {
        // Rotated with the controls hidden: there's no controls-up area for the
        // new size yet, so pages don't grow until the controls show.
        var tracker = PageAreaTracker()
        tracker.reset(to: 700)
        tracker.settle(700, controlsUp: true)
        tracker.reset(to: 330)
        XCTAssertEqual(tracker.controlsUpHeight, 0)
        tracker.observe(300)
        tracker.settle(330, controlsUp: false)
        XCTAssertEqual(tracker.pageHeight, 300)
        tracker.settle(310, controlsUp: true)
        XCTAssertEqual(tracker.pageHeight, 310)
    }
}

/// Page-by-page pagination on every screen the app runs on, so a layout change
/// made for one (iPhone Duo's spread, a Mac window) can't quietly break the
/// others: no page runs past its page area, no page but a chapter's last
/// leaves a band of blank space, every sentence lands on exactly one page, and
/// SwiftUI draws each page within the height it was measured for. Runs on
/// whichever simulator CI picks (iPhone and iPad), so text is measured with
/// that platform's metrics.
@MainActor
final class ReaderPaginationTests: XCTestCase {
    struct Device {
        let name: String
        /// The page container: its width × its height with the reader
        /// controls (nav bar, page footer) up.
        let pageArea: CGSize
        /// Phone settings cap line length (see ReaderMetrics.textColumnWidth).
        let isPhone: Bool
        /// iPhone Duo's fold, in the page container's space.
        var fold: CGRect? = nil
    }

    static let devices: [Device] = [
        Device(name: "iPhone SE", pageArea: CGSize(width: 375, height: 570), isPhone: true),
        Device(name: "iPhone 17", pageArea: CGSize(width: 402, height: 694), isPhone: true),
        Device(name: "iPhone 17 Pro Max", pageArea: CGSize(width: 440, height: 776), isPhone: true),
        Device(name: "iPhone 17 Pro Max landscape", pageArea: CGSize(width: 832, height: 357), isPhone: true),
        Device(name: "iPhone Duo folded", pageArea: CGSize(width: 466, height: 520), isPhone: true),
        Device(name: "iPhone Duo unfolded", pageArea: CGSize(width: 880, height: 600), isPhone: true,
               fold: CGRect(x: 465, y: 0, width: 20, height: 600)),
        Device(name: "iPad mini", pageArea: CGSize(width: 744, height: 1009), isPhone: false),
        Device(name: "iPad Pro 13-inch", pageArea: CGSize(width: 1032, height: 1252), isPhone: false),
        Device(name: "iPad Pro 13-inch landscape", pageArea: CGSize(width: 1376, height: 908), isPhone: false),
        Device(name: "Mac window", pageArea: CGSize(width: 1280, height: 718), isPhone: false),
    ]

    struct Typography {
        let name: String
        let family: ReaderFontFamily
        let fontSize: CGFloat
        let lineSpacing: CGFloat
        let paragraphSpacing: CGFloat
        let kerning: CGFloat
        let bold: Bool
        /// One-page margins (two-page spreads use their own default).
        let widthPercent: Double
    }

    static let typographies: [Typography] = [
        Typography(name: "default", family: .newYork, fontSize: CGFloat(ReaderMetrics.defaultFontSize),
                   lineSpacing: CGFloat(ReaderMetrics.defaultLineSpacing),
                   paragraphSpacing: CGFloat(ReaderMetrics.defaultParagraphSpacing),
                   kerning: 0, bold: false, widthPercent: 70),
        Typography(name: "small sans", family: .sans, fontSize: 13, lineSpacing: 2, paragraphSpacing: 8,
                   kerning: 0, bold: false, widthPercent: 90),
        Typography(name: "huge bold serif", family: .serif, fontSize: 27, lineSpacing: 12, paragraphSpacing: 30,
                   kerning: 1.5, bold: true, widthPercent: 100),
    ]

    /// ~3,000 words of plain prose: paragraphs of one to twelve sentences,
    /// dialogue, a little emphasis. Several pages on any screen.
    static let chapterHTML: String = {
        let words = ["the", "rain", "had", "not", "stopped", "since", "morning", "and", "she", "walked",
                     "along", "river", "with", "her", "hands", "deep", "in", "pockets", "of", "an", "old",
                     "coat", "that", "smelled", "faintly", "woodsmoke", "library", "dust", "quiet",
                     "because", "remembered", "everything", "he", "said", "about", "staying", "still",
                     "when", "world", "goes", "sideways", "understanding", "a", "to", "was"]
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        func sentence() -> String {
            let text = (0..<(4 + next(22))).map { _ in words[next(words.count)] }.joined(separator: " ")
            return text.prefix(1).uppercased() + String(text.dropFirst()) + [".", ".", ".", "?", "!"][next(5)]
        }
        var paragraphs: [String] = []
        for i in 0..<70 {
            var text = (0..<(i % 9 == 0 ? 12 : 1 + next(5))).map { _ in sentence() }.joined(separator: " ")
            if i % 6 == 3 { text = "\u{201C}\(sentence())\u{201D} he said." }
            if i % 11 == 5 { text = "<em>\(text)</em>" }
            paragraphs.append("<p>\(text)</p>")
        }
        return paragraphs.joined()
    }()

    private struct Layout {
        let columnWidth: CGFloat
        /// The page's height for content, inside its top and bottom margins.
        let viewportHeight: CGFloat
        let pagesOnScreen: Int
    }

    private func layout(_ device: Device, _ type: Typography) -> Layout {
        // As ReaderView.pageByPageBody: a two-page spread when the window is
        // wide enough, both pages paginated at the spread's page width.
        let spread = ReaderSpread.layout(containerSize: device.pageArea, fold: device.fold)
        let percent = spread == nil ? type.widthPercent : ReaderSpread.defaultWidthPercent
        let width = ReaderMetrics.textColumnWidth(containerWidth: spread?.pageWidth ?? device.pageArea.width,
                                                  widthPercent: percent, fontSize: Double(type.fontSize),
                                                  limitLineLength: device.isPhone)
        return Layout(columnWidth: width,
                      viewportHeight: device.pageArea.height - 2 * ReaderView.pageVerticalMargin,
                      pagesOnScreen: spread == nil ? 1 : 2)
    }

    private struct Pagination {
        let pages: [ChapterPage]
        let atoms: [ParagraphAtom]
        let chapterHeaderHeight: CGFloat
    }

    /// A chapter after the first (chapter 1 adds the work's title page).
    private func paginate(_ type: Typography, _ layout: Layout, isFirstChapter: Bool = false) -> Pagination {
        var atoms = ReaderPaginator.atoms(fromChapterHTML: Self.chapterHTML, includeImages: false)
        let header = ReaderPaginator.estimateChapterHeaderHeight(
            title: "The Long Way Round", width: layout.columnWidth, fontSize: type.fontSize, fontFamily: type.family)
        let titleHeader = ReaderPaginator.estimateTitleHeaderHeight(
            title: "A Fixture Work", author: "tester", authorUsername: "tester", summary: nil,
            width: layout.columnWidth, fontSize: type.fontSize, fontFamily: type.family)
        let pages = ReaderPaginator.paginateChapter(
            chapterIndex: isFirstChapter ? 1 : 2, atoms: &atoms, width: layout.columnWidth,
            viewportHeight: layout.viewportHeight, titleHeaderHeight: titleHeader, chapterHeaderHeight: header,
            isFirstChapter: isFirstChapter, showChapterHeader: true, fontSize: type.fontSize,
            fontFamily: type.family, lineSpacing: type.lineSpacing, paragraphSpacing: type.paragraphSpacing,
            kerning: type.kerning, boldText: type.bold)
        return Pagination(pages: pages, atoms: atoms, chapterHeaderHeight: header)
    }

    /// The page's paragraphs, joined as ReaderPageCell draws them.
    private func blocks(_ page: ChapterPage, _ atoms: [ParagraphAtom]) -> [AttributedString] {
        var groups: [[ParagraphAtom]] = []
        for index in page.paragraphIndices {
            if let last = groups.last?.last, last.originalParagraphIndex == atoms[index].originalParagraphIndex {
                groups[groups.count - 1].append(atoms[index])
            } else {
                groups.append([atoms[index]])
            }
        }
        return groups.map(ReaderPageCell.concatenateAtoms)
    }

    private func measure(_ text: AttributedString, _ type: Typography, _ layout: Layout) -> CGFloat {
        ReaderPaginator.calculateHeight(for: text, width: layout.columnWidth, fontSize: type.fontSize,
                                        fontFamily: type.family, lineSpacing: type.lineSpacing,
                                        kerning: type.kerning, boldText: type.bold)
    }

    /// The page's height as the paginator measures it, header included.
    private func measuredHeight(_ page: ChapterPage, in result: Pagination, _ type: Typography, _ layout: Layout) -> CGFloat {
        let parts = blocks(page, result.atoms)
        let text = parts.map { measure($0, type, layout) }.reduce(0, +)
            + type.paragraphSpacing * CGFloat(max(0, parts.count - 1))
        return text + (page.pageIndex == 0 ? result.chapterHeaderHeight : 0)
    }

    /// The most blank space a full page may leave: the paginator's safety
    /// margin, plus a paragraph that needs two lines to start on a page (a
    /// lone opening line moves to the next page), plus a line of slack.
    private func fillTolerance(_ type: Typography, _ layout: Layout) -> CGFloat {
        let line = measure(AttributedString("Ag"), type, layout) + type.lineSpacing
        let reserve = min(24, max(8, layout.viewportHeight * 0.02))
        return reserve + type.paragraphSpacing + 3 * line
    }

    private func forEachLayout(_ body: (Device, Typography, Layout, String) throws -> Void) rethrows {
        for device in Self.devices {
            for type in Self.typographies {
                try body(device, type, layout(device, type), "\(device.name), \(type.name)")
            }
        }
    }

    func test_twoPageSpread_onlyOnWideWindows() {
        let spreads = Self.devices.filter { layout($0, Self.typographies[0]).pagesOnScreen == 2 }.map(\.name)
        XCTAssertEqual(spreads, ["iPhone 17 Pro Max landscape", "iPhone Duo unfolded",
                                 "iPad Pro 13-inch landscape", "Mac window"])
    }

    func test_everySentenceLandsOnExactlyOnePage() {
        forEachLayout { _, type, layout, label in
            let result = paginate(type, layout)
            XCTAssertGreaterThanOrEqual(result.pages.count, 3, "\(label): the fixture should span several pages")
            var next = 0
            for page in result.pages {
                XCTAssertEqual(page.paragraphIndices.lowerBound, next, "\(label): gap or overlap before page \(page.pageIndex)")
                XCTAssertFalse(page.paragraphIndices.isEmpty, "\(label): empty page \(page.pageIndex)")
                next = page.paragraphIndices.upperBound
            }
            XCTAssertEqual(next, result.atoms.count, "\(label): sentences missing from the last page")
        }
    }

    func test_firstChapter_opensOnTheTitlePage() {
        forEachLayout { _, type, layout, label in
            let pages = paginate(type, layout, isFirstChapter: true).pages
            XCTAssertEqual(pages.first?.paragraphIndices, 0..<0, "\(label): page 0 is the title page")
            XCTAssertEqual(pages.dropFirst().first?.paragraphIndices.lowerBound, 0, "\(label): text starts on page 1")
        }
    }

    func test_pagesFitTheirPageArea() {
        forEachLayout { _, type, layout, label in
            let result = paginate(type, layout)
            for page in result.pages {
                let height = measuredHeight(page, in: result, type, layout)
                XCTAssertLessThanOrEqual(height, layout.viewportHeight,
                                         "\(label): page \(page.pageIndex) runs \(height - layout.viewportHeight) pt past its area")
            }
        }
    }

    func test_pagesFillTheirPageArea() {
        // The blank-band regression: every page but a chapter's last is full.
        forEachLayout { _, type, layout, label in
            let result = paginate(type, layout)
            let tolerance = fillTolerance(type, layout)
            for page in result.pages.dropLast() {
                let blank = layout.viewportHeight - measuredHeight(page, in: result, type, layout)
                XCTAssertLessThanOrEqual(blank, tolerance,
                                         "\(label): page \(page.pageIndex) leaves \(blank) pt blank (allowed \(tolerance))")
            }
        }
    }

    func test_swiftUIDrawsEachPageWithinItsArea() {
        // boundingRect (the paginator) and SwiftUI's Text layout disagree by
        // fractions of a point per line, differently per platform; the
        // paginator's safety margin has to absorb it, or a page's last lines
        // run under the footer. Pages after the first carry no header.
        forEachLayout { _, type, layout, label in
            let result = paginate(type, layout)
            let chapter = AO3ChapterPayload(index: 2, title: "The Long Way Round", bodyHTML: Self.chapterHTML)
            let tolerance = fillTolerance(type, layout) + layout.viewportHeight * 0.03
            for page in result.pages.dropFirst().prefix(3) {
                let cell = ReaderPageCell(
                    page: page, chapter: chapter, atoms: result.atoms,
                    showTitleHeader: false, showChapterHeader: false,
                    titleHeaderView: nil, chapterHeaderView: AnyView(EmptyView()),
                    font: type.family.font(size: type.fontSize), lineSpacing: type.lineSpacing,
                    paragraphSpacing: type.paragraphSpacing, kerning: type.kerning, boldText: type.bold,
                    foreground: .primary, highlightParagraph: nil)
                let host = UIHostingController(rootView: cell.pageContent
                    .frame(width: layout.columnWidth)
                    .fixedSize(horizontal: false, vertical: true))
                let drawn = host.sizeThatFits(in: CGSize(width: layout.columnWidth,
                                                         height: .greatestFiniteMagnitude)).height
                XCTAssertLessThanOrEqual(drawn, layout.viewportHeight,
                                         "\(label): page \(page.pageIndex) draws \(drawn - layout.viewportHeight) pt past its area")
                if page.id != result.pages.last?.id {
                    XCTAssertGreaterThanOrEqual(drawn, layout.viewportHeight - tolerance,
                                                "\(label): page \(page.pageIndex) draws only \(drawn) of \(layout.viewportHeight) pt")
                }
            }
        }
    }
}

/// TEMPORARY diagnostic (remove before merge): prints how boundingRect and
/// SwiftUI's Text measure the same text on this platform, so the paginator's
/// measurement can be matched to what SwiftUI draws.
@MainActor
final class TextMetricsReport: XCTestCase {
    private func drawn(_ text: AttributedString, _ family: ReaderFontFamily, _ size: CGFloat,
                       lineSpacing: CGFloat, width: CGFloat) -> CGFloat {
        let view = Text(text).font(family.font(size: size)).lineSpacing(lineSpacing)
            .frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        return UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private func lineCount(_ text: AttributedString, _ family: ReaderFontFamily, _ size: CGFloat, width: CGFloat) -> Int {
        let storage = NSTextStorage(string: String(text.characters), attributes: [.font: family.uiFont(size: size)])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
        return lines
    }

    func test_report() {
        let long = AttributedString(String(repeating: "The rain had not stopped since morning and she walked along the river. ", count: 4))
        for family in ReaderFontFamily.allCases {
            for size: CGFloat in [13, 18, 27] {
                let font = family.uiFont(size: size)
                var row = "METRICS \(family.rawValue) \(Int(size))pt lineHeight=\(font.lineHeight) asc=\(font.ascender) desc=\(font.descender) leading=\(font.leading)"
                for ls: CGFloat in [0, 6] {
                    for n in [1, 2, 10] {
                        let text = AttributedString(Array(repeating: "Ag", count: n).joined(separator: "\n"))
                        let measured = ReaderPaginator.calculateHeight(for: text, width: 300, fontSize: size, fontFamily: family,
                                                                       lineSpacing: ls, kerning: 0, boldText: false)
                        row += " | ls\(Int(ls)) n\(n) rect=\(measured) swiftui=\(drawn(text, family, size, lineSpacing: ls, width: 300))"
                    }
                    let measured = ReaderPaginator.calculateHeight(for: long, width: 300, fontSize: size, fontFamily: family,
                                                                   lineSpacing: ls, kerning: 0, boldText: false)
                    row += " | ls\(Int(ls)) wrapped lines=\(lineCount(long, family, size, width: 300)) rect=\(measured) swiftui=\(drawn(long, family, size, lineSpacing: ls, width: 300))"
                }
                print(row)
            }
        }
    }
}
