import XCTest
import SwiftData
@testable import Fanficly

@MainActor
final class ContentSafetyTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Work.self, Chapter.self, TagRecord.self, BookmarkRecord.self,
            SubscriptionRecord.self, SavedSearch.self, ReadingProgress.self,
            RecentlyViewed.self, SavedFilter.self, HiddenWork.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func summary(id: Int, rating: String) -> AO3WorkSummary {
        AO3WorkSummary(
            id: id, title: "Work \(id)", author: "a", summary: "", rating: rating,
            warnings: [], categories: [], fandoms: [], characters: [],
            relationships: [], freeforms: [], wordCount: 0, chapterCount: 1,
            totalChapters: 1, language: "English", kudos: 0, hits: 0,
            isComplete: true, updatedAt: nil
        )
    }

    // MARK: HiddenWorkStore

    func test_hideThenUnhide() throws {
        let ctx = try makeContext()
        XCTAssertFalse(HiddenWorkStore.isHidden(ao3Id: 42, in: ctx))

        HiddenWorkStore.hide(ao3Id: 42, title: "Secret", into: ctx)
        XCTAssertTrue(HiddenWorkStore.isHidden(ao3Id: 42, in: ctx))

        // Idempotent: hiding twice doesn't duplicate.
        HiddenWorkStore.hide(ao3Id: 42, title: "Secret", into: ctx)
        let all = try ctx.fetch(FetchDescriptor<HiddenWork>())
        XCTAssertEqual(all.count, 1)

        HiddenWorkStore.unhide(ao3Id: 42, in: ctx)
        XCTAssertFalse(HiddenWorkStore.isHidden(ao3Id: 42, in: ctx))
    }

    // MARK: ContentFilter

    func test_filterDropsMatureAndExplicitWhenOn() {
        let works = [
            summary(id: 1, rating: "General Audiences"),
            summary(id: 2, rating: "Teen And Up Audiences"),
            summary(id: 3, rating: "Mature"),
            summary(id: 4, rating: "Explicit"),
        ]
        let kept = ContentFilter.apply(works, hiddenIds: [], filterMature: true)
        XCTAssertEqual(kept.map(\.id), [1, 2])
    }

    func test_filterKeepsAllRatingsWhenOff() {
        let works = [summary(id: 3, rating: "Mature"), summary(id: 4, rating: "Explicit")]
        let kept = ContentFilter.apply(works, hiddenIds: [], filterMature: false)
        XCTAssertEqual(kept.count, 2)
    }

    func test_filterDropsHiddenIds() {
        let works = [summary(id: 1, rating: "General Audiences"), summary(id: 2, rating: "General Audiences")]
        let kept = ContentFilter.apply(works, hiddenIds: [2], filterMature: true)
        XCTAssertEqual(kept.map(\.id), [1])
    }

    // MARK: DemoAO3Client

    func test_demoCatalogIsAllAges() async throws {
        let client = DemoAO3Client()
        let results = try await client.search(filters: AO3SearchFilters(), page: 1)
        XCTAssertFalse(results.works.isEmpty)
        // No Mature/Explicit works in the screenshot catalog.
        XCTAssertTrue(results.works.allSatisfy { !ContentFilter.matureRatings.contains($0.rating) })
    }

    func test_demoFetchWorkHasChapters() async throws {
        let client = DemoAO3Client()
        let payload = try await client.fetchWork(id: 90001)
        XCTAssertEqual(payload.summary.title, "The Long Way Home")
        XCTAssertFalse(payload.chapters.isEmpty)
        XCTAssertTrue(payload.chapters[0].bodyHTML.contains("<p>"))
    }

    func test_demoSearchFiltersByRating() async throws {
        let client = DemoAO3Client()
        var filters = AO3SearchFilters()
        filters.ratings = [.general]
        let results = try await client.search(filters: filters, page: 1)
        XCTAssertTrue(results.works.allSatisfy { $0.rating == "General Audiences" })
    }
}
