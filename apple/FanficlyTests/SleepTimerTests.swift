import AVFoundation
import XCTest
@testable import Fanficly

/// The Listen sleep timer (#182): 15, 30 or 60 minutes, or the end of the
/// chapter, always pausing between paragraphs.
final class SleepTimerTests: XCTestCase {
    func test_choicesAreTheIssuesFour() {
        XCTAssertEqual(SleepTimer.choices, [.minutes(15), .minutes(30), .minutes(60), .endOfChapter])
        XCTAssertEqual(SleepTimer.choices.map(\.title), ["15 minutes", "30 minutes", "1 hour", "End of chapter"])
    }

    func test_timedChoicesRunTheirMinutes() {
        XCTAssertEqual(SleepTimer.minutes(15).duration, 900)
        XCTAssertEqual(SleepTimer.minutes(60).duration, 3600)
        XCTAssertNil(SleepTimer.endOfChapter.duration)
    }

    func test_runningOutWhilePlayingPausesAfterTheParagraph() {
        XCTAssertEqual(SpeechController.sleepTimerRanOut(isPlaying: true), .pauseAfterParagraph)
    }

    func test_runningOutWhilePausedLeavesNothingPending() {
        XCTAssertEqual(SpeechController.sleepTimerRanOut(isPlaying: false), .nothingToPause)
    }

    func test_onlyEndOfChapterPausesAtTheChaptersEnd() {
        XCTAssertTrue(SpeechController.pausesAtChapterEnd(.endOfChapter))
        XCTAssertFalse(SpeechController.pausesAtChapterEnd(.minutes(15)))
        XCTAssertFalse(SpeechController.pausesAtChapterEnd(nil))
    }

    func test_aPendingPauseStopsBeforeTheNextParagraph() {
        XCTAssertEqual(SpeechController.paragraphEnd(isLast: false, sleepPausePending: true), .pause)
        XCTAssertEqual(SpeechController.paragraphEnd(isLast: false, sleepPausePending: false), .carryOn)
    }

    func test_theLastParagraphAlwaysFinishesTheChapter() {
        // A pending pause then holds the next chapter at its start (play()).
        XCTAssertEqual(SpeechController.paragraphEnd(isLast: true, sleepPausePending: true), .finishChapter)
        XCTAssertEqual(SpeechController.paragraphEnd(isLast: true, sleepPausePending: false), .finishChapter)
    }
}

/// Settings' Play Sample (#193) speaks at the stored Listen rate, kept to
/// what AVSpeech takes.
final class SpeechSampleTests: XCTestCase {
    func test_rateIsTheStoredRateWithinAVSpeechsRange() {
        XCTAssertEqual(SpeechSample.utteranceRate(Double(AVSpeechUtteranceDefaultSpeechRate)),
                       AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertEqual(SpeechSample.utteranceRate(0.6), 0.6)
        XCTAssertEqual(SpeechSample.utteranceRate(5), AVSpeechUtteranceMaximumSpeechRate)
        XCTAssertEqual(SpeechSample.utteranceRate(-1), AVSpeechUtteranceMinimumSpeechRate)
    }

    func test_sampleIsTheWindowsAppsPassage() {
        XCTAssertEqual(SpeechSample.text,
                       "Bella poured the latte. It was hot. Edward looked up from the corner table and met her eyes.")
    }
}
