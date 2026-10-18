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
}
