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

