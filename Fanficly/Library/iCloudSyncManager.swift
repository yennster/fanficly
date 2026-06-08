import Foundation
import SwiftData

@MainActor
final class iCloudSyncManager {
    static let shared = iCloudSyncManager()
    
    private init() {}
    
    /// The URL to the backup file in the iCloud ubiquitous container.
    static var backupURL: URL? {
        guard let ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let docsURL = ubiquityURL.appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
        return docsURL.appendingPathComponent("library_backup.json")
    }
    
    /// Checks if a backup is available in iCloud (either downloaded or as a placeholder).
    var isBackupAvailable: Bool {
        guard let url = Self.backupURL else { return false }
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        let dir = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        let placeholderURL = dir.appendingPathComponent(".\(filename).icloud")
        return FileManager.default.fileExists(atPath: placeholderURL.path)
    }
    
    /// Gets the modification date of the iCloud backup file.
    var lastBackupDate: Date? {
        guard let url = Self.backupURL else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }
    
    /// Performs a backup of the SwiftData database to iCloud.
    func backupToiCloud(context: ModelContext) {
        guard let url = Self.backupURL else { return }
        
        do {
            // 1. Fetch all records from SwiftData
            let works = (try? context.fetch(FetchDescriptor<Work>())) ?? []
            let bookmarks = (try? context.fetch(FetchDescriptor<BookmarkRecord>())) ?? []
            let subscriptions = (try? context.fetch(FetchDescriptor<SubscriptionRecord>())) ?? []
            let searches = (try? context.fetch(FetchDescriptor<SavedSearch>())) ?? []
            let progress = (try? context.fetch(FetchDescriptor<ReadingProgress>())) ?? []
            let filters = (try? context.fetch(FetchDescriptor<SavedFilter>())) ?? []
            let hidden = (try? context.fetch(FetchDescriptor<HiddenWork>())) ?? []
            
            // 2. Map them to Codable structures
            let workBackups = works.map { work in
                WorkBackup(
                    ao3Id: work.ao3Id,
                    title: work.title,
                    authorName: work.authorName,
                    authorUsername: work.authorUsername,
                    summary: work.summary,
                    rating: work.rating,
                    warnings: work.warnings,
                    categories: work.categories,
                    fandoms: work.fandoms,
                    characters: work.characters,
                    relationships: work.relationships,
                    freeforms: work.freeforms,
                    language: work.language,
                    wordCount: work.wordCount,
                    chapterCount: work.chapterCount,
                    totalChapters: work.totalChapters,
                    kudos: work.kudos,
                    hits: work.hits,
                    bookmarksCount: work.bookmarksCount,
                    commentsCount: work.commentsCount,
                    isComplete: work.isComplete,
                    publishedAt: work.publishedAt,
                    updatedAt: work.updatedAt,
                    savedAt: work.savedAt,
                    lastReadAt: work.lastReadAt,
                    lastReadChapter: work.lastReadChapter,
                    lastReadProgress: work.lastReadProgress,
                    isFollowed: work.isFollowed,
                    followedAt: work.followedAt,
                    lastSeenChapterCount: work.lastSeenChapterCount,
                    isStarred: work.isStarred,
                    isPinned: work.isPinned,
                    chapters: work.chapters.sorted(by: { $0.index < $1.index }).map { ch in
                        ChapterBackup(index: ch.index, title: ch.title, bodyHTML: ch.bodyHTML)
                    }
                )
            }
            
            let bookmarkBackups = bookmarks.map {
                BookmarkBackup(ao3Id: $0.ao3Id, workAo3Id: $0.workAo3Id, notes: $0.notes, tags: $0.tags, savedAt: $0.savedAt)
            }
            
            let subscriptionBackups = subscriptions.map {
                SubscriptionBackup(
                    key: $0.key,
                    kind: $0.kind,
                    displayName: $0.displayName,
                    authorName: $0.authorName,
                    lastSeenChapterCount: $0.lastSeenChapterCount,
                    lastCheckedAt: $0.lastCheckedAt
                )
            }
            
            let searchBackups = searches.map {
                SearchBackup(name: $0.name, prompt: $0.prompt, sortColumn: $0.sortColumn, sortDirection: $0.sortDirection, savedAt: $0.savedAt)
            }
            
            let progressBackups = progress.map {
                ProgressBackup(ao3Id: $0.ao3Id, chapterIndex: $0.chapterIndex, paragraphIndex: $0.paragraphIndex, title: $0.title, author: $0.author, updatedAt: $0.updatedAt)
            }
            
            let filterBackups = filters.map {
                FilterBackup(name: $0.name, filtersJSON: $0.filtersJSON, savedAt: $0.savedAt)
            }
            
            let hiddenBackups = hidden.map {
                HiddenBackup(ao3Id: $0.ao3Id, title: $0.title, hiddenAt: $0.hiddenAt)
            }
            
            let backup = LibraryBackup(
                works: workBackups,
                bookmarks: bookmarkBackups,
                subscriptions: subscriptionBackups,
                searches: searchBackups,
                progress: progressBackups,
                filters: filterBackups,
                hidden: hiddenBackups,
                timestamp: .now
            )
            
            // 3. Serialize to JSON and write
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(backup)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to backup to iCloud: \(error)")
        }
    }
    
    /// Restores all records from iCloud backup. Returns true if successful.
    @discardableResult
    func restoreFromiCloud(context: ModelContext) async -> Bool {
        guard let url = Self.backupURL else {
            return false
        }
        
        let fileManager = FileManager.default
        let dir = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        let placeholderURL = dir.appendingPathComponent(".\(filename).icloud")
        
        if !fileManager.fileExists(atPath: url.path) && fileManager.fileExists(atPath: placeholderURL.path) {
            do {
                try fileManager.startDownloadingUbiquitousItem(at: url)
                // Poll for up to 5 seconds
                var downloaded = false
                for _ in 0..<25 {
                    if fileManager.fileExists(atPath: url.path) {
                        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                        if let status = values?.ubiquitousItemDownloadingStatus,
                           status == .current || status == .downloaded {
                            downloaded = true
                            break
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if !downloaded {
                    print("iCloud backup download timed out")
                    return false
                }
            } catch {
                print("Failed to download ubiquitous item: \(error)")
                return false
            }
        }
        
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let backup = try decoder.decode(LibraryBackup.self, from: data)
            
            // 1. Restore Works and their Chapters
            for w in backup.works {
                let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == w.ao3Id })
                let existing = (try? context.fetch(descriptor))?.first
                
                let work: Work
                if let existing {
                    work = existing
                } else {
                    work = Work(ao3Id: w.ao3Id, title: w.title, authorName: w.authorName)
                    context.insert(work)
                }
                
                work.title = w.title
                work.authorName = w.authorName
                work.authorUsername = w.authorUsername
                work.summary = w.summary
                work.rating = w.rating
                work.warnings = w.warnings
                work.categories = w.categories
                work.fandoms = w.fandoms
                work.characters = w.characters
                work.relationships = w.relationships
                work.freeforms = w.freeforms
                work.language = w.language
                work.wordCount = w.wordCount
                work.chapterCount = w.chapterCount
                work.totalChapters = w.totalChapters
                work.kudos = w.kudos
                work.hits = w.hits
                work.bookmarksCount = w.bookmarksCount
                work.commentsCount = w.commentsCount
                work.isComplete = w.isComplete
                work.publishedAt = w.publishedAt
                work.updatedAt = w.updatedAt
                work.savedAt = w.savedAt
                work.lastReadAt = w.lastReadAt
                work.lastReadChapter = w.lastReadChapter
                work.lastReadProgress = w.lastReadProgress
                work.isFollowed = w.isFollowed
                work.followedAt = w.followedAt
                work.lastSeenChapterCount = w.lastSeenChapterCount
                work.isStarred = w.isStarred ?? false
                work.isPinned = w.isPinned ?? false
                
                // Clear existing chapters first to prevent duplicates
                for ch in work.chapters { context.delete(ch) }
                work.chapters.removeAll()
                
                // Add backup chapters
                for ch in w.chapters {
                    let chapter = Chapter(work: work, index: ch.index, title: ch.title, bodyHTML: ch.bodyHTML)
                    context.insert(chapter)
                }
            }
            
            // 2. Restore BookmarkRecords
            for b in backup.bookmarks {
                let descriptor = FetchDescriptor<BookmarkRecord>(predicate: #Predicate { $0.ao3Id == b.ao3Id })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    existing.workAo3Id = b.workAo3Id
                    existing.notes = b.notes
                    existing.tags = b.tags
                    existing.savedAt = b.savedAt
                } else {
                    context.insert(BookmarkRecord(ao3Id: b.ao3Id, workAo3Id: b.workAo3Id, notes: b.notes, tags: b.tags, savedAt: b.savedAt))
                }
            }
            
            // 3. Restore SubscriptionRecords
            for s in backup.subscriptions {
                let descriptor = FetchDescriptor<SubscriptionRecord>(predicate: #Predicate { $0.key == s.key })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    existing.kind = s.kind
                    existing.displayName = s.displayName
                    existing.authorName = s.authorName
                    existing.lastSeenChapterCount = s.lastSeenChapterCount
                    existing.lastCheckedAt = s.lastCheckedAt
                } else {
                    let rec = SubscriptionRecord(key: s.key, kind: s.kind, displayName: s.displayName, authorName: s.authorName)
                    rec.lastSeenChapterCount = s.lastSeenChapterCount
                    rec.lastCheckedAt = s.lastCheckedAt
                    context.insert(rec)
                }
            }
            
            // 4. Restore SavedSearches
            for s in backup.searches {
                let descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.name == s.name })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    existing.prompt = s.prompt
                    existing.sortColumn = s.sortColumn
                    existing.sortDirection = s.sortDirection
                    existing.savedAt = s.savedAt
                } else {
                    context.insert(SavedSearch(name: s.name, prompt: s.prompt, sortColumn: s.sortColumn, sortDirection: s.sortDirection, savedAt: s.savedAt))
                }
            }
            
            // 5. Restore ReadingProgress entries
            for p in backup.progress {
                let descriptor = FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.ao3Id == p.ao3Id })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    existing.chapterIndex = p.chapterIndex
                    existing.paragraphIndex = p.paragraphIndex
                    existing.title = p.title
                    existing.author = p.author
                    existing.updatedAt = p.updatedAt
                } else {
                    context.insert(ReadingProgress(ao3Id: p.ao3Id, chapterIndex: p.chapterIndex, paragraphIndex: p.paragraphIndex, title: p.title, author: p.author, updatedAt: p.updatedAt))
                }
            }
            
            // 6. Restore SavedFilters
            for f in backup.filters {
                let descriptor = FetchDescriptor<SavedFilter>(predicate: #Predicate { $0.name == f.name })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    existing.filtersJSON = f.filtersJSON
                    existing.savedAt = f.savedAt
                } else {
                    context.insert(SavedFilter(name: f.name, filtersJSON: f.filtersJSON, savedAt: f.savedAt))
                }
            }
            
            // 7. Restore HiddenWorks
            for h in backup.hidden {
                let descriptor = FetchDescriptor<HiddenWork>(predicate: #Predicate { $0.ao3Id == h.ao3Id })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    existing.title = h.title
                    existing.hiddenAt = h.hiddenAt
                } else {
                    context.insert(HiddenWork(ao3Id: h.ao3Id, title: h.title, hiddenAt: h.hiddenAt))
                }
            }
            
            try context.save()
            return true
        } catch {
            print("Failed to restore from iCloud: \(error)")
            return false
        }
    }
    
    /// Deletes the backup file from iCloud.
    @discardableResult
    func clearFromiCloud() -> Bool {
        guard let url = Self.backupURL, FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            print("Failed to clear iCloud backup: \(error)")
            return false
        }
    }
}

// MARK: - Backup Codable Structs

struct LibraryBackup: Codable {
    let works: [WorkBackup]
    let bookmarks: [BookmarkBackup]
    let subscriptions: [SubscriptionBackup]
    let searches: [SearchBackup]
    let progress: [ProgressBackup]
    let filters: [FilterBackup]
    let hidden: [HiddenBackup]
    let timestamp: Date
}

struct WorkBackup: Codable {
    let ao3Id: Int
    let title: String
    let authorName: String
    let authorUsername: String
    let summary: String
    let rating: String
    let warnings: [String]
    let categories: [String]
    let fandoms: [String]
    let characters: [String]
    let relationships: [String]
    let freeforms: [String]
    let language: String
    let wordCount: Int
    let chapterCount: Int
    let totalChapters: Int?
    let kudos: Int
    let hits: Int
    let bookmarksCount: Int
    let commentsCount: Int
    let isComplete: Bool
    let publishedAt: Date?
    let updatedAt: Date?
    let savedAt: Date
    let lastReadAt: Date?
    let lastReadChapter: Int?
    let lastReadProgress: Double?
    let isFollowed: Bool
    let followedAt: Date?
    let lastSeenChapterCount: Int?
    let isStarred: Bool?
    let isPinned: Bool?
    let chapters: [ChapterBackup]
}

struct ChapterBackup: Codable {
    let index: Int
    let title: String
    let bodyHTML: String
}

struct BookmarkBackup: Codable {
    let ao3Id: Int
    let workAo3Id: Int
    let notes: String
    let tags: [String]
    let savedAt: Date
}

struct SubscriptionBackup: Codable {
    let key: String
    let kind: String
    let displayName: String
    let authorName: String
    let lastSeenChapterCount: Int?
    let lastCheckedAt: Date?
}

struct SearchBackup: Codable {
    let name: String
    let prompt: String
    let sortColumn: String
    let sortDirection: String
    let savedAt: Date
}

struct ProgressBackup: Codable {
    let ao3Id: Int
    let chapterIndex: Int
    let paragraphIndex: Int
    let title: String
    let author: String
    let updatedAt: Date
}

struct FilterBackup: Codable {
    let name: String
    let filtersJSON: String
    let savedAt: Date
}

struct HiddenBackup: Codable {
    let ao3Id: Int
    let title: String
    let hiddenAt: Date
}
