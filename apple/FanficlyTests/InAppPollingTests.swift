import XCTest
import UserNotifications
@testable import Fanficly

/// Checking for new chapters while the app is open (#185): a minute after
/// launch, then every four hours, never sooner than four hours after the last
/// check, and stopped cleanly. Alerts posted while the app is in front show.
@MainActor
final class InAppPollingTests: XCTestCase {
    private let hour: TimeInterval = 60 * 60
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    private final class Recorder {
        var sleeps: [TimeInterval] = []
        var polls = 0
    }

    // MARK: First delay

    func test_firstDelay_isAMinuteWithNoEarlierCheck() {
        XCTAssertEqual(InAppPolling.firstDelay(lastPoll: nil, now: now), 60)
    }

    func test_firstDelay_waitsOutTheIntervalSinceTheLastCheck() {
        let delay = InAppPolling.firstDelay(lastPoll: now.addingTimeInterval(-hour), now: now)
        XCTAssertEqual(delay, 3 * hour, accuracy: 0.001)
    }

    func test_firstDelay_isAMinuteOnceTheIntervalHasPassed() {
        XCTAssertEqual(InAppPolling.firstDelay(lastPoll: now.addingTimeInterval(-5 * hour), now: now), 60)
        // Just short of due still gives launch work its minute.
        XCTAssertEqual(InAppPolling.firstDelay(lastPoll: now.addingTimeInterval(-4 * hour + 10), now: now), 60)
    }

    func test_firstDelay_neverExceedsTheInterval() {
        // The clock went back: the last check looks like it's in the future.
        let delay = InAppPolling.firstDelay(lastPoll: now.addingTimeInterval(2 * hour), now: now)
        XCTAssertEqual(delay, InAppPolling.interval)
    }

    func test_interval_matchesBackgroundRefresh() {
        XCTAssertEqual(InAppPolling.interval, 4 * hour)
        XCTAssertEqual(InAppPolling.interval, BackgroundRefresh.defaultInterval)
    }

    // MARK: Schedule

    func test_checksAfterAMinuteThenEveryInterval() async {
        let recorder = Recorder()
        let polling = InAppPolling(
            sleep: { seconds in
                recorder.sleeps.append(seconds)
                // End the run on the fourth wait.
                if recorder.sleeps.count > 3 { throw CancellationError() }
            },
            lastPoll: { nil },
            now: { self.now }
        )
        polling.start { recorder.polls += 1 }
        await polling.loop?.value

        XCTAssertEqual(recorder.sleeps, [60, 4 * hour, 4 * hour, 4 * hour])
        XCTAssertEqual(recorder.polls, 3)
    }

    func test_returningSoonAfterACheck_waitsForTheRestOfTheInterval() async {
        let recorder = Recorder()
        let polling = InAppPolling(
            sleep: { seconds in
                recorder.sleeps.append(seconds)
                throw CancellationError()
            },
            lastPoll: { self.now.addingTimeInterval(-30 * 60) },
            now: { self.now }
        )
        polling.start { recorder.polls += 1 }
        await polling.loop?.value

        XCTAssertEqual(recorder.sleeps.count, 1)
        XCTAssertEqual(recorder.sleeps[0], 3.5 * hour, accuracy: 0.001)
        XCTAssertEqual(recorder.polls, 0)
    }

    func test_startWhileRunning_keepsOneSchedule() {
        let polling = InAppPolling(
            sleep: { try await Task.sleep(for: .seconds($0)) },
            lastPoll: { nil },
            now: { self.now }
        )
        polling.start {}
        let first = polling.loop
        polling.start {}
        XCTAssertNotNil(first)
        XCTAssertEqual(polling.loop, first)
        polling.stop()
    }

    func test_stop_cancelsBeforeAnyCheck() async {
        let recorder = Recorder()
        let polling = InAppPolling(
            sleep: { try await Task.sleep(for: .seconds($0)) },
            lastPoll: { nil },
            now: { self.now }
        )
        polling.start { recorder.polls += 1 }
        let loop = polling.loop
        polling.stop()
        XCTAssertNil(polling.loop)
        await loop?.value

        XCTAssertEqual(recorder.polls, 0)
        XCTAssertTrue(loop?.isCancelled ?? false)
    }

    func test_stopThenStart_runsAFreshSchedule() async {
        let recorder = Recorder()
        let polling = InAppPolling(
            sleep: { seconds in
                recorder.sleeps.append(seconds)
                if recorder.sleeps.count > 1 { throw CancellationError() }
                try await Task.sleep(for: .seconds(seconds))
            },
            lastPoll: { nil },
            now: { self.now }
        )
        polling.start { recorder.polls += 1 }
        let first = polling.loop
        polling.stop()
        await first?.value
        polling.start { recorder.polls += 1 }
        XCTAssertNotNil(polling.loop)
        XCTAssertNotEqual(polling.loop, first)
        await polling.loop?.value
        XCTAssertEqual(recorder.polls, 0)
    }

    // MARK: Alerts while the app is in front

    func test_alertsShowWhileTheAppIsInFront() {
        let options = NotificationTapHandler.foregroundPresentation
        XCTAssertTrue(options.contains(.banner))
        XCTAssertTrue(options.contains(.list))
    }
}
