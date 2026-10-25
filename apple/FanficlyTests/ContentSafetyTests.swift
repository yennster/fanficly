import XCTest
import SwiftData
@testable import Fanficly

@MainActor
final class ContentSafetyTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Work.self, Chapter.self, TagRecord.self, BookmarkRecord.self,
            SubscriptionRecord.self, SavedSearch.self, ReadingProgress.self,
            RecentlyViewed.self, SavedFilter.self, HiddenWork.self, CustomFolder.self,
            BlockedTerm.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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

    // MARK: Blocklist (RM-006)

    private func tagged(
        id: Int, author: String = "someone", login: String = "someone",
        fandoms: [String] = [], relationships: [String] = [], characters: [String] = [],
        freeforms: [String] = [], warnings: [String] = []
    ) -> AO3WorkSummary {
        AO3WorkSummary(
            id: id, title: "Work \(id)", author: author, authorUsername: login, summary: "",
            rating: "General Audiences", warnings: warnings, categories: [], fandoms: fandoms,
            characters: characters, relationships: relationships, freeforms: freeforms,
            wordCount: 0, chapterCount: 1, totalChapters: 1, language: "English",
            kudos: 0, hits: 0, isComplete: true, updatedAt: nil
        )
    }

    func test_blockedTagMatchesCaseInsensitivelyByAO3Name() {
        let works = [
            tagged(id: 1, freeforms: ["Alternate Universe - Coffee Shops & Cafés"]),
            tagged(id: 2, relationships: ["Hermione Granger/Draco Malfoy"]),
            tagged(id: 3, fandoms: ["Harry Potter - J. K. Rowling"], warnings: ["Major Character Death"]),
            tagged(id: 4, freeforms: ["Fluff"]),
        ]
        let blocklist = Blocklist(
            tags: ["alternate universe - coffee shops & cafés", " HERMIONE GRANGER/DRACO MALFOY ", "major character death"],
            authors: [String]()
        )
        let kept = ContentFilter.apply(works, hiddenIds: [], filterMature: false, blocklist: blocklist)
        XCTAssertEqual(kept.map(\.id), [4])
    }

    func test_blockedTagNeedsTheWholeAO3Name() {
        // "Coffee Shops" is a different tag from the canonical AU tag, and
        // a blocked fandom doesn't swallow a longer one that contains it.
        let works = [
            tagged(id: 1, freeforms: ["Alternate Universe - Coffee Shops & Cafés"]),
            tagged(id: 2, fandoms: ["Harry Potter - J. K. Rowling"]),
        ]
        let blocklist = Blocklist(tags: ["Coffee Shops", "Harry Potter"], authors: [String]())
        XCTAssertEqual(ContentFilter.apply(works, hiddenIds: [], filterMature: false, blocklist: blocklist).map(\.id), [1, 2])
    }

    func test_blockedAuthorMatchesLoginOrDisplayName() {
        let works = [
            tagged(id: 1, author: "Pseud (writer)", login: "writer"),
            tagged(id: 2, author: "Anonymous", login: ""),
            tagged(id: 3, author: "Other", login: "other"),
        ]
        let blocklist = Blocklist(tags: [String](), authors: ["Writer", "anonymous"])
        XCTAssertEqual(ContentFilter.apply(works, hiddenIds: [], filterMature: false, blocklist: blocklist).map(\.id), [3])
    }

    func test_blockedAuthorMatchesAnyCoAuthor() {
        let works = [
            tagged(id: 1, author: "First, Second Pseud (second)", login: "first"),
            tagged(id: 2, author: "First, Third", login: "first"),
        ]
        XCTAssertEqual(ContentFilter.apply(works, hiddenIds: [], filterMature: false,
                                           blocklist: Blocklist(tags: [String](), authors: ["second"])).map(\.id), [2])
        XCTAssertEqual(ContentFilter.apply(works, hiddenIds: [], filterMature: false,
                                           blocklist: Blocklist(tags: [String](), authors: ["Third"])).map(\.id), [1])
    }

    func test_blocklistWithNoMatchKeepsEverything() {
        let works = [tagged(id: 1, freeforms: ["Fluff"]), tagged(id: 2, login: "writer")]
        let blocklist = Blocklist(tags: ["Angst"], authors: ["nobody"])
        XCTAssertEqual(ContentFilter.apply(works, hiddenIds: [], filterMature: false, blocklist: blocklist).map(\.id), [1, 2])
    }

    func test_emptyBlocklistKeepsEverything() {
        let works = [tagged(id: 1, freeforms: ["Fluff"]), tagged(id: 2, author: "", login: "")]
        XCTAssertTrue(Blocklist.empty.isEmpty)
        XCTAssertEqual(ContentFilter.apply(works, hiddenIds: [], filterMature: false, blocklist: .empty).map(\.id), [1, 2])
        // An empty login never matches an empty blocklist entry either.
        XCTAssertTrue(Blocklist(tags: ["  "], authors: [""]).isEmpty)
    }

    func test_blockedTermsAskedForByNameAreLifted() {
        let works = [tagged(id: 1, login: "writer", fandoms: ["Teen Wolf (TV)"])]
        let blocklist = Blocklist(tags: ["teen wolf (tv)"], authors: ["writer"])
        var filters = AO3SearchFilters()
        filters.otherTagNames = ["Teen Wolf (TV)"]
        // Still blocked by author until the search names the creator too.
        XCTAssertTrue(ContentFilter.apply(works, hiddenIds: [], filterMature: false,
                                          blocklist: blocklist.lifting(filters)).isEmpty)
        filters.creators = "Writer"
        XCTAssertEqual(ContentFilter.apply(works, hiddenIds: [], filterMature: false,
                                           blocklist: blocklist.lifting(filters)).map(\.id), [1])
    }

    func test_warningAndCategoryFiltersLiftTheirBlockedTags() {
        let works = [tagged(id: 1, warnings: ["Major Character Death"])]
        let blocklist = Blocklist(tags: ["Major Character Death"], authors: [String]())
        var filters = AO3SearchFilters()
        XCTAssertTrue(ContentFilter.apply(works, hiddenIds: [], filterMature: false,
                                          blocklist: blocklist.lifting(filters)).isEmpty)
        filters.warnings = [.majorCharacterDeath]
        XCTAssertEqual(ContentFilter.apply(works, hiddenIds: [], filterMature: false,
                                           blocklist: blocklist.lifting(filters)).map(\.id), [1])
        XCTAssertEqual(blocklist.lifting(tags: ["Fluff"], authors: ["x"]), blocklist)
    }

    func test_blockThenUnblock() throws {
        let ctx = try makeContext()
        BlocklistStore.block(.tag, "Major Character Death", into: ctx)
        // Same term in another case is the same block.
        BlocklistStore.block(.tag, "major character death", into: ctx)
        BlocklistStore.block(.author, "writer", into: ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<BlockedTerm>()).count, 2)
        XCTAssertTrue(BlocklistStore.isBlocked(.tag, "MAJOR CHARACTER DEATH", in: ctx))
        XCTAssertFalse(BlocklistStore.isBlocked(.author, "Major Character Death", in: ctx))

        let blocklist = Blocklist(try ctx.fetch(FetchDescriptor<BlockedTerm>()))
        XCTAssertTrue(blocklist.blocks(tagged(id: 1, warnings: ["Major Character Death"])))
        XCTAssertTrue(blocklist.blocks(tagged(id: 2, login: "writer")))

        BlocklistStore.unblock(.tag, "Major Character Death", in: ctx)
        XCTAssertFalse(BlocklistStore.isBlocked(.tag, "Major Character Death", in: ctx))
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<BlockedTerm>()).count, 1)
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
