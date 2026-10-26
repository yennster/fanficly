import XCTest
@testable import Fanficly

/// "Volume buttons turn pages": which way a volume change turns, and the
/// volume held while watching.
final class VolumeButtonTurnTests: XCTestCase {
    private let step = VolumeButtonTurn.step

    private func direction(_ old: Float, _ new: Float, pending: Float? = nil) -> Bool? {
        VolumeButtonTurn.direction(from: old, to: new, pendingReset: pending)
    }

    func test_upTurnsForwardDownTurnsBack() {
        XCTAssertEqual(direction(0.5, 0.5 + step), true)
        XCTAssertEqual(direction(0.5, 0.5 - step), false)
    }

    func test_directionIsFromTheLastReportNotTheBaseline() {
        // The reset hasn't landed: 0.5625 → 0.625 is still a press up, and
        // 0.625 → 0.5625 a press down, though both are above the baseline.
        XCTAssertEqual(direction(0.5 + step, 0.5 + 2 * step), true)
        XCTAssertEqual(direction(0.5 + 2 * step, 0.5 + step), false)
    }

    func test_theResetItselfDoesNothing() {
        XCTAssertNil(direction(0.5 + step, 0.5, pending: 0.5))
        // Float rounding on the way back to the held volume.
        XCTAssertNil(direction(0.5 + step, 0.5001, pending: 0.5))
        XCTAssertNil(direction(0.5, 0.5))
    }

    func test_baselineMovesOffTheEnds() {
        // A press past full or silent changes nothing iOS reports.
        XCTAssertEqual(VolumeButtonTurn.baseline(for: 1), 1 - step)
        XCTAssertEqual(VolumeButtonTurn.baseline(for: 0), step)
        XCTAssertEqual(VolumeButtonTurn.baseline(for: 0.5), 0.5)
    }

    func test_volumeTurnsLikePageDownAndPageUp() {
        XCTAssertEqual(ReaderKeyAction.action(for: .pageDown, shift: false, otherModifiers: false, mode: .pageByPage),
                       .turnPage(forward: true))
        XCTAssertEqual(ReaderKeyAction.action(for: .pageUp, shift: false, otherModifiers: false, mode: .continuous),
                       .scrollScreen(forward: false))
    }
}
