import XCTest
@testable import Fanficly

final class ChapterTrackingTests: XCTestCase {
    func test_keyRoundTrips() {
        let key = ChapterTracking.key(chapter: 12, paragraph: 3)
        XCTAssertEqual(key, "c12-p3")
        let parsed = ChapterTracking.parse(key)
        XCTAssertEqual(parsed?.chapter, 12)
        XCTAssertEqual(parsed?.paragraph, 3)
    }

    func test_topmostAnchorPicksGreatestPassedOffset() {
        // Paragraph offsets in scroll-content coords (decreasing as you scroll).
        let offsets: [String: CGFloat] = [
            "c1-p0": -400,  // scrolled well past
            "c1-p1": -120,
            "c1-p2": 40,    // just above threshold (current top)
            "c1-p3": 300,   // below the fold
        ]
        let anchor = ChapterTracking.topmostAnchor(offsets, threshold: 80)
        XCTAssertEqual(anchor?.chapter, 1)
        XCTAssertEqual(anchor?.paragraph, 2)
    }

    // MARK: - End-of-content detection (100% progress)

    func test_endOfContentAnchorWhenFinalParagraphTopEntersViewport() {
        // Scrolled to the very bottom of a 60-paragraph one-shot: the final
        // paragraph's top edge is inside the 800pt viewport, even though the
        // *topmost* anchor is still a screenful earlier.
        let offsets: [String: CGFloat] = [
            "c1-p48": -200,
            "c1-p54": 250,
            "c1-p59": 620,
        ]
        let end = ChapterTracking.endOfContentAnchor(
            offsets, lastChapter: 1, lastParagraph: 59, viewportHeight: 800)
        XCTAssertEqual(end, ReadingAnchor(chapter: 1, paragraph: 59))
        // The old topmost-anchor path alone would have stalled progress here.
        XCTAssertEqual(ChapterTracking.topmostAnchor(offsets)?.paragraph, 48)
    }

    func test_endOfContentAnchorNilWhileEndStillBelowViewport() {
        let offsets: [String: CGFloat] = [
            "c1-p54": 150,
            "c1-p59": 1200,  // laid out (lazy pre-render) but below the fold
        ]
        XCTAssertNil(ChapterTracking.endOfContentAnchor(
            offsets, lastChapter: 1, lastParagraph: 59, viewportHeight: 800))
    }

    func test_endOfContentAnchorNilWhenFinalParagraphNotLaidOut() {
        let offsets: [String: CGFloat] = ["c1-p0": 0, "c1-p6": 300]
        XCTAssertNil(ChapterTracking.endOfContentAnchor(
            offsets, lastChapter: 1, lastParagraph: 59, viewportHeight: 800))
    }

    func test_endOfContentAnchorMatchesFinalChapterOnly() {
        // A mid-work chapter ending on screen isn't the end of the work.
        let offsets: [String: CGFloat] = ["c2-p59": 500]
        XCTAssertNil(ChapterTracking.endOfContentAnchor(
            offsets, lastChapter: 3, lastParagraph: 59, viewportHeight: 800))
    }

    // MARK: - Anchor stride

    func test_finalParagraphAlwaysCarriesAnchor() {
        // Every 6th paragraph is anchored — plus always the final one, or a
        // fully-read chapter could never report its true end.
        XCTAssertTrue(ChapterContentView.isAnchorIndex(0, count: 60))
        XCTAssertTrue(ChapterContentView.isAnchorIndex(54, count: 60))
        XCTAssertFalse(ChapterContentView.isAnchorIndex(55, count: 60))
        XCTAssertTrue(ChapterContentView.isAnchorIndex(59, count: 60))  // final, off-stride
        XCTAssertTrue(ChapterContentView.isAnchorIndex(60, count: 61))  // final, on-stride
        XCTAssertTrue(ChapterContentView.isAnchorIndex(0, count: 1))
    }

    func test_currentChapterExcludesTitle() {
        let offsets: [Int: CGFloat] = [0: -500, 1: -100, 2: 200]
        XCTAssertEqual(ChapterTracking.currentChapter(offsets: offsets), 1)
    }

    // MARK: - adjacentChapter (tap-to-turn page zones)

    func test_adjacentChapterMovesForwardAndBack() {
        let order = [1, 2, 3, 4]
        XCTAssertEqual(ChapterTracking.adjacentChapter(in: order, current: 2, forward: true), 3)
        XCTAssertEqual(ChapterTracking.adjacentChapter(in: order, current: 2, forward: false), 1)
    }

    func test_adjacentChapterClampsAtEnds() {
        let order = [1, 2, 3]
        XCTAssertNil(ChapterTracking.adjacentChapter(in: order, current: 3, forward: true))
        XCTAssertNil(ChapterTracking.adjacentChapter(in: order, current: 1, forward: false))
    }

    func test_adjacentChapterFollowsReadingOrderNotIndexValue() {
        // Indices need not be contiguous or 1-based; navigation follows the
        // array order, stepping to the literal neighbour index.
        let order = [3, 7, 8, 15]
        XCTAssertEqual(ChapterTracking.adjacentChapter(in: order, current: 7, forward: true), 8)
        XCTAssertEqual(ChapterTracking.adjacentChapter(in: order, current: 15, forward: false), 8)
    }

    func test_adjacentChapterUnknownCurrentReturnsNil() {
        XCTAssertNil(ChapterTracking.adjacentChapter(in: [1, 2, 3], current: 9, forward: true))
    }
}
