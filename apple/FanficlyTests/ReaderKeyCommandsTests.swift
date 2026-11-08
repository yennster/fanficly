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
        XCTAssertEqual(ReaderKey(.home), .home)
        XCTAssertEqual(ReaderKey(.end), .end)
        XCTAssertNil(ReaderKey(.return))
        XCTAssertEqual(ReaderKey.all.count, 9)
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
        XCTAssertEqual(action(.down, .paginated), .scrollLine(forward: true))
    }

    func test_continuous() {
        XCTAssertEqual(action(.right, .continuous), .scrollScreen(forward: true))
        XCTAssertEqual(action(.pageUp, .continuous), .scrollScreen(forward: false))
        XCTAssertEqual(action(.space, .continuous), .scrollScreen(forward: true))
        XCTAssertEqual(action(.up, .continuous), .scrollLine(forward: false))
    }

    func test_homeAndEndGoToTheChapterEdgeInEveryMode() {
        for mode in ReadingMode.allCases {
            XCTAssertEqual(action(.home, mode), .chapterEdge(end: false), "\(mode)")
            XCTAssertEqual(action(.end, mode), .chapterEdge(end: true), "\(mode)")
            XCTAssertNil(action(.end, shift: true, mode), "\(mode)")
            XCTAssertNil(action(.home, other: true, mode), "\(mode)")
        }
    }

    func test_commandKeys() {
        XCTAssertEqual(ReaderCommandKey(key: .leftArrow, modifiers: .command), .chapter(forward: false))
        XCTAssertEqual(ReaderCommandKey(key: .rightArrow, modifiers: [.command, .capsLock]), .chapter(forward: true))
        XCTAssertEqual(ReaderCommandKey(key: "l", modifiers: .command), .listen)
        // Only ⌘ alone: ⇧⌘← (select to the line start) and a bare arrow pass.
        XCTAssertNil(ReaderCommandKey(key: .leftArrow, modifiers: [.command, .shift]))
        XCTAssertNil(ReaderCommandKey(key: .rightArrow, modifiers: []))
        XCTAssertNil(ReaderCommandKey(key: "l", modifiers: .control))
        XCTAssertNil(ReaderCommandKey(key: "f", modifiers: .command))
    }

    // MARK: - Home / End in page-by-page

    private func page(_ chapter: Int, _ index: Int) -> ChapterPage {
        ChapterPage(id: "c\(chapter)-p\(index)", chapterIndex: chapter, pageIndex: index, paragraphIndices: 0..<1)
    }

    private var pages: [ChapterPage] {
        [page(1, 0), page(1, 1), page(2, 0), page(2, 1), page(2, 2), page(3, 0)]
    }

    func test_chapterEdgePagesStayInTheChapter() {
        XCTAssertEqual(ReaderChapterEdge.pageId(in: pages, selected: "c2-p1", end: false, spreads: false), "c2-p0")
        XCTAssertEqual(ReaderChapterEdge.pageId(in: pages, selected: "c2-p1", end: true, spreads: false), "c2-p2")
        XCTAssertEqual(ReaderChapterEdge.pageId(in: pages, selected: "c1-p0", end: true, spreads: false), "c1-p1")
    }

    func test_chapterEdgeIsNilWhenAlreadyThere() {
        XCTAssertNil(ReaderChapterEdge.pageId(in: pages, selected: "c2-p0", end: false, spreads: false))
        XCTAssertNil(ReaderChapterEdge.pageId(in: pages, selected: "c3-p0", end: true, spreads: false))
        XCTAssertNil(ReaderChapterEdge.pageId(in: pages, selected: "missing", end: true, spreads: false))
    }

    func test_chapterEdgeInASpreadPicksTheSpread() {
        // Chapter 2 pairs as (p0, p1) and (p2): End from p0 lands on p2's
        // spread; from p1 (the right page of the first) too.
        XCTAssertEqual(ReaderChapterEdge.pageId(in: pages, selected: "c2-p0", end: true, spreads: true), "c2-p2")
        XCTAssertEqual(ReaderChapterEdge.pageId(in: pages, selected: "c2-p1", end: true, spreads: true), "c2-p2")
        // Home from the right page of the chapter's first spread is no move.
        XCTAssertNil(ReaderChapterEdge.pageId(in: pages, selected: "c2-p1", end: false, spreads: true))
        XCTAssertEqual(ReaderChapterEdge.pageId(in: pages, selected: "c2-p2", end: false, spreads: true), "c2-p0")
        // Chapter 1's last page is the right page of its only spread.
        XCTAssertNil(ReaderChapterEdge.pageId(in: pages, selected: "c1-p0", end: true, spreads: true))
    }

    func test_modifiersPassThrough() {
        // ⌘← and friends belong to the system / other shortcuts.
        XCTAssertNil(action(.left, other: true, .pageByPage))
        XCTAssertNil(action(.right, shift: true, .pageByPage))
    }

    // MARK: - Scroll offsets

    private func target(_ current: CGFloat, forward: Bool, screenful: Bool = true,
                        content: CGFloat = 5000, top: CGFloat = 100, bottom: CGFloat = 50) -> CGFloat? {
        ReaderKeyScroll.targetOffset(current: current, viewportHeight: 850, contentHeight: content,
                                     insetTop: top, insetBottom: bottom, forward: forward, screenful: screenful)
    }

    func test_screenfulIsNinetyPercentOfTheVisibleHeight() {
        // 850 tall less 150 of insets = 700 visible; 90% = 630.
        XCTAssertEqual(target(1000, forward: true), 1630)
        XCTAssertEqual(target(1000, forward: false), 370)
    }

    func test_lineStep() {
        XCTAssertEqual(target(1000, forward: true, screenful: false), 1048)
        XCTAssertEqual(target(1000, forward: false, screenful: false), 952)
    }

    func test_clampsToTheContent() {
        // Max offset = 5000 + 50 - 850 = 4200; min = -100 (the top inset).
        XCTAssertEqual(target(4000, forward: true), 4200)
        XCTAssertEqual(target(200, forward: false), -100)
    }

    func test_nilAtTheEdges() {
        XCTAssertNil(target(4200, forward: true))
        XCTAssertNil(target(4199.5, forward: true))
        XCTAssertNil(target(-100, forward: false))
        // Content shorter than the screen: already at both edges.
        XCTAssertNil(target(-100, forward: true, content: 300))
    }
}

/// Work links from a drop, ⌘V or Open AO3 Link….
final class WorkLinkTests: XCTestCase {
    func test_ao3WorkLinks() {
        XCTAssertEqual(WorkLink.workId(fromText: "https://archiveofourown.org/works/123456"), 123456)
        XCTAssertEqual(WorkLink.workId(fromText: "  https://archiveofourown.org/works/42/chapters/99?view_adult=true\n"), 42)
        XCTAssertEqual(WorkLink.workId(fromText: "archiveofourown.org/works/7"), 7)
    }

    func test_fanficlyLinks() {
        XCTAssertEqual(WorkLink.workId(fromText: "fanficly://works/55"), 55)
        let wrapped = "fanficly://import?url=" + "https://archiveofourown.org/works/77"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        XCTAssertEqual(WorkLink.workId(fromText: wrapped), 77)
    }

    func test_otherTextIsNotAWork() {
        XCTAssertNil(WorkLink.workId(fromText: ""))
        XCTAssertNil(WorkLink.workId(fromText: "hello there"))
        XCTAssertNil(WorkLink.workId(fromText: "https://archiveofourown.org/users/someone"))
        XCTAssertNil(WorkLink.workId(fromText: "https://archiveofourown.org/tags/Fluff/works"))
    }
}
