import XCTest
import SwiftData
@testable import Fanficly

@MainActor
final class WidgetDataStoreTests: XCTestCase {
    
    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Work.self, Chapter.self, TagRecord.self, BookmarkRecord.self,
            SubscriptionRecord.self, SavedSearch.self, ReadingProgress.self,
            SavedFilter.self, CustomFolder.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    func test_widgetDataStore_serialization() throws {
        let context = try makeContext()
        
        // 1. Create a Saved Search
        let search = SavedSearch(name: "My Harry Potter Search", prompt: "harry potter complete")
        context.insert(search)
        
        // 2. Create a Saved Filter
        let filter = SavedFilter(name: "Drarry Filter", filtersJSON: "{\"query\":\"Drarry\"}")
        context.insert(filter)
        
        // 3. Create Custom Folder and Work
        let folder = CustomFolder(name: "Favorites")
        context.insert(folder)
        
        let work = Work(ao3Id: 12345, title: "An Epic Drarry Romance", authorName: "Jane Doe")
        work.summary = "A summary with some <b>HTML</b> tags."
        work.fandoms = ["Harry Potter"]
        work.relationships = ["Harry/Draco"]
        work.isStarred = true
        work.isFollowed = true
        work.folders.append(folder)
        context.insert(work)
        
        // 4. Create an Online Subscription
        let sub = SubscriptionRecord(key: "work:67890", kind: "work", displayName: "Online Work Title")
        sub.authorName = "John Smith"
        sub.lastSeenChapterCount = 12
        context.insert(sub)
        
        try context.save()
        
        // Execute Widget updates
        WidgetDataStore.updateAll(context: context)
        
        // Verify Saved Searches
        let savedSearches = WidgetDataStore.loadLocalSavedSearches()
        XCTAssertEqual(savedSearches.count, 2)
        XCTAssertTrue(savedSearches.contains(where: { $0.name == "My Harry Potter Search" && $0.query == "harry potter complete" && !$0.isFilter }))
        XCTAssertTrue(savedSearches.contains(where: { $0.name == "Drarry Filter" && $0.query == "{\"query\":\"Drarry\"}" && $0.isFilter }))
        
        // Verify Folder Shortcuts
        let foldersList = WidgetDataStore.loadLocalFolders()
        XCTAssertEqual(foldersList.count, 1)
        XCTAssertEqual(foldersList.first?.name, "Favorites")
        XCTAssertEqual(foldersList.first?.workCount, 1)
        
        // Verify Subscriptions Tracker
        let subsList = WidgetDataStore.loadLocalSubscriptions()
        XCTAssertEqual(subsList.count, 2)
        
        let localFollowSub = subsList.first(where: { $0.workId == 12345 })
        XCTAssertNotNil(localFollowSub)
        XCTAssertEqual(localFollowSub?.title, "An Epic Drarry Romance")
        XCTAssertEqual(localFollowSub?.author, "Jane Doe")
        XCTAssertTrue(localFollowSub?.isFollowed ?? false)
        
        let onlineSub = subsList.first(where: { $0.workId == 67890 })
        XCTAssertNotNil(onlineSub)
        XCTAssertEqual(onlineSub?.title, "Online Work Title")
        XCTAssertEqual(onlineSub?.author, "John Smith")
        XCTAssertFalse(onlineSub?.isFollowed ?? true)
        XCTAssertEqual(onlineSub?.chapterCount, 12)
        
        // Verify Recommendations
        let recs = WidgetDataStore.loadLocalRecommendations()
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.workId, 12345)
        XCTAssertEqual(recs.first?.title, "An Epic Drarry Romance")
        XCTAssertEqual(recs.first?.author, "Jane Doe")
        XCTAssertEqual(recs.first?.summary, "A summary with some HTML tags.")
        XCTAssertEqual(recs.first?.tags, ["Harry Potter", "Harry/Draco"])
    }

    // MARK: - Reading progress leaves the library widgets alone (#165)

    private func clearLibrarySnapshots() {
        for key in [WidgetDataStore.savedSearchesKey, WidgetDataStore.customFoldersKey,
                    WidgetDataStore.subscriptionsKey, WidgetDataStore.recommendationsKey] {
            UserDefaults(suiteName: WidgetDataStore.appGroupIdentifier)?.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func test_progressSave_doesNotRebuildLibrarySnapshots() throws {
        let context = try makeContext()
        let work = Work(ao3Id: 4242, title: "Saved Story", authorName: "Someone")
        work.isFollowed = true
        context.insert(work)
        context.insert(SavedSearch(name: "Search", prompt: "slow burn"))
        try context.save()
        clearLibrarySnapshots()
        defer { clearLibrarySnapshots() }

        ReadingProgressStore.save(ao3Id: 4242, anchor: ReadingAnchor(chapter: 2, paragraph: 3),
                                  title: "Saved Story", author: "Someone", in: context)

        XCTAssertEqual(work.lastReadChapter, 2, "the save itself still lands")
        XCTAssertTrue(WidgetDataStore.loadLocalRecommendations().isEmpty)
        XCTAssertTrue(WidgetDataStore.loadLocalSubscriptions().isEmpty)
        XCTAssertTrue(WidgetDataStore.loadLocalSavedSearches().isEmpty)
    }

    /// The Subscriptions widget orders by AO3's Updated date: a subscription
    /// polled a minute ago but last updated in March sorts below a followed
    /// work updated yesterday, and one never checked sorts last (#197).
    func test_subscriptions_sortByUpdatedDateNotLastCheck() throws {
        let context = try makeContext()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let followed = Work(ao3Id: 1, title: "Followed", authorName: "A", chapterCount: 12,
                            updatedAt: now.addingTimeInterval(-86_400))
        followed.isFollowed = true
        context.insert(followed)
        let stale = SubscriptionRecord(key: "work:2", kind: "work", displayName: "Old")
        stale.lastCheckedAt = now
        stale.updatedAt = now.addingTimeInterval(-200 * 86_400)
        stale.lastSeenChapterCount = 3
        context.insert(stale)
        let fresh = SubscriptionRecord(key: "work:3", kind: "work", displayName: "Fresh")
        fresh.lastCheckedAt = now.addingTimeInterval(-3_600)
        fresh.updatedAt = now
        context.insert(fresh)
        let unchecked = SubscriptionRecord(key: "work:4", kind: "work", displayName: "Unchecked")
        context.insert(unchecked)
        try context.save()
        defer { clearLibrarySnapshots() }

        WidgetDataStore.updateSubscriptions(context: context)

        let list = WidgetDataStore.loadLocalSubscriptions()
        XCTAssertEqual(list.map(\.workId), [3, 1, 2, 4])
        XCTAssertEqual(list.first(where: { $0.workId == 1 })?.chapterCount, 12)
    }

    func test_recommendations_keepTheTopTwenty() throws {
        let context = try makeContext()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for id in 1...30 {
            let work = Work(ao3Id: id, title: "Work \(id)", authorName: "A")
            work.savedAt = base.addingTimeInterval(TimeInterval(id))
            work.isStarred = id == 1
            context.insert(work)
        }
        try context.save()
        defer { clearLibrarySnapshots() }

        WidgetDataStore.updateRecommendations(context: context)

        let ids = WidgetDataStore.loadLocalRecommendations().map(\.workId)
        XCTAssertEqual(ids.count, WidgetDataStore.listLimit)
        XCTAssertEqual(ids.first, 1, "starred works come first")
        XCTAssertEqual(Array(ids.dropFirst()), Array((12...30).reversed()), "then the most recently saved")
    }

    // MARK: - Saved Searches widget route (fanficly://search?query=)

    /// What tapping the widget does: its link → RootView's query value →
    /// SearchView's pending query → the filters the search runs with.
    private func filtersAfterTapping(_ item: WidgetSavedSearch) throws -> AO3SearchFilters {
        let url = try XCTUnwrap(item.searchURL)
        let query = try XCTUnwrap(WidgetSavedSearch.routeQuery(from: url))
        return AO3SearchFilters.savedFilter(fromRouteQuery: query) ?? SearchSyntax.parse(query)
    }

    func test_savedFilter_roundTripsThroughSearchRoute() throws {
        var f = AO3SearchFilters()
        f.query = "complete idiots"                        // a filter phrase stays a keyword
        f.fandomNames = ["Harry Potter - J. K. Rowling"]   // saved filters drop the fandom
        f.relationshipNames = ["Hermione Granger & Harry Potter"]
        f.freeformNames = ["Slow Burn"]
        f.excludedFreeforms = ["Angst"]
        f.ratings = [.explicit]
        f.complete = .yes
        f.wordCount = "1000-5000"
        f.kudosCount = ">100"
        f.sortColumn = .kudosCount
        f.sortDirection = .asc

        let item = WidgetSavedSearch(name: "Drarry", query: f.savedJSON(), isFilter: true)
        var expected = f
        expected.fandomNames = []
        XCTAssertEqual(try filtersAfterTapping(item), expected)
    }

    func test_savedSearchPrompt_roundTripsThroughSearchRoute() throws {
        let prompt = #"drarry ship:"Hermione Granger & Harry Potter" kudos:>100 words:1000-5000"#
        let item = WidgetSavedSearch(name: "Drarry", query: prompt, isFilter: false)
        let url = try XCTUnwrap(item.searchURL)
        XCTAssertTrue(url.absoluteString.contains("%26"), "& must stay inside the query value")
        XCTAssertEqual(WidgetSavedSearch.routeQuery(from: url), prompt)
        XCTAssertNil(AO3SearchFilters.savedFilter(fromRouteQuery: prompt))
        XCTAssertEqual(try filtersAfterTapping(item), SearchSyntax.parse(prompt))
    }

    func test_malformedJSONQuery_degradesToKeywordSearch() throws {
        let broken = #"{"relationshipNames":["Draco"#
        XCTAssertNil(AO3SearchFilters.savedFilter(fromRouteQuery: broken))
        let item = WidgetSavedSearch(name: "Broken", query: broken, isFilter: true)
        let filters = try filtersAfterTapping(item)
        XCTAssertFalse(filters.query.isEmpty)
        XCTAssertTrue(filters.relationshipNames.isEmpty)
    }

    func test_routeQuery_ignoresOtherRoutes() throws {
        let url = try XCTUnwrap(URL(string: "fanficly://library?query=x"))
        XCTAssertNil(WidgetSavedSearch.routeQuery(from: url))
    }
}
