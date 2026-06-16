import Foundation
import SwiftData

@Model
final class Work {
    @Attribute(.unique) var ao3Id: Int
    var title: String
    var authorName: String
    /// AO3 login for "more by this author"; "" when unknown. Additive field
    /// (defaulted) so SwiftData migrates existing stores automatically.
    var authorUsername: String = ""
    var summary: String
    var rating: String
    var warnings: [String]
    var categories: [String]
    var fandoms: [String]
    var characters: [String]
    var relationships: [String]
    var freeforms: [String]
    var language: String
    var wordCount: Int
    var chapterCount: Int
    var totalChapters: Int?
    var kudos: Int
    var hits: Int
    var bookmarksCount: Int
    var commentsCount: Int
    var isComplete: Bool
    var publishedAt: Date?
    var updatedAt: Date?
    var savedAt: Date
    var lastReadAt: Date?
    var lastReadChapter: Int?
    var lastReadProgress: Double?
    var epubLocalPath: String?

    /// Local "follow" — saved to the device without needing an AO3 login.
    /// Followed works are checked for new chapters by the background poller.
    var isFollowed: Bool = false
    var followedAt: Date?
    var lastSeenChapterCount: Int?

    var isStarred: Bool = false
    var isPinned: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Chapter.work)
    var chapters: [Chapter] = []

    var folder: CustomFolder?

    var folders: [CustomFolder] = []

    init(
        ao3Id: Int,
        title: String,
        authorName: String,
        summary: String = "",
        rating: String = "Not Rated",
        warnings: [String] = [],
        categories: [String] = [],
        fandoms: [String] = [],
        characters: [String] = [],
        relationships: [String] = [],
        freeforms: [String] = [],
        language: String = "en",
        wordCount: Int = 0,
        chapterCount: Int = 1,
        totalChapters: Int? = nil,
        kudos: Int = 0,
        hits: Int = 0,
        bookmarksCount: Int = 0,
        commentsCount: Int = 0,
        isComplete: Bool = false,
        publishedAt: Date? = nil,
        updatedAt: Date? = nil,
        savedAt: Date = .now
    ) {
        self.ao3Id = ao3Id
        self.title = title
        self.authorName = authorName
        self.summary = summary
        self.rating = rating
        self.warnings = warnings
        self.categories = categories
        self.fandoms = fandoms
        self.characters = characters
        self.relationships = relationships
        self.freeforms = freeforms
        self.language = language
        self.wordCount = wordCount
        self.chapterCount = chapterCount
        self.totalChapters = totalChapters
        self.kudos = kudos
        self.hits = hits
        self.bookmarksCount = bookmarksCount
        self.commentsCount = commentsCount
        self.isComplete = isComplete
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.savedAt = savedAt
    }
}

@Model
final class Chapter {
    var work: Work?
    var index: Int
    var title: String
    var bodyHTML: String

    init(work: Work? = nil, index: Int, title: String, bodyHTML: String) {
        self.work = work
        self.index = index
        self.title = title
        self.bodyHTML = bodyHTML
    }
}

@Model
final class TagRecord {
    @Attribute(.unique) var name: String
    var kind: String

    init(name: String, kind: String) {
        self.name = name
        self.kind = kind
    }
}

@Model
final class BookmarkRecord {
    @Attribute(.unique) var ao3Id: Int
    var workAo3Id: Int
    var notes: String
    var tags: [String]
    var savedAt: Date

    init(ao3Id: Int, workAo3Id: Int, notes: String = "", tags: [String] = [], savedAt: Date = .now) {
        self.ao3Id = ao3Id
        self.workAo3Id = workAo3Id
        self.notes = notes
        self.tags = tags
        self.savedAt = savedAt
    }
}

@Model
final class SavedFilter {
    @Attribute(.unique) var name: String
    var filtersJSON: String
    var savedAt: Date

    init(name: String, filtersJSON: String, savedAt: Date = .now) {
        self.name = name
        self.filtersJSON = filtersJSON
        self.savedAt = savedAt
    }
}

@Model
final class ReadingProgress {
    @Attribute(.unique) var ao3Id: Int
    var chapterIndex: Int
    var paragraphIndex: Int
    var title: String
    var author: String
    var updatedAt: Date

    init(ao3Id: Int, chapterIndex: Int = 1, paragraphIndex: Int = 0, title: String = "", author: String = "", updatedAt: Date = .now) {
        self.ao3Id = ao3Id
        self.chapterIndex = chapterIndex
        self.paragraphIndex = paragraphIndex
        self.title = title
        self.author = author
        self.updatedAt = updatedAt
    }
}

/// A lightweight history entry for a work the user opened. Kept separate from
/// `Work` so merely *viewing* a fic doesn't create a full saved/followed Work
/// row — this mirrors `ReadingProgress`'s per-work-id footprint.
@Model
final class RecentlyViewed {
    @Attribute(.unique) var ao3Id: Int
    var title: String
    var author: String
    var fandom: String
    var viewedAt: Date

    init(ao3Id: Int, title: String, author: String = "", fandom: String = "", viewedAt: Date = .now) {
        self.ao3Id = ao3Id
        self.title = title
        self.author = author
        self.fandom = fandom
        self.viewedAt = viewedAt
    }
}

@Model
final class SavedSearch {
    @Attribute(.unique) var name: String
    var prompt: String
    var sortColumn: String
    var sortDirection: String
    var savedAt: Date

    init(name: String, prompt: String, sortColumn: String = "_score", sortDirection: String = "desc", savedAt: Date = .now) {
        self.name = name
        self.prompt = prompt
        self.sortColumn = sortColumn
        self.sortDirection = sortDirection
        self.savedAt = savedAt
    }
}

/// A work the user has hidden ("block objectionable content" — App Store
/// guideline 1.2). Hidden ids are filtered out of Search and Browse results.
@Model
final class HiddenWork {
    @Attribute(.unique) var ao3Id: Int
    var title: String
    var hiddenAt: Date

    init(ao3Id: Int, title: String = "", hiddenAt: Date = .now) {
        self.ao3Id = ao3Id
        self.title = title
        self.hiddenAt = hiddenAt
    }
}

@Model
final class SubscriptionRecord {
    @Attribute(.unique) var key: String
    var kind: String
    var displayName: String
    var authorName: String = ""
    var lastSeenChapterCount: Int?
    var lastCheckedAt: Date?

    init(key: String, kind: String, displayName: String, authorName: String = "") {
        self.key = key
        self.kind = kind
        self.displayName = displayName
        self.authorName = authorName
    }
}

/// An AO3 author the user follows locally (no login required), mirroring the
/// per-work `isFollowed` flow. The background poller checks each followed
/// author's works page for newly-published works and fires a local
/// notification. `knownWorkIds` is the set of work ids already seen, so a new
/// work notifies exactly once; it's seeded when the user follows so previously
/// published works don't all alert on the first poll.
@Model
final class FollowedAuthor {
    @Attribute(.unique) var username: String
    var displayName: String
    var followedAt: Date
    var lastCheckedAt: Date?
    var knownWorkIds: [Int]

    init(username: String, displayName: String, followedAt: Date = .now,
         lastCheckedAt: Date? = nil, knownWorkIds: [Int] = []) {
        self.username = username
        self.displayName = displayName
        self.followedAt = followedAt
        self.lastCheckedAt = lastCheckedAt
        self.knownWorkIds = knownWorkIds
    }
}

@Model
final class CustomFolder {
    @Attribute(.unique) var name: String
    var createdAt: Date
    
    @Relationship(deleteRule: .nullify, inverse: \Work.folders)
    var works: [Work] = []
    
    init(name: String, createdAt: Date = .now) {
        self.name = name
        self.createdAt = createdAt
    }
}
