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
}
