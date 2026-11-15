import XCTest
import SwiftData
@testable import Fanficly

/// #209: deleting or hiding a work, or clearing the history, forgets the
/// last-read widget entry, so the Continue reading widget doesn't keep the
/// title; a hidden work's reader never writes it back.
@MainActor
final class WidgetProgressClearTests: XCTestCase {
    private let keys = [WidgetProgressStore.lastReadProgressKey, WidgetProgressStore.clearedKey]
    private var saved: [String: (shared: Data?, standard: Data?)] = [:]
    private var shared: UserDefaults? { UserDefaults(suiteName: WidgetProgressStore.appGroupIdentifier) }

    override func setUp() {
        super.setUp()
        // Never touch iCloud: it would push test entries to the developer's
        // other devices. The defaults are the device's own: put back whatever
        // was there.
        WidgetProgressStore.usesCloud = false
        for key in keys {
            saved[key] = (shared?.data(forKey: key), UserDefaults.standard.data(forKey: key))
            shared?.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            shared?.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
            if let data = saved[key]?.shared { shared?.set(data, forKey: key) }
            if let data = saved[key]?.standard { UserDefaults.standard.set(data, forKey: key) }
        }
        WidgetProgressStore.usesCloud = true
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Work.self, Chapter.self, TagRecord.self, BookmarkRecord.self,
            SubscriptionRecord.self, SavedSearch.self, ReadingProgress.self,
            RecentlyViewed.self, CustomFolder.self, FollowedAuthor.self,
            ReadingStat.self, BlockedTerm.self, HiddenWork.self, SavedFilter.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func summary(_ id: Int) -> AO3WorkSummary {
        AO3WorkSummary(
            id: id, title: "Work \(id)", author: "tester",
            summary: "", rating: "General Audiences", warnings: [],
            categories: [], fandoms: [], characters: [], relationships: [],
            freeforms: [], wordCount: 1000, chapterCount: 1,
            totalChapters: 1, language: "English", kudos: 0, hits: 0,
            isComplete: true, updatedAt: nil
        )
    }

    private func saveEntry(_ id: Int) {
        WidgetProgressStore.save(id: id, title: "Work \(id)", author: "tester", progress: 0.5,
                                 chapter: 1, paragraph: 0)
    }

    func test_clear_removesOnlyTheNamedWork() {
        saveEntry(83001)
        XCTAssertFalse(WidgetProgressStore.clear(workId: 83002))
        XCTAssertEqual(WidgetProgressStore.load()?.id, 83001)
        XCTAssertTrue(WidgetProgressStore.clear(workId: 83001))
        XCTAssertNil(WidgetProgressStore.load())
    }

    func test_clearWithNoWork_removesWhicheverWorkItNames() {
        saveEntry(83003)
        XCTAssertTrue(WidgetProgressStore.clear())
        XCTAssertNil(WidgetProgressStore.load())
    }

    /// Puts a copy back as a synced or stale write would.
    private func putBack(_ progress: WidgetStoryProgress) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(progress), forKey: WidgetProgressStore.lastReadProgressKey)
    }

    func test_clear_keepsACopyFromBeforeIt_fromComingBack() throws {
        let old = Date.now.addingTimeInterval(-60)
        WidgetProgressStore.save(id: 83004, title: "Work", author: "tester", progress: 0.5, updatedAt: old)
        XCTAssertTrue(WidgetProgressStore.clear(workId: 83004))
        try putBack(WidgetStoryProgress(id: 83004, title: "Work", author: "tester", progress: 0.5,
                                        chapter: nil, paragraph: nil, updatedAt: old))
        XCTAssertNil(WidgetProgressStore.load())

        // Reading it again afterwards shows it again.
        WidgetProgressStore.save(id: 83004, title: "Work", author: "tester", progress: 0.6,
                                 updatedAt: Date.now.addingTimeInterval(60))
        XCTAssertEqual(WidgetProgressStore.load()?.id, 83004)
    }

    func test_aHiddenWork_neverComesBack_evenFromANewerCopy_untilUnhidden() throws {
        saveEntry(83007)
        XCTAssertTrue(WidgetProgressStore.setHidden(83007, hidden: true))
        XCTAssertNil(WidgetProgressStore.load())

        // Another device still reading it saved a newer copy.
        try putBack(WidgetStoryProgress(id: 83007, title: "Work", author: "tester", progress: 0.75,
                                        chapter: nil, paragraph: nil, updatedAt: Date.now.addingTimeInterval(60)))
        XCTAssertNil(WidgetProgressStore.load())

        XCTAssertFalse(WidgetProgressStore.setHidden(83007, hidden: false))
        XCTAssertEqual(WidgetProgressStore.load()?.id, 83007)
    }

    func test_oldDatedMarksArePruned() {
        let ancient = Date.now.addingTimeInterval(-WidgetProgressStore.clearedMarkLifetime - 60)
        let marks = [WidgetProgressStore.ClearedMark(id: 1, at: ancient),
                     WidgetProgressStore.ClearedMark(id: 2, at: nil)]
        shared?.set(try? JSONEncoder().encode(marks), forKey: WidgetProgressStore.clearedKey)
        WidgetProgressStore.clear(workId: 3)
        let kept = WidgetProgressStore.loadMarks()
        XCTAssertFalse(kept.contains { $0.id == 1 })
        XCTAssertTrue(kept.contains(WidgetProgressStore.ClearedMark(id: 2, at: nil)))
        XCTAssertTrue(kept.contains { $0.id == 3 && $0.at != nil })
    }

    func test_deletingAWork_clearsItsEntry() throws {
        let context = try makeContext()
        let work = WorkPersistence.upsertMetadata(summary: summary(83005), into: context)
        saveEntry(83005)
        WorkPersistence.delete(work, in: context)
        XCTAssertNil(WidgetProgressStore.load())
    }

    func test_hidingAWork_clearsItsEntry_andItsReaderNeverWritesItBack() throws {
        let context = try makeContext()
        saveEntry(83006)
        HiddenWorkStore.hide(ao3Id: 83006, title: "Work 83006", into: context)
        XCTAssertNil(WidgetProgressStore.load())

        // The reader's closing save after "Hide this work".
        ReadingProgressStore.save(ao3Id: 83006, anchor: ReadingAnchor(chapter: 1, paragraph: 3),
                                  title: "Work 83006", author: "tester", progress: 0.6,
                                  syncWidgetImmediately: true, in: context)
        XCTAssertNil(WidgetProgressStore.load())
        // The place itself is still kept.
        XCTAssertEqual(ReadingProgressStore.load(ao3Id: 83006, in: context),
                       ReadingAnchor(chapter: 1, paragraph: 3))
    }
}
