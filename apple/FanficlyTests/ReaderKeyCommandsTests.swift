import SwiftUI
import XCTest
@testable import Fanficly

/// Keyboard and Bluetooth page-turner keys in the reader.
final class ReaderKeyCommandsTests: XCTestCase {
    private func action(_ key: ReaderKey, shift: Bool = false, other: Bool = false,
                        _ mode: ReadingMode) -> ReaderKeyAction? {
        ReaderKeyAction.action(for: key, shift: shift, otherModifiers: other, mode: mode)
    }

    func test_keyEquivalentsMap() {
        XCTAssertEqual(ReaderKey(.pageDown), .pageDown)
        XCTAssertEqual(ReaderKey(.upArrow), .up)
        XCTAssertEqual(ReaderKey(.space), .space)
        XCTAssertNil(ReaderKey(.return))
        XCTAssertEqual(ReaderKey.all.count, 7)
    }

    func test_pageByPageTurnsOnEveryKey() {
        // Remotes send any of these; all of them turn the page.
        for key in [ReaderKey.right, .down, .pageDown, .space] {
            XCTAssertEqual(action(key, .pageByPage), .turnPage(forward: true), "\(key)")
        }
        for key in [ReaderKey.left, .up, .pageUp] {
            XCTAssertEqual(action(key, .pageByPage), .turnPage(forward: false), "\(key)")
        }
        XCTAssertEqual(action(.space, shift: true, .pageByPage), .turnPage(forward: false))
    }

    func test_swipeByChapter() {
        XCTAssertEqual(action(.right, .paginated), .turnChapter(forward: true))
        XCTAssertEqual(action(.left, .paginated), .turnChapter(forward: false))
        XCTAssertEqual(action(.pageDown, .paginated), .scrollScreen(forward: true))
        XCTAssertEqual(action(.space, shift: true, .paginated), .scrollScreen(forward: false))
        XCTAssertEqual(action(.down, .paginated), .scrollParagraph(forward: true))
    }

    func test_continuous() {
        XCTAssertEqual(action(.right, .continuous), .scrollScreen(forward: true))
        XCTAssertEqual(action(.pageUp, .continuous), .scrollScreen(forward: false))
        XCTAssertEqual(action(.space, .continuous), .scrollScreen(forward: true))
        XCTAssertEqual(action(.up, .continuous), .scrollParagraph(forward: false))
    }

    func test_modifiersPassThrough() {
        // ⌘← and friends belong to the system / other shortcuts.
        XCTAssertNil(action(.left, other: true, .pageByPage))
        XCTAssertNil(action(.right, shift: true, .pageByPage))
    }

    // MARK: - Scroll targets

    private let offsets: [String: CGFloat] = [
        "c1-p0": -500,
        "c1-p1": -200,
        "c1-p2": 0,     // the top paragraph
        "c1-p3": 300,
        "c1-p4": 650,   // last one starting within 90% of 800
        "c1-p5": 900,
    ]

    func test_screenfulForwardBringsUpLastParagraphInReach() {
        XCTAssertEqual(ChapterTracking.scrollTarget(offsets, viewportHeight: 800, forward: true, screenful: true),
                       ReadingAnchor(chapter: 1, paragraph: 4))
    }

    func test_screenfulBackGoesToFirstParagraphInReach() {
        XCTAssertEqual(ChapterTracking.scrollTarget(offsets, viewportHeight: 800, forward: false, screenful: true),
                       ReadingAnchor(chapter: 1, paragraph: 0))
    }

    func test_paragraphStep() {
        XCTAssertEqual(ChapterTracking.scrollTarget(offsets, viewportHeight: 800, forward: true, screenful: false),
                       ReadingAnchor(chapter: 1, paragraph: 3))
        XCTAssertEqual(ChapterTracking.scrollTarget(offsets, viewportHeight: 800, forward: false, screenful: false),
                       ReadingAnchor(chapter: 1, paragraph: 1))
    }

    func test_tallParagraphFallsBackToNextOne() {
        // The next paragraph starts below the screen: a screenful still moves on.
        let tall: [String: CGFloat] = ["c1-p0": 0, "c1-p1": 1400]
        XCTAssertEqual(ChapterTracking.scrollTarget(tall, viewportHeight: 800, forward: true, screenful: true),
                       ReadingAnchor(chapter: 1, paragraph: 1))
    }

    func test_crossesChapters() {
        let two: [String: CGFloat] = ["c1-p9": 0, "c2-p0": 400]
        XCTAssertEqual(ChapterTracking.scrollTarget(two, viewportHeight: 800, forward: true, screenful: true),
                       ReadingAnchor(chapter: 2, paragraph: 0))
    }

    func test_nilAtTheEnds() {
        let end: [String: CGFloat] = ["c1-p7": -300, "c1-p8": 0]
        XCTAssertNil(ChapterTracking.scrollTarget(end, viewportHeight: 800, forward: true, screenful: true))
        let start: [String: CGFloat] = ["c1-p0": 20, "c1-p1": 400]
        XCTAssertNil(ChapterTracking.scrollTarget(start, viewportHeight: 800, forward: false, screenful: true))
        XCTAssertNil(ChapterTracking.scrollTarget([:], viewportHeight: 800, forward: true, screenful: true))
    }
}
