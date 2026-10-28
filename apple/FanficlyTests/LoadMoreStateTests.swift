import XCTest
@testable import Fanficly

/// The next-page bookkeeping behind every infinite-scroll list (#154): a
/// failed page keeps its own error, and a page-1 reload drops stale pages.
@MainActor
final class LoadMoreStateTests: XCTestCase {
    func test_failureIsKeptSeparatelyUntilTheNextTry() {
        var paging = LoadMoreState()
        let generation = paging.begin()
        XCTAssertTrue(paging.fail("Couldn't load more: AO3 returned HTTP 502.", generation: generation))
        XCTAssertEqual(paging.error, "Couldn't load more: AO3 returned HTTP 502.")

        // Try Again starts another load, which clears the footer.
        _ = paging.begin()
        XCTAssertNil(paging.error)
    }

    func test_restartMakesAPageInFlightStale() {
        var paging = LoadMoreState()
        let generation = paging.begin()
        XCTAssertTrue(paging.isCurrent(generation))

        paging.restart()  // a new search or filters while the page was loading

        XCTAssertFalse(paging.isCurrent(generation))
        XCTAssertFalse(paging.fail("timed out", generation: generation))
        XCTAssertNil(paging.error)
        XCTAssertTrue(paging.isCurrent(paging.begin()))
    }

    func test_restartClearsAnEarlierFailure() {
        var paging = LoadMoreState()
        let generation = paging.begin()
        paging.fail("timed out", generation: generation)
        XCTAssertNotNil(paging.error)

        paging.restart()

        XCTAssertNil(paging.error)
    }
}
