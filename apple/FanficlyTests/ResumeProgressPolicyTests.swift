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

/// Opening a story from the Library (not the widget) takes a strictly newer
/// place synced from another device too, and closing the reader without moving
/// writes nothing (#160).
final class OpeningProgressPolicyTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_700_000_000)
    private let local = ReadingAnchor(chapter: 12, paragraph: 4)
    private let other = ReadingAnchor(chapter: 20, paragraph: 7)

    private func synced(id: Int = 1, chapter: Int? = 20, paragraph: Int? = 7,
                        updatedAt: Date?) -> WidgetStoryProgress {
        WidgetStoryProgress(id: id, title: "T", author: "A", progress: 0.8,
                            chapter: chapter, paragraph: paragraph, updatedAt: updatedAt)
    }

    // The issue's scenario: chapter 20 read on the iPhone, the iPad last saw 12.
    // The iPad opens at 20, and closing without moving doesn't save 12 or 20.
    func test_fresherSyncedEntry_opensThereAndUnmovedCloseSavesNothing() {
        let opened = OpeningProgressPolicy.anchor(
            workId: 1, local: local, localUpdatedAt: noon,
            synced: synced(updatedAt: noon.addingTimeInterval(60)))
        XCTAssertEqual(opened, other)

        var gate = OpenedAnchorGate(openedAnchor: opened)
        XCTAssertFalse(gate.allowsSave(of: other), "closing where it opened must not re-stamp the place")
        XCTAssertFalse(gate.allowsSave(of: other))
    }

    func test_sameDeviceSave_tiesAndLocalWins() {
        XCTAssertEqual(OpeningProgressPolicy.anchor(
            workId: 1, local: local, localUpdatedAt: noon, synced: synced(updatedAt: noon)), local)
    }

    func test_olderSyncedEntry_localWins() {
        XCTAssertEqual(OpeningProgressPolicy.anchor(
            workId: 1, local: local, localUpdatedAt: noon,
            synced: synced(updatedAt: noon.addingTimeInterval(-60))), local)
    }

    func test_syncedEntryForAnotherWork_localWins() {
        XCTAssertEqual(OpeningProgressPolicy.anchor(
            workId: 1, local: local, localUpdatedAt: noon,
            synced: synced(id: 2, updatedAt: noon.addingTimeInterval(60))), local)
    }

    func test_fresherSyncedEntryWithoutChapter_localWins() {
        XCTAssertEqual(OpeningProgressPolicy.anchor(
            workId: 1, local: local, localUpdatedAt: noon,
            synced: synced(chapter: nil, paragraph: nil, updatedAt: noon.addingTimeInterval(60))), local)
    }

    // Never read here: the other device's place, whatever its date.
    func test_noLocalProgress_opensSyncedPlace() {
        XCTAssertEqual(OpeningProgressPolicy.anchor(
            workId: 1, local: nil, localUpdatedAt: nil, synced: synced(updatedAt: nil)), other)
        XCTAssertNil(OpeningProgressPolicy.anchor(
            workId: 1, local: nil, localUpdatedAt: nil, synced: nil))
    }

    func test_gate_movingSavesAndMovingBackSavesTheOpenedPlaceToo() {
        var gate = OpenedAnchorGate(openedAnchor: local)
        XCTAssertFalse(gate.allowsSave(of: local))
        XCTAssertTrue(gate.allowsSave(of: other))
        XCTAssertTrue(gate.allowsSave(of: local), "after a move the opened place is a real place again")
    }

    // Page by page: opened at (20,7), the page holding it starts at (20,3).
    func test_gate_landingOnThePageHoldingTheOpenedPlaceIsNotAMove() {
        let pageStart = ReadingAnchor(chapter: 20, paragraph: 3)
        var gate = OpenedAnchorGate(openedAnchor: other)
        gate.landed(on: pageStart, holdingOpened: true)
        XCTAssertFalse(gate.allowsSave(of: pageStart))
        XCTAssertTrue(gate.allowsSave(of: ReadingAnchor(chapter: 20, paragraph: 12)))

        var elsewhere = OpenedAnchorGate(openedAnchor: other)
        elsewhere.landed(on: pageStart, holdingOpened: false)
        XCTAssertTrue(elsewhere.allowsSave(of: pageStart))

        var moved = OpenedAnchorGate()
        moved.landed(on: pageStart, holdingOpened: true)
        XCTAssertTrue(moved.allowsSave(of: pageStart))
    }

    func test_gate_nothingOpened_savesEverything() {
        var gate = OpenedAnchorGate()
        XCTAssertTrue(gate.allowsSave(of: ReadingAnchor(chapter: 1, paragraph: 0)))
    }
}

/// "Continue Reading" opens whichever story was read last: the widget store's
/// entry (mirrored from other devices through iCloud KVS) or this device's
/// newest reading progress.
final class ContinueReadingPolicyTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    private func widget(id: Int, updatedAt: Date?) -> WidgetStoryProgress {
        WidgetStoryProgress(id: id, title: "T", author: "A", progress: 0.5,
                            chapter: 2, paragraph: 0, updatedAt: updatedAt)
    }

    func test_nothingRead_returnsNil() {
        XCTAssertNil(ContinueReadingPolicy.workId(
            widgetProgress: nil, latestLocalId: nil, latestLocalUpdatedAt: nil))
    }

    func test_onlyLocalProgress_opensIt() {
        XCTAssertEqual(ContinueReadingPolicy.workId(
            widgetProgress: nil, latestLocalId: 5, latestLocalUpdatedAt: noon), 5)
    }

    func test_onlyWidgetProgress_opensIt() {
        XCTAssertEqual(ContinueReadingPolicy.workId(
            widgetProgress: widget(id: 9, updatedAt: noon),
            latestLocalId: nil, latestLocalUpdatedAt: nil), 9)
    }

    // Read on another device later: its synced entry wins.
    func test_fresherWidgetEntry_wins() {
        XCTAssertEqual(ContinueReadingPolicy.workId(
            widgetProgress: widget(id: 9, updatedAt: noon.addingTimeInterval(60)),
            latestLocalId: 5, latestLocalUpdatedAt: noon), 9)
    }

    // A story without a progress fraction was read here since: local wins.
    func test_fresherLocalProgress_wins() {
        XCTAssertEqual(ContinueReadingPolicy.workId(
            widgetProgress: widget(id: 9, updatedAt: noon),
            latestLocalId: 5, latestLocalUpdatedAt: noon.addingTimeInterval(60)), 5)
    }

    // A local save stamps both stores with the same date.
    func test_tie_opensWidgetEntry() {
        XCTAssertEqual(ContinueReadingPolicy.workId(
            widgetProgress: widget(id: 5, updatedAt: noon),
            latestLocalId: 5, latestLocalUpdatedAt: noon), 5)
    }

    // An old widget payload with no date loses to any local progress.
    func test_undatedWidgetEntry_losesToLocal() {
        XCTAssertEqual(ContinueReadingPolicy.workId(
            widgetProgress: widget(id: 9, updatedAt: nil),
            latestLocalId: 5, latestLocalUpdatedAt: noon), 5)
    }
}

/// The global UI zoom's step and clamp (`UIZoom`, in RootView.swift beside
/// `ResumeProgressPolicy`): ⌘/⇧⌘ +/− and the View menu all go through it.
final class UIZoomTests: XCTestCase {
    func test_stepsByATenthEachWay() {
        XCTAssertEqual(UIZoom.stepped(1.0, in: true), 1.1)
        XCTAssertEqual(UIZoom.stepped(1.0, in: false), 0.9)
    }

    func test_upAtMaxStaysAtMax() {
        XCTAssertEqual(UIZoom.stepped(UIZoom.maxScale, in: true), UIZoom.maxScale)
        XCTAssertEqual(UIZoom.stepped(1.95, in: true), UIZoom.maxScale)
    }

    func test_downAtMinStaysAtMin() {
        XCTAssertEqual(UIZoom.stepped(UIZoom.minScale, in: false), UIZoom.minScale)
        XCTAssertEqual(UIZoom.stepped(0.55, in: false), UIZoom.minScale)
    }

    func test_actualSizeIsOne() {
        XCTAssertEqual(UIZoom.actualSize, 1.0)
    }

    /// Ten steps up and ten back land exactly on 1.0, not 0.9999999999999998.
    func test_repeatedStepsDontDrift() {
        var scale = UIZoom.actualSize
        for _ in 0..<5 { scale = UIZoom.stepped(scale, in: true) }
        XCTAssertEqual(scale, 1.5)
        for _ in 0..<5 { scale = UIZoom.stepped(scale, in: false) }
        XCTAssertEqual(scale, 1.0)
        for _ in 0..<20 { scale = UIZoom.stepped(scale, in: false) }
        XCTAssertEqual(scale, UIZoom.minScale)
        for _ in 0..<20 { scale = UIZoom.stepped(scale, in: true) }
        XCTAssertEqual(scale, UIZoom.maxScale)
    }

    /// A stored value outside the range (an older build, a hand-edited
    /// default) comes back inside it on the next step.
    func test_outOfRangeOrInvalidStoredValueIsClamped() {
        XCTAssertEqual(UIZoom.stepped(5.0, in: true), UIZoom.maxScale)
        XCTAssertEqual(UIZoom.stepped(5.0, in: false), UIZoom.maxScale)
        XCTAssertEqual(UIZoom.stepped(0.0, in: false), UIZoom.minScale)
        XCTAssertEqual(UIZoom.stepped(.nan, in: true), 1.1)
        XCTAssertEqual(UIZoom.stepped(.infinity, in: false), 0.9)

        XCTAssertEqual(UIZoom.clamped(3.0), UIZoom.maxScale)
        XCTAssertEqual(UIZoom.clamped(0.0), UIZoom.minScale)
        XCTAssertEqual(UIZoom.clamped(1.3), 1.3)
        XCTAssertEqual(UIZoom.clamped(.nan), UIZoom.actualSize)
    }
}
