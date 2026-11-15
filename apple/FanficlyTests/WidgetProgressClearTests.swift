import XCTest
import SwiftData
@testable import Fanficly

/// #209: deleting or hiding a work, or clearing the history, forgets the
/// last-read widget entry, so the Continue reading widget doesn't keep the
/// title; a hidden work's reader never writes it back.
@MainActor
final class WidgetProgressClearTests: XCTestCase {
    private let key = WidgetProgressStore.lastReadProgressKey
    private var savedShared: Data?
    private var savedStandard: Data?
    private var savedCloud: Data?

    override func setUp() {
        super.setUp()
        // The stores are the device's own: put back whatever was there.
        savedShared = UserDefaults(suiteName: WidgetProgressStore.appGroupIdentifier)?.data(forKey: key)
        savedStandard = UserDefaults.standard.data(forKey: key)
        savedCloud = NSUbiquitousKeyValueStore.default.data(forKey: key)
        WidgetProgressStore.clear()
    }

    override func tearDown() {
        WidgetProgressStore.clear()
        if let savedShared { UserDefaults(suiteName: WidgetProgressStore.appGroupIdentifier)?.set(savedShared, forKey: key) }
        if let savedStandard { UserDefaults.standard.set(savedStandard, forKey: key) }
        if let savedCloud { NSUbiquitousKeyValueStore.default.set(savedCloud, forKey: key) }
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
                                 chapter: 1, paragraph: 0, syncImmediately: true)
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

    func test_clear_dropsAPendingMirror() async throws {
        WidgetProgressStore.save(id: 83004, title: "Work", author: "tester", progress: 0.5)
        XCTAssertTrue(WidgetProgressStore.clear(workId: 83004))
        try await Task.sleep(nanoseconds: 1_500_000_000) // past the 1.2 s mirror
        XCTAssertNil(WidgetProgressStore.load())
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
