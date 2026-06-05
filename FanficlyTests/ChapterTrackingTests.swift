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
