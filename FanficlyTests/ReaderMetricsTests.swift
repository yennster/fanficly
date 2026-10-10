import XCTest
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
