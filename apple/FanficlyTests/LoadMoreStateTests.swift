import XCTest
@testable import Fanficly

/// The next-page bookkeeping behind every infinite-scroll list (#154): a
/// failed page keeps its own error, and a page-1 reload drops stale pages.
/// Pages the content filter hides entirely load on by themselves, up to a
/// limit (#155).
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

    func test_aHiddenPageLoadsTheNextUntilTheLimit() {
        var paging = LoadMoreState()
        for _ in 1..<LoadMoreState.hiddenPageLimit {
            XCTAssertTrue(paging.landed(newRows: 0, hasMore: true))
            XCTAssertFalse(paging.stoppedOnHiddenPages)
        }
        // The last one allowed: stop and offer Load More.
        XCTAssertFalse(paging.landed(newRows: 0, hasMore: true))
        XCTAssertTrue(paging.stoppedOnHiddenPages)

        // Load More (or a row coming into view) allows another run.
        paging.resume()
        XCTAssertFalse(paging.stoppedOnHiddenPages)
        XCTAssertTrue(paging.landed(newRows: 0, hasMore: true))
    }

    func test_aPageWithVisibleRowsStopsTheRun() {
        var paging = LoadMoreState()
        XCTAssertTrue(paging.landed(newRows: 0, hasMore: true))
        // The new rows' own infinite scroll takes it from here.
        XCTAssertFalse(paging.landed(newRows: 2, hasMore: true))
        XCTAssertEqual(paging.hiddenPages, 0)
    }

    func test_theLastPageNeverOffersLoadMore() {
        var paging = LoadMoreState()
        for _ in 1..<LoadMoreState.hiddenPageLimit {
            _ = paging.landed(newRows: 0, hasMore: true)
        }
        XCTAssertFalse(paging.landed(newRows: 0, hasMore: false))
        XCTAssertFalse(paging.stoppedOnHiddenPages)
    }

    func test_restartForgetsHiddenPages() {
        var paging = LoadMoreState()
        for _ in 0..<LoadMoreState.hiddenPageLimit {
            _ = paging.landed(newRows: 0, hasMore: true)
        }
        XCTAssertTrue(paging.stoppedOnHiddenPages)

        paging.restart()

        XCTAssertFalse(paging.stoppedOnHiddenPages)
    }
}
