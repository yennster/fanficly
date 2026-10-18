import Foundation

public struct WidgetSavedSearch: Codable, Equatable, Sendable {
    public let name: String
    public let query: String
    public let isFilter: Bool
    
    public init(name: String, query: String, isFilter: Bool) {
        self.name = name
        self.query = query
        self.isFilter = isFilter
    }
}

public struct WidgetFolderShortcut: Codable, Equatable, Sendable {
    public let name: String
    public let workCount: Int
    
    public init(name: String, workCount: Int) {
        self.name = name
        self.workCount = workCount
    }
}

public struct WidgetSubscriptionUpdate: Codable, Equatable, Sendable {
    public let workId: Int
    public let title: String
    public let author: String
    public let chapterCount: Int
    public let isFollowed: Bool
    public let updatedAt: Date
    
    public init(workId: Int, title: String, author: String, chapterCount: Int, isFollowed: Bool, updatedAt: Date) {
        self.workId = workId
        self.title = title
        self.author = author
        self.chapterCount = chapterCount
        self.isFollowed = isFollowed
        self.updatedAt = updatedAt
    }
}

public struct WidgetRecommendation: Codable, Equatable, Sendable {
    public let workId: Int
    public let title: String
    public let author: String
    public let summary: String
    public let tags: [String]
    
    public init(workId: Int, title: String, author: String, summary: String, tags: [String]) {
        self.workId = workId
        self.title = title
        self.author = author
        self.summary = summary
        self.tags = tags
    }
}

public enum WidgetDataStore {
    public static let appGroupIdentifier = "group.io.github.yennster.fanficly"
    public static let savedSearchesKey = "widget.savedSearches"
    public static let customFoldersKey = "widget.customFolders"
    public static let subscriptionsKey = "widget.subscriptions"
    public static let recommendationsKey = "widget.recommendations"

    public static func loadLocalSavedSearches() -> [WidgetSavedSearch] {
        loadLocal(forKey: savedSearchesKey) ?? []
    }
    
    public static func loadLocalFolders() -> [WidgetFolderShortcut] {
        loadLocal(forKey: customFoldersKey) ?? []
    }
    
    public static func loadLocalSubscriptions() -> [WidgetSubscriptionUpdate] {
        loadLocal(forKey: subscriptionsKey) ?? []
    }
    
    public static func loadLocalRecommendations() -> [WidgetRecommendation] {
        loadLocal(forKey: recommendationsKey) ?? []
    }
    
    private static func loadLocal<T: Codable>(forKey key: String) -> T? {
        let sharedData = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: key)
        let standardData = UserDefaults.standard.data(forKey: key)
        
        if let data = sharedData ?? standardData {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        return nil
    }
}
