import XCTest
@testable import Fanficly

/// A widget tap must never move saved reading progress backwards. The widget's
/// deep-link URL bakes in an anchor from whenever WidgetKit last reloaded the
/// timeline — potentially hours stale — so it may only seed progress that
/// doesn't exist yet; only a strictly fresher widget-store entry (progress
/// synced from another device) may override a local record.
final class ResumeProgressPolicyTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_700_000_000)
    private var earlier: Date { noon.addingTimeInterval(-3600) }
    private var later: Date { noon.addingTimeInterval(3600) }

    private let urlAnchor = ReadingAnchor(chapter: 2, paragraph: 5)
    private let storeAnchor = ReadingAnchor(chapter: 10, paragraph: 3)

    // The audit's scenario 1: same work, local save stamped ReadingProgress and
    // the widget payload with the same date, but the tapped URL carries an old
    // anchor. Equal timestamps must NOT let the URL anchor through.
    func test_equalTimestamps_staleURLAnchorDoesNotOverwrite() {
        let anchor = ResumeProgressPolicy.anchorToInstall(
            routeAnchor: urlAnchor,
            widgetAnchor: storeAnchor,
            widgetFreshness: noon,
            existingUpdatedAt: noon
        )
        XCTAssertNil(anchor)
    }

    // The audit's scenario 2: the widget store now holds a different work, so
    // there's no matching entry (nil anchor/freshness) — the stale URL anchor
    // must not overwrite the existing progress for the tapped work.
    func test_widgetShowsOtherWork_staleURLAnchorDoesNotOverwrite() {
        let anchor = ResumeProgressPolicy.anchorToInstall(
            routeAnchor: urlAnchor,
            widgetAnchor: nil,
            widgetFreshness: nil,
            existingUpdatedAt: noon
        )
        XCTAssertNil(anchor)
    }

    func test_olderStoreEntry_doesNotOverwrite() {
        let anchor = ResumeProgressPolicy.anchorToInstall(
            routeAnchor: urlAnchor,
            widgetAnchor: storeAnchor,
            widgetFreshness: earlier,
            existingUpdatedAt: noon
        )
        XCTAssertNil(anchor)
    }

    // The legitimate override: another device read further and its progress
    // synced through the widget store with a strictly newer stamp.
    func test_strictlyFresherStoreEntry_installsStoreAnchorNotURL() {
        let anchor = ResumeProgressPolicy.anchorToInstall(
            routeAnchor: urlAnchor,
            widgetAnchor: storeAnchor,
            widgetFreshness: later,
            existingUpdatedAt: noon
        )
        XCTAssertEqual(anchor, storeAnchor)
    }

    // A fresher store entry without chapter data has nothing safe to install —
    // the untimestamped URL anchor must not ride in on its freshness.
    func test_fresherStoreEntryWithoutAnchor_installsNothing() {
        let anchor = ResumeProgressPolicy.anchorToInstall(
            routeAnchor: urlAnchor,
            widgetAnchor: nil,
            widgetFreshness: later,
            existingUpdatedAt: noon
        )
        XCTAssertNil(anchor)
    }

    // No local progress yet (fresh install / cleared data): seeding is safe,
    // and the store payload wins over the possibly-stale URL snapshot.
    func test_noLocalProgress_prefersStoreAnchorOverURL() {
        let anchor = ResumeProgressPolicy.anchorToInstall(
            routeAnchor: urlAnchor,
            widgetAnchor: storeAnchor,
            widgetFreshness: earlier,
            existingUpdatedAt: nil
        )
        XCTAssertEqual(anchor, storeAnchor)
    }

    func test_noLocalProgress_fallsBackToURLAnchor() {
        let anchor = ResumeProgressPolicy.anchorToInstall(
            routeAnchor: urlAnchor,
            widgetAnchor: nil,
            widgetFreshness: nil,
            existingUpdatedAt: nil
        )
        XCTAssertEqual(anchor, urlAnchor)
    }

    func test_nothingAvailable_installsNothing() {
        let anchor = ResumeProgressPolicy.anchorToInstall(
            routeAnchor: nil,
            widgetAnchor: nil,
            widgetFreshness: nil,
            existingUpdatedAt: nil
        )
        XCTAssertNil(anchor)
    }
}
