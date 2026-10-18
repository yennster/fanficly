import Foundation
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

extension WidgetDataStore {

    @MainActor
    public static func updateAll(context: ModelContext) {
        updateSavedSearches(context: context)
        updateFolders(context: context)
        updateSubscriptions(context: context)
        updateRecommendations(context: context)
        
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    @MainActor
    public static func updateSavedSearches(context: ModelContext) {
        var list: [WidgetSavedSearch] = []
        
        // Fetch Saved Searches
        let searchDescriptor = FetchDescriptor<SavedSearch>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)])
        if let searches = try? context.fetch(searchDescriptor) {
            for s in searches {
                list.append(WidgetSavedSearch(name: s.name, query: s.prompt, isFilter: false))
            }
        }
        
        // Fetch Saved Filters
        let filterDescriptor = FetchDescriptor<SavedFilter>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)])
        if let filters = try? context.fetch(filterDescriptor) {
            for f in filters {
                list.append(WidgetSavedSearch(name: f.name, query: f.filtersJSON, isFilter: true))
            }
        }
        
        // Limit to top 20
        if list.count > 20 {
            list = Array(list.prefix(20))
        }
        
        saveLocal(list, forKey: savedSearchesKey)
    }

    @MainActor
    public static func updateFolders(context: ModelContext) {
        var list: [WidgetFolderShortcut] = []
        let descriptor = FetchDescriptor<CustomFolder>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        
        if let folders = try? context.fetch(descriptor) {
            for f in folders {
                list.append(WidgetFolderShortcut(name: f.name, workCount: f.works.count))
            }
        }
        
        saveLocal(list, forKey: customFoldersKey)
    }

    @MainActor
    public static func updateSubscriptions(context: ModelContext) {
        var list: [WidgetSubscriptionUpdate] = []
        
        // 1. Followed local works
        let followedDescriptor = FetchDescriptor<Work>(
            predicate: #Predicate { $0.isFollowed == true },
            sortBy: [SortDescriptor(\.savedAt, order: .reverse)]
        )
        if let followedWorks = try? context.fetch(followedDescriptor) {
            for w in followedWorks {
                list.append(WidgetSubscriptionUpdate(
                    workId: w.ao3Id,
                    title: w.title,
                    author: w.authorName,
                    chapterCount: w.chapterCount,
                    isFollowed: true,
                    updatedAt: w.updatedAt ?? w.savedAt
                ))
            }
        }
        
        // 2. Online Subscriptions (kind == "work")
        let subDescriptor = FetchDescriptor<SubscriptionRecord>(
            predicate: #Predicate { $0.kind == "work" }
        )
        if let subs = try? context.fetch(subDescriptor) {
            for s in subs {
                let parts = s.key.split(separator: ":")
                guard parts.count == 2, let workId = Int(parts[1]) else { continue }
                
                // Avoid duplicating if already in followed list
                if !list.contains(where: { $0.workId == workId }) {
                    list.append(WidgetSubscriptionUpdate(
                        workId: workId,
                        title: s.displayName,
                        author: s.authorName,
                        chapterCount: s.lastSeenChapterCount ?? 0,
                        isFollowed: false,
                        updatedAt: s.lastCheckedAt ?? .now
                    ))
                }
            }
        }
        
        // Sort by update date descending
        list.sort(by: { $0.updatedAt > $1.updatedAt })
        
        if list.count > 20 {
            list = Array(list.prefix(20))
        }
        
        saveLocal(list, forKey: subscriptionsKey)
    }

    @MainActor
    public static func updateRecommendations(context: ModelContext) {
        var list: [WidgetRecommendation] = []
        
        // Fetch works (prioritize Starred, Pinned, or recently saved)
        let workDescriptor = FetchDescriptor<Work>(
            sortBy: [SortDescriptor<Work>(\.savedAt, order: .reverse)]
        )
        
        if var works = try? context.fetch(workDescriptor) {
            // Sort in memory because Foundation.SortDescriptor requires NSObject when sorting by Bool properties (isStarred, isPinned)
            works.sort { w1, w2 in
                if w1.isStarred != w2.isStarred {
                    return w1.isStarred && !w2.isStarred
                }
                if w1.isPinned != w2.isPinned {
                    return w1.isPinned && !w2.isPinned
                }
                return w1.savedAt > w2.savedAt
            }
            for w in works {
                // Strip HTML tags from summary for widget preview
                let cleanSummary = w.summary
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: String.CompareOptions.regularExpression)
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                
                // Collect a few key tags
                var tags: [String] = []
                if let firstFandom = w.fandoms.first { tags.append(firstFandom) }
                if let firstRelationship = w.relationships.first { tags.append(firstRelationship) }
                if let firstChar = w.characters.first { tags.append(firstChar) }
                
                list.append(WidgetRecommendation(
                    workId: w.ao3Id,
                    title: w.title,
                    author: w.authorName,
                    summary: String(cleanSummary.prefix(180)),
                    tags: tags
                ))
            }
        }
        
        saveLocal(list, forKey: recommendationsKey)
    }

    private static func saveLocal<T: Codable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults(suiteName: appGroupIdentifier)?.set(data, forKey: key)
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
