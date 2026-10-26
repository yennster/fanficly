import XCTest
@testable import Fanficly

/// "Volume buttons turn pages": which way a volume change turns, and the
/// volume held while watching.
final class VolumeButtonTurnTests: XCTestCase {
    private let step = VolumeButtonTurn.step

    func test_offByDefaultKey() {
        XCTAssertEqual(VolumeButtonTurn.settingKey, "reader.volumeButtonsTurnPages")
        XCTAssertFalse(UserDefaults(suiteName: #function)!.bool(forKey: VolumeButtonTurn.settingKey))
    }

    func test_upTurnsForwardDownTurnsBack() {
        XCTAssertEqual(VolumeButtonTurn.direction(from: 0.5, to: 0.5 + step), true)
        XCTAssertEqual(VolumeButtonTurn.direction(from: 0.5, to: 0.5 - step), false)
    }

    func test_theResetItselfDoesNothing() {
        XCTAssertNil(VolumeButtonTurn.direction(from: 0.5, to: 0.5))
        // Float rounding on the way back to the held volume.
        XCTAssertNil(VolumeButtonTurn.direction(from: 0.5, to: 0.5001))
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
