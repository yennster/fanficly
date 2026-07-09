import XCTest
@testable import Fanficly

final class ThrottleActorTests: XCTestCase {
    func test_firstCallDoesNotWait() async {
        let throttle = ThrottleActor(minimumInterval: 1.0)
        let start = Date()
        await throttle.wait()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2, "first call should be immediate")
    }

    func test_secondCallWaitsTheInterval() async {
        let throttle = ThrottleActor(minimumInterval: 0.4)
        await throttle.wait()
        let start = Date()
        await throttle.wait()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.25, "second call should be throttled")
    }

    /// Concurrent callers must each get a distinct, strictly-spaced slot — they
    /// must NOT all sleep to the same instant and fire together. The old
    /// implementation set `nextEarliest` only after sleeping, so a burst leaked
    /// through at once; this guards against that regression (which overran AO3's
    /// rate limit and led to stalls/timeouts).
    func test_concurrentCallsAreSerializedNotBursted() async {
        let interval = 0.2
        let throttle = ThrottleActor(minimumInterval: interval)
        let count = 5

        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask { await throttle.wait() }
            }
        }
        let elapsed = Date().timeIntervalSince(start)

        // N calls spaced by `interval` take at least (N-1)*interval overall. If
        // they had bursted, this would be ~0.
        let expectedMinimum = Double(count - 1) * interval
        XCTAssertGreaterThan(elapsed, expectedMinimum * 0.8,
                             "concurrent calls should be spaced, not fired in a burst")
    }
}
