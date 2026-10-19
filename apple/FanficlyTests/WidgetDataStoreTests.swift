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
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
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
