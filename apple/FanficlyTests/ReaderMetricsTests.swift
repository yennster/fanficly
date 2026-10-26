import XCTest
import SwiftUI
@testable import Fanficly

/// The reading column: phone settings cap line length on wide layouts (a Pro
/// Max in landscape, iPhone Duo unfolded); iPad and Mac keep the plain
/// percentage the user chose.
final class ReaderMetricsTests: XCTestCase {
    func test_narrowPhone_usesThePercentage() {
        let w = ReaderMetrics.textColumnWidth(containerWidth: 402, widthPercent: 90, fontSize: 18, limitLineLength: true)
        XCTAssertEqual(w, 361, "402 × 90%, in whole points")
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
        XCTAssertEqual(w, 956, "1366 × 70%, in whole points")
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

    func test_aKeptPageOpensASpread() {
        // Re-paginating keeps the page on screen in place; in a spread it has
        // to stay on the left, so the page before it may stand alone.
        var kept = page(1, 3)
        kept.startsSpread = true
        let spreads = ReaderSpread.spreads(from: [page(1, 0), page(1, 1), page(1, 2), kept, page(1, 4)])
        XCTAssertEqual(spreads.map(\.left.id), ["c1-p0", "c1-p2", "c1-p3"])
        XCTAssertEqual(spreads.map { $0.right?.id }, ["c1-p1", nil, "c1-p4"])
    }

    func test_spreadFindsEitherOfItsPages() {
        let spread = ReaderSpread.spreads(from: [page(1, 0), page(1, 1)])[0]
        XCTAssertTrue(spread.contains("c1-p0"))
        XCTAssertTrue(spread.contains("c1-p1"))
        XCTAssertFalse(spread.contains("c1-p2"))
        XCTAssertEqual(spread.id, "c1-p0")
    }
}


/// Which side insets the reader runs under (`RunUnderSideColumn`).
final class ReaderSideColumnTests: XCTestCase {
    private func edges(leading: CGFloat, trailing: CGFloat, isPhone: Bool = true,
                       compactHeight: Bool = false) -> Edge.Set {
        RunUnderSideColumn.columnEdges(EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing),
                                        isPhone: isPhone, compactHeight: compactHeight)
    }

    func test_duoColumn_isRunUnder() {
        XCTAssertEqual(edges(leading: 0, trailing: 64), .trailing)
        XCTAssertEqual(edges(leading: 64, trailing: 0), .leading)
    }

    func test_duoColumnBesideASidebar_onlyTheColumnIsRunUnder() {
        XCTAssertEqual(edges(leading: 320, trailing: 64), .trailing)
    }

    func test_landscapeNotch_isKept() {
        XCTAssertEqual(edges(leading: 62, trailing: 62), [])
        // An iPhone in landscape, whichever side its sensor housing is on.
        XCTAssertEqual(edges(leading: 62, trailing: 0, compactHeight: true), [])
        XCTAssertEqual(edges(leading: 0, trailing: 62, compactHeight: true), [])
    }

    func test_noInsets_orASidebarAlone_changeNothing() {
        XCTAssertEqual(edges(leading: 0, trailing: 0), [])
        XCTAssertEqual(edges(leading: 320, trailing: 0), [])
    }

    func test_iPadAndMac_keepTheirInsets() {
        XCTAssertEqual(edges(leading: 0, trailing: 64, isPhone: false), [])
    }
}

/// Page-by-page's page height: pages fill the page area on screen, shrink at
/// once and grow only once the area settles. The heights are an iPhone's page
/// area: 700 with the controls up, 784 with them hidden.
final class PageAreaTrackerTests: XCTestCase {
    func test_shrinksAtOnce() {
        var tracker = PageAreaTracker()
        tracker.reset(to: 700, controlsUp: true)
        tracker.observe(650, controlsUp: true)
        XCTAssertEqual(tracker.pageHeight, 650)
    }

    func test_aMomentsSmallerArea_growsBackOnceSettled() {
        // A short first layout (a transition) used to stick for good, leaving
        // blank space at the foot of every page.
        var tracker = PageAreaTracker()
        tracker.reset(to: 530, controlsUp: true)
        tracker.observe(700, controlsUp: true)
        XCTAssertEqual(tracker.pageHeight, 530, "growing waits for the area to settle")
        tracker.settle(700)
        XCTAssertEqual(tracker.pageHeight, 700)
    }

    func test_hidingTheControls_growsPagesToFillTheScreen() {
        // Pages used to stay at the controls-up height, leaving the controls'
        // room blank at the foot of every page while they were hidden.
        var tracker = PageAreaTracker()
        tracker.reset(to: 700, controlsUp: true)
        tracker.observe(784, controlsUp: false)
        XCTAssertEqual(tracker.pageHeight, 700, "growing waits for the bars to finish animating")
        tracker.settle(784)
        XCTAssertEqual(tracker.pageHeight, 784)
    }

    func test_showingTheControls_shrinksPagesAtOnce() {
        // Or the page's last lines would sit under the page footer.
        var tracker = PageAreaTracker()
        tracker.reset(to: 784, controlsUp: false)
        tracker.observe(700, controlsUp: true)
        XCTAssertEqual(tracker.pageHeight, 700)
        tracker.settle(700)
        XCTAssertEqual(tracker.pageHeight, 700)
    }

    func test_narrationBar_shrinksPagesUntilItCloses() {
        var tracker = PageAreaTracker()
        tracker.reset(to: 700, controlsUp: true)
        tracker.observe(660, controlsUp: true)
        tracker.settle(660)
        XCTAssertEqual(tracker.pageHeight, 660)
        tracker.observe(700, controlsUp: true)
        tracker.settle(700)
        XCTAssertEqual(tracker.pageHeight, 700)
    }

    func test_fullScreen_keepsOnePageOrTwo() {
        // An iPad in landscape beside the sidebar: a two-page spread with the
        // controls up, but full screen's extra height made the area too square
        // for two pages, so hiding the controls switched to one page.
        let width: CGFloat = 1056
        var tracker = PageAreaTracker()
        tracker.reset(to: 910, controlsUp: true)
        XCTAssertNotNil(ReaderSpread.layout(containerSize: CGSize(width: width, height: tracker.spreadDecisionHeight), fold: nil))
        tracker.observe(988, controlsUp: false)
        tracker.settle(988)
        XCTAssertEqual(tracker.pageHeight, 988, "full screen fills the screen")
        XCTAssertNil(ReaderSpread.layout(containerSize: CGSize(width: width, height: 988), fold: nil),
                     "the full-screen area alone would mean one page")
        XCTAssertEqual(tracker.spreadDecisionHeight, 910)
        XCTAssertNotNil(ReaderSpread.layout(containerSize: CGSize(width: width, height: tracker.spreadDecisionHeight), fold: nil),
                        "still two pages in full screen")
    }

    func test_newWindowSize_startsOver() {
        var tracker = PageAreaTracker()
        tracker.reset(to: 700, controlsUp: true)
        tracker.reset(to: 330, controlsUp: true)
        XCTAssertEqual(tracker.pageHeight, 330)
        tracker.observe(300, controlsUp: true)
        XCTAssertEqual(tracker.pageHeight, 300)
        tracker.settle(330)
        XCTAssertEqual(tracker.pageHeight, 330)
    }
}

/// Page-by-page pagination on every screen the app runs on, so a layout change
/// made for one (iPhone Duo's spread, a Mac window) can't quietly break the
/// others: every sentence lands on exactly one page, and each page, as SwiftUI
/// draws it, neither runs past its page area nor (but a chapter's last) leaves
/// a band of blank space. CI runs it on an iPhone, an iPad and the Mac, so
/// text is laid out with each platform's own metrics.
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
    /// `checked: false` paginates as the chapters either side of the one
    /// being read are on iOS: by boundingRect alone.
    private func paginate(_ type: Typography, _ layout: Layout, isFirstChapter: Bool = false,
                          startingAt start: PageStart? = nil, checked: Bool = true) -> Pagination {
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
            kerning: type.kerning, boldText: type.bold,
            // As ReaderView does for the chapter being read: check every
            // page against SwiftUI's layout.
            drawnHeight: checked ? drawn(type, layout) : nil,
            startingAt: start)
        return Pagination(pages: pages, atoms: atoms, chapterHeaderHeight: header)
    }

    /// SwiftUI's layout of a page's text, in ReaderPageCell's own view.
    private func drawn(_ type: Typography, _ layout: Layout) -> ReaderPaginator.DrawnHeight {
        ReaderPaginator.drawnHeightMeasure(width: layout.columnWidth, fontSize: type.fontSize,
                                           fontFamily: type.family, lineSpacing: type.lineSpacing,
                                           paragraphSpacing: type.paragraphSpacing, kerning: type.kerning,
                                           boldText: type.bold)
    }

    /// The page's height as SwiftUI draws it, with the chapter heading's
    /// (estimated) height on the chapter's first page.
    private func drawnHeight(_ page: ChapterPage, in result: Pagination, _ measure: ReaderPaginator.DrawnHeight) -> CGFloat {
        measure(result.atoms, page.paragraphIndices) + (page.pageIndex == 0 ? result.chapterHeaderHeight : 0)
    }

    /// The most blank space a full page may leave: the paginator's rounding
    /// margin, plus a paragraph gap and a line that didn't fit (a paragraph
    /// may start with a single line at the foot of a page, so nothing more).
    private func fillTolerance(_ type: Typography, _ layout: Layout) -> CGFloat {
        let oneLine = ReaderPaginator.atoms(fromChapterHTML: "<p>Ag</p>", includeImages: false)
        let line = drawn(type, layout)(oneLine, 0..<oneLine.count) + type.lineSpacing
        return ReaderPaginator.reserve + type.paragraphSpacing + line + 1
    }


    private func assertEverySentenceOnOnePage(_ result: Pagination, _ label: String,
                                              file: StaticString = #filePath, line: UInt = #line) {
        var next = 0
        for page in result.pages {
            XCTAssertEqual(page.paragraphIndices.lowerBound, next, "\(label): gap or overlap before page \(page.pageIndex)",
                           file: file, line: line)
            XCTAssertFalse(page.paragraphIndices.isEmpty, "\(label): empty page \(page.pageIndex)", file: file, line: line)
            next = page.paragraphIndices.upperBound
        }
        XCTAssertEqual(next, result.atoms.count, "\(label): sentences missing from the last page", file: file, line: line)
    }

    private func assertPagesFit(_ result: Pagination, _ type: Typography, _ layout: Layout, _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let measure = drawn(type, layout)
        for page in result.pages {
            let height = drawnHeight(page, in: result, measure)
            XCTAssertLessThanOrEqual(height, layout.viewportHeight,
                                     "\(label): page \(page.pageIndex) draws \(height - layout.viewportHeight) pt past its area",
                                     file: file, line: line)
        }
    }

    private func assertPagesFull<Pages: Sequence<ChapterPage>>(
        _ pages: Pages, in result: Pagination, _ type: Typography, _ layout: Layout, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let measure = drawn(type, layout)
        let tolerance = fillTolerance(type, layout)
        for page in pages {
            let blank = layout.viewportHeight - drawnHeight(page, in: result, measure)
            XCTAssertLessThanOrEqual(blank, tolerance,
                                     "\(label): page \(page.pageIndex) leaves \(blank) pt blank (allowed \(tolerance))",
                                     file: file, line: line)
        }
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
            assertEverySentenceOnOnePage(result, label)
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
        // Runs past it and the page's last lines sit under the footer.
        forEachLayout { _, type, layout, label in
            assertPagesFit(paginate(type, layout), type, layout, label)
        }
    }

    func test_uncheckedPages_stillFitTheirPageArea() throws {
        // The chapters either side of the one being read skip the check
        // against SwiftUI's layout on iOS (they're re-paginated, checked, once
        // reached); boundingRect's headroom must keep them on screen meanwhile.
        try XCTSkipIf(ReaderPaginator.checksAdjacentChapters, "this platform checks every chapter")
        forEachLayout { _, type, layout, label in
            assertPagesFit(paginate(type, layout, checked: false), type, layout, "\(label), unchecked")
        }
    }

    func test_pagesFillTheirPageArea() {
        // The blank-band regression: every page but a chapter's last is full.
        forEachLayout { _, type, layout, label in
            let result = paginate(type, layout)
            assertPagesFull(result.pages.dropLast(), in: result, type, layout, label)
        }
    }

    func test_repaginatingFromOneOfItsOwnPageBreaks_changesNothing() {
        // Re-opening on a page, or a re-pagination that doesn't change the page
        // area: the same pages, paired into spreads as before (a kept page
        // only opens a spread of its own when pairing would put it on the right).
        forEachLayout { _, type, layout, label in
            let before = paginate(type, layout, isFirstChapter: true)
            let lefts = before.pages.filter { $0.pageIndex % 2 == 0 && !$0.paragraphIndices.isEmpty }
            guard let start = ReaderPaginator.start(of: lefts[lefts.count / 2], atoms: before.atoms) else {
                return XCTFail("\(label): no text on a mid-chapter page")
            }
            let after = paginate(type, layout, isFirstChapter: true, startingAt: start)
            XCTAssertEqual(after.pages.map(\.paragraphIndices), before.pages.map(\.paragraphIndices), label)
            XCTAssertFalse(after.pages.contains(where: \.startsSpread), "\(label): a spread re-paired")
        }
    }

    /// The nav bar and page footer on an iPhone: what the page area gains when
    /// the controls hide, and loses when they show.
    static let controlsHeight: CGFloat = 84

    func test_showingOrHidingTheControls_keepsThePageInPlace() throws {
        // Pages fill the area on screen either way: hiding the controls used to
        // leave their room blank at the foot of every page. Re-paginating starts
        // a page where the one on screen did, so it keeps its first line.
        try forEachLayout { _, type, layout, label in
            let before = paginate(type, layout)
            let page = before.pages[before.pages.count / 2]
            let pageStart = try XCTUnwrap(ReaderPaginator.start(of: page, atoms: before.atoms))
            let firstWords = String(before.atoms[page.paragraphIndices.lowerBound].text.characters)
            for change in [Self.controlsHeight, -Self.controlsHeight] {
                let context = "\(label), \(change > 0 ? "controls hidden" : "controls shown")"
                let resized = Layout(columnWidth: layout.columnWidth, viewportHeight: layout.viewportHeight + change,
                                     pagesOnScreen: layout.pagesOnScreen)
                let after = paginate(type, resized, startingAt: pageStart)
                // The page kept in place starts where it did.
                let kept = after.pages.first { ReaderPaginator.start(of: $0, atoms: after.atoms) == pageStart }
                guard let keptPage = kept else {
                    XCTFail("\(context): no page starts where the one on screen did")
                    continue
                }
                let keptWords = String(after.atoms[keptPage.paragraphIndices.lowerBound].text.characters)
                let n = min(firstWords.count, keptWords.count)
                XCTAssertEqual(keptWords.prefix(n), firstWords.prefix(n), "\(context): the kept page opens with the same words")
                assertEverySentenceOnOnePage(after, context)
                assertPagesFit(after, type, resized, context)
                // From the kept page on, pages fill the new area (the one before it may be short).
                assertPagesFull(after.pages.drop { $0.id != keptPage.id }.dropLast(), in: after, type, resized, context)
                if layout.pagesOnScreen == 2 {
                    XCTAssertTrue(ReaderSpread.spreads(from: after.pages).contains { $0.left.id == keptPage.id },
                                  "\(context): the kept page stays on the left of its spread")
                }
            }
        }
    }
}


/// ⌘+ / ⌘− (Reader → Bigger / Smaller Text) step the reader's text size.
final class ReaderFontSizeStepTests: XCTestCase {
    func test_stepsByAPointEachWay() {
        XCTAssertEqual(ReaderMetrics.steppedFontSize(18, bigger: true), 19)
        XCTAssertEqual(ReaderMetrics.steppedFontSize(18, bigger: false), 17)
    }

    func test_staysInsideTheSlidersRange() {
        let range = ReaderMetrics.fontSizeRange
        XCTAssertEqual(ReaderMetrics.steppedFontSize(range.upperBound, bigger: true), range.upperBound)
        XCTAssertEqual(ReaderMetrics.steppedFontSize(range.lowerBound, bigger: false), range.lowerBound)
        XCTAssertEqual(ReaderMetrics.steppedFontSize(40, bigger: false), range.upperBound)
        XCTAssertEqual(ReaderMetrics.steppedFontSize(4, bigger: true), range.lowerBound)
    }

    /// A slider-set size between points lands on the next whole point.
    func test_fractionalSizeSnapsToTheNextWholePoint() {
        XCTAssertEqual(ReaderMetrics.steppedFontSize(18.4, bigger: true), 19)
        XCTAssertEqual(ReaderMetrics.steppedFontSize(18.4, bigger: false), 18)
    }

    func test_invalidStoredSizeStepsFromTheDefault() {
        XCTAssertEqual(ReaderMetrics.steppedFontSize(.nan, bigger: true), ReaderMetrics.defaultFontSize + 1)
    }
}
