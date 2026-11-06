import XCTest
import SwiftData
@testable import Fanficly

/// A downloaded work in progress offers its new chapters (#180).
@MainActor
final class DownloadUpdateTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Work.self, Chapter.self, TagRecord.self, BookmarkRecord.self,
            SubscriptionRecord.self, SavedSearch.self, ReadingProgress.self,
            RecentlyViewed.self, CustomFolder.self, FollowedAuthor.self,
            ReadingStat.self, BlockedTerm.self, HiddenWork.self, SavedFilter.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func payload(id: Int, chapters: Int) -> AO3WorkPayload {
        let summary = AO3WorkSummary(
            id: id, title: "Work \(id)", author: "tester",
            summary: "", rating: "General Audiences", warnings: [],
            categories: [], fandoms: ["Fandom"], characters: [], relationships: [],
            freeforms: [], wordCount: 1000, chapterCount: chapters,
            totalChapters: nil, language: "English", kudos: 0, hits: 0,
            isComplete: false, updatedAt: nil
        )
        let chs = (1...chapters).map { AO3ChapterPayload(index: $0, title: "", bodyHTML: "<p>Chapter \($0)</p>") }
        return AO3WorkPayload(summary: summary, chapters: chs)
    }

    func test_newChapterCount_isTheHighestKnownCountPastTheSavedChapters() {
        XCTAssertEqual(DownloadUpdate.newChapterCount(saved: 5, known: [5, 8, nil]), 3)
        XCTAssertEqual(DownloadUpdate.newChapterCount(saved: 5, known: [nil, 6, 7]), 2)
    }

    func test_newChapterCount_isZeroWhenUpToDateOrUnknown() {
        XCTAssertEqual(DownloadUpdate.newChapterCount(saved: 5, known: [5, 5]), 0)
        XCTAssertEqual(DownloadUpdate.newChapterCount(saved: 5, known: [nil, nil]), 0)
        XCTAssertEqual(DownloadUpdate.newChapterCount(saved: 5, known: []), 0)
        // AO3 has fewer (a chapter deleted there): nothing to offer.
        XCTAssertEqual(DownloadUpdate.newChapterCount(saved: 5, known: [4]), 0)
    }

    func test_newChapterCount_isZeroWithNothingSaved() {
        // A bookmarked-only work reads live from AO3: nothing to update.
        XCTAssertEqual(DownloadUpdate.newChapterCount(saved: 0, known: [9]), 0)
    }

    func test_bannerText() {
        XCTAssertEqual(DownloadUpdate.bannerText(count: 1), "1 new chapter on AO3")
        XCTAssertEqual(DownloadUpdate.bannerText(count: 3), "3 new chapters on AO3")
    }

    func test_libraryWork_countsItsFollowBaseline() throws {
        let ctx = try makeContext()
        let work = WorkPersistence.upsert(payload: payload(id: 1, chapters: 4), into: ctx)
        XCTAssertEqual(DownloadUpdate.newChapterCount(for: work, in: ctx), 0)

        // The poller saw chapter 6 go up.
        work.isFollowed = true
        work.lastSeenChapterCount = 6
        XCTAssertEqual(DownloadUpdate.newChapterCount(for: work, in: ctx), 2)
    }

    func test_libraryWork_countsItsSubscriptionBaseline() throws {
        let ctx = try makeContext()
        let work = WorkPersistence.upsert(payload: payload(id: 2, chapters: 3), into: ctx)
        let record = SubscriptionRecord(key: "work:2", kind: "work", displayName: "Work 2")
        record.lastSeenChapterCount = 7
        ctx.insert(record)
        // Another work's subscription doesn't count.
        let other = SubscriptionRecord(key: "work:20", kind: "work", displayName: "Work 20")
        other.lastSeenChapterCount = 40
        ctx.insert(other)
        try ctx.save()

        XCTAssertEqual(DownloadUpdate.newChapterCount(for: work, in: ctx), 4)
    }

    func test_updatingTheDownload_addsTheNewChaptersAndKeepsTheReadingPlace() throws {
        let ctx = try makeContext()
        let work = WorkPersistence.upsert(payload: payload(id: 3, chapters: 2), into: ctx)
        work.lastReadChapter = 2
        work.lastReadProgress = 0.9
        work.lastSeenChapterCount = 4
        XCTAssertEqual(DownloadUpdate.newChapterCount(for: work, in: ctx), 2)

        let updated = WorkPersistence.upsert(payload: payload(id: 3, chapters: 4), into: ctx)
        XCTAssertEqual(updated.chapters.count, 4)
        XCTAssertEqual(updated.lastReadChapter, 2)
        XCTAssertEqual(updated.lastReadProgress, 0.9)
        XCTAssertEqual(DownloadUpdate.newChapterCount(for: updated, in: ctx), 0)
    }

    func test_apply_savesTheNewChaptersAndMovesTheBaselines() throws {
        let ctx = try makeContext()
        let work = WorkPersistence.upsert(payload: payload(id: 4, chapters: 3), into: ctx)
        work.isFollowed = true
        work.lastSeenChapterCount = 6
        let record = SubscriptionRecord(key: "work:4", kind: "work", displayName: "Work 4")
        record.lastSeenChapterCount = 6
        ctx.insert(record)

        // AO3 has 5 now (one of the 6 the poller saw was deleted).
        XCTAssertEqual(DownloadUpdate.apply(payload(id: 4, chapters: 5), to: work, in: ctx), .updated(added: 2))
        XCTAssertEqual(work.chapters.count, 5)
        XCTAssertEqual(work.lastSeenChapterCount, 5)
        XCTAssertEqual(record.lastSeenChapterCount, 5)
        // So the banner doesn't come back offering a sixth.
        XCTAssertEqual(DownloadUpdate.newChapterCount(for: work, in: ctx), 0)
    }

    func test_apply_neverReplacesMoreSavedChaptersWithFewer() throws {
        let ctx = try makeContext()
        let work = WorkPersistence.upsert(payload: payload(id: 5, chapters: 8), into: ctx)
        XCTAssertEqual(DownloadUpdate.apply(payload(id: 5, chapters: 5), to: work, in: ctx),
                       .keptLonger(saved: 8, onAO3: 5))
        XCTAssertEqual(work.chapters.count, 8)
    }

    func test_apply_leavesAnUnfollowedWorkWithoutABaseline() throws {
        let ctx = try makeContext()
        let work = WorkPersistence.upsert(payload: payload(id: 6, chapters: 1), into: ctx)
        XCTAssertEqual(DownloadUpdate.apply(payload(id: 6, chapters: 2), to: work, in: ctx), .updated(added: 1))
        XCTAssertNil(work.lastSeenChapterCount)
    }
}
