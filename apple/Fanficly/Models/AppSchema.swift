import SwiftData

/// Every SwiftData model, for the app's container and the App Clip's (#292),
/// so the two can't drift apart.
enum AppSchema {
    static var schema: Schema {
        Schema([
            Work.self,
            Chapter.self,
            TagRecord.self,
            BookmarkRecord.self,
            SubscriptionRecord.self,
            SavedSearch.self,
            ReadingProgress.self,
            SavedFilter.self,
            RecentlyViewed.self,
            HiddenWork.self,
            CustomFolder.self,
            FollowedAuthor.self,
            ReadingStat.self,
            BlockedTerm.self,
        ])
    }
}
