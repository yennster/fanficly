import Foundation
import SwiftData
import CoreSpotlight
import UniformTypeIdentifiers

enum WorkPersistence {
    @MainActor
    static func upsert(payload: AO3WorkPayload, into context: ModelContext) -> Work {
        let work = upsertMetadata(summary: payload.summary, into: context, save: false)

        for ch in work.chapters { context.delete(ch) }
        work.chapters.removeAll()
        for ch in payload.chapters {
            let chapter = Chapter(work: work, index: ch.index, title: ch.title, bodyHTML: ch.bodyHTML, aoId: ch.aoId)
            context.insert(chapter)
        }

        try? context.save()
        return work
    }

    /// Upsert just the metadata (no chapter bodies). Used by the local
    /// follow action, which doesn't need to download the full work.
    @MainActor
    @discardableResult
    static func upsertMetadata(summary: AO3WorkSummary, into context: ModelContext, save: Bool = true) -> Work {
        let ao3Id = summary.id
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == ao3Id })
        let existing = (try? context.fetch(descriptor))?.first

        let work: Work
        if let existing {
            work = existing
        } else {
            work = Work(ao3Id: summary.id, title: summary.title, authorName: summary.author)
            context.insert(work)
        }

        work.title = summary.title
        work.authorName = summary.author
        work.authorUsername = summary.authorUsername
        work.summary = summary.summary
        work.rating = summary.rating
        work.warnings = summary.warnings
        work.categories = summary.categories
        work.fandoms = summary.fandoms
        work.characters = summary.characters
        work.relationships = summary.relationships
        work.freeforms = summary.freeforms
        work.language = summary.language
        work.wordCount = summary.wordCount
        work.chapterCount = summary.chapterCount
        work.totalChapters = summary.totalChapters
        work.kudos = summary.kudos
        work.hits = summary.hits
        work.isComplete = summary.isComplete
        work.updatedAt = summary.updatedAt

        if save { try? context.save() }
        if work.isFollowed {
            indexWork(work)
        } else {
            deindexWork(ao3Id: work.ao3Id)
        }
        return work
    }

    @MainActor
    static func indexWork(_ work: Work) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        attributeSet.title = work.title
        attributeSet.contentDescription = work.summary
        attributeSet.artist = work.authorName
        
        let item = CSSearchableItem(
            uniqueIdentifier: "work-\(work.ao3Id)",
            domainIdentifier: "io.github.yennster.fanficly.works",
            attributeSet: attributeSet
        )
        CSSearchableIndex.default().indexSearchableItems([item], completionHandler: nil)
    }

    @MainActor
    static func deindexWork(ao3Id: Int) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ["work-\(ao3Id)"], completionHandler: nil)
    }

    @MainActor
    static func isFollowed(workId: Int, in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == workId })
        return (try? context.fetch(descriptor))?.first?.isFollowed ?? false
    }

    /// Toggle the local follow flag, persisting metadata if needed.
    /// Returns the new follow state.
    @MainActor
    @discardableResult
    static func toggleFollow(summary: AO3WorkSummary, into context: ModelContext) -> Bool {
        let work = upsertMetadata(summary: summary, into: context, save: false)
        work.isFollowed.toggle()
        if work.isFollowed {
            work.followedAt = .now
            work.lastSeenChapterCount = summary.chapterCount
            indexWork(work)
        } else {
            work.followedAt = nil
            deindexWork(ao3Id: work.ao3Id)
        }
        try? context.save()
        iCloudSyncManager.shared.queueBackup(context: context)
        return work.isFollowed
    }

    /// Record (or bump to "now") a work in the recently-viewed history.
    @MainActor
    static func recordView(summary: AO3WorkSummary, into context: ModelContext, limit: Int = 50) {
        recordView(ao3Id: summary.id, title: summary.title, author: summary.author,
                   fandom: summary.fandoms.first ?? "", into: context, limit: limit)
    }

    /// Overload for Library reads, which carry a `Work` rather than a summary.
    @MainActor
    static func recordView(work: Work, into context: ModelContext, limit: Int = 50) {
        recordView(ao3Id: work.ao3Id, title: work.title, author: work.authorName,
                   fandom: work.fandoms.first ?? "", into: context, limit: limit)
    }

    /// Upsert a recently-viewed entry, then trim the list to the newest `limit`.
    @MainActor
    static func recordView(ao3Id: Int, title: String, author: String, fandom: String,
                           into context: ModelContext, limit: Int = 50) {
        let descriptor = FetchDescriptor<RecentlyViewed>(predicate: #Predicate { $0.ao3Id == ao3Id })
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.viewedAt = .now
            existing.title = title
            existing.author = author
            existing.fandom = fandom
        } else {
            context.insert(RecentlyViewed(ao3Id: ao3Id, title: title, author: author, fandom: fandom))
        }

        let all = (try? context.fetch(FetchDescriptor<RecentlyViewed>(
            sortBy: [SortDescriptor(\.viewedAt, order: .reverse)]))) ?? []
        if all.count > limit {
            for stale in all[limit...] { context.delete(stale) }
        }
        try? context.save()
    }

    // MARK: - Followed authors

    @MainActor
    static func isAuthorFollowed(username: String, in context: ModelContext) -> Bool {
        guard !username.isEmpty else { return false }
        let descriptor = FetchDescriptor<FollowedAuthor>(predicate: #Predicate { $0.username == username })
        return ((try? context.fetch(descriptor))?.first) != nil
    }

    /// Toggle following an author. `seedWorkIds` are the work ids currently
    /// visible for the author at follow time, recorded so the poller doesn't
    /// alert for already-published works on its first check. Returns the new
    /// follow state.
    @MainActor
    @discardableResult
    static func toggleFollowAuthor(username: String, displayName: String,
                                   seedWorkIds: [Int] = [], into context: ModelContext) -> Bool {
        guard !username.isEmpty else { return false }
        let descriptor = FetchDescriptor<FollowedAuthor>(predicate: #Predicate { $0.username == username })
        if let existing = (try? context.fetch(descriptor))?.first {
            context.delete(existing)
            try? context.save()
            iCloudSyncManager.shared.queueBackup(context: context)
            return false
        } else {
            context.insert(FollowedAuthor(
                username: username,
                displayName: displayName.isEmpty ? username : displayName,
                knownWorkIds: seedWorkIds
            ))
            try? context.save()
            iCloudSyncManager.shared.queueBackup(context: context)
            return true
        }
    }

    static func epubURL(workId: Int) -> URL? {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return nil }
        let url = docs.appendingPathComponent("library/\(workId).epub")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
