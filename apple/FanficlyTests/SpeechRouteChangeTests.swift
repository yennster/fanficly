import AVFoundation
import XCTest
@testable import Fanficly

/// Listen pauses when the headphones it was playing through go away (#162),
/// and only then; a speed change never starts paused narration.
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

    func test_speedChangeWhilePausedDropsTheQueueWithoutSpeaking() {
        XCTAssertEqual(SpeechController.rateChange(isActive: true, isPlaying: false), .dropQueue)
    }

    func test_speedChangeWhilePlayingRequeues() {
        XCTAssertEqual(SpeechController.rateChange(isActive: true, isPlaying: true), .requeue)
    }

    func test_speedChangeWithNothingLoadedDoesNothing() {
        XCTAssertEqual(SpeechController.rateChange(isActive: false, isPlaying: false), .none)
    }
}
