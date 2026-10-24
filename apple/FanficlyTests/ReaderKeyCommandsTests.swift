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
        XCTAssertEqual(action(.down, .paginated), .scrollLine(forward: true))
    }

    func test_continuous() {
        XCTAssertEqual(action(.right, .continuous), .scrollScreen(forward: true))
        XCTAssertEqual(action(.pageUp, .continuous), .scrollScreen(forward: false))
        XCTAssertEqual(action(.space, .continuous), .scrollScreen(forward: true))
        XCTAssertEqual(action(.up, .continuous), .scrollLine(forward: false))
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
