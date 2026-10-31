import AVFoundation
import XCTest
@testable import Fanficly

/// Listen pauses when the headphones it was playing through go away (#162),
/// and only then.
final class SpeechRouteChangeTests: XCTestCase {
    func test_losingTheOutputDevicePauses() {
        XCTAssertTrue(SpeechController.pausesNarration(for: .oldDeviceUnavailable))
    }

    func test_otherRouteChangesKeepPlaying() {
        let others: [AVAudioSession.RouteChangeReason] = [
            .unknown, .newDeviceAvailable, .categoryChange, .override,
            .wakeFromSleep, .noSuitableRouteForCategory, .routeConfigurationChange,
        ]
        for reason in others {
            XCTAssertFalse(SpeechController.pausesNarration(for: reason), "\(reason.rawValue)")
        }
    }
}
