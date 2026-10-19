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
        // Every library work is findable in Spotlight, followed or not.
        indexWork(work)
        return work
    }

    // MARK: - Spotlight

    /// Core Spotlight domain for library works. The index is on-device; a tap
    /// on a result reaches `RootView`'s `CSSearchableItemActionType` handler,
    /// which opens the work through the resume route.
    static let spotlightDomain = "io.github.yennster.fanficly.works"

    /// Set once the launch task has rebuilt the index from the whole library.
    static let spotlightReindexedKey = "spotlight.reindexed.v1"

    /// What Spotlight shows for one library work. A Sendable value so items
    /// can be built off the main actor, in the index's completion handler.
    struct SpotlightEntry: Sendable, Equatable {
        let ao3Id: Int
        let title: String
        let author: String
        let summary: String
        let keywords: [String]
    }

    static func spotlightIdentifier(ao3Id: Int) -> String {
        "work-\(ao3Id)"
    }

    /// The AO3 work id in a `work-<id>` Spotlight identifier, or nil for
    /// anything else.
    static func workId(fromSpotlightIdentifier identifier: String) -> Int? {
        guard identifier.hasPrefix("work-") else { return nil }
        guard let id = Int(identifier.dropFirst("work-".count)), id > 0 else { return nil }
        return id
    }

    @MainActor
    static func spotlightEntry(for work: Work) -> SpotlightEntry {
        SpotlightEntry(
            ao3Id: work.ao3Id,
            title: work.title,
            author: work.authorName,
            summary: work.summary,
            keywords: work.fandoms + work.relationships + work.characters
        )
    }

    static func searchableItem(for entry: SpotlightEntry) -> CSSearchableItem {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        attributeSet.title = entry.title
        attributeSet.contentDescription = entry.summary
        attributeSet.artist = entry.author
        attributeSet.keywords = entry.keywords
        return CSSearchableItem(
            uniqueIdentifier: spotlightIdentifier(ao3Id: entry.ao3Id),
            domainIdentifier: spotlightDomain,
            attributeSet: attributeSet
        )
    }

    @MainActor
    static func indexWork(_ work: Work) {
        // Demo mode's library is in memory, but the index is the device's own.
        guard !FanficlyApp.isDemoMode else { return }
        CSSearchableIndex.default().indexSearchableItems(
            [searchableItem(for: spotlightEntry(for: work))], completionHandler: nil)
    }

    @MainActor
    static func deindexWork(ao3Id: Int) {
        CSSearchableIndex.default().deleteSearchableItems(
            withIdentifiers: [spotlightIdentifier(ao3Id: ao3Id)], completionHandler: nil)
    }

    /// Rebuilds the Spotlight index from the whole library: clears the domain,
    /// then indexes every saved work. Run once at launch (works saved before
    /// every library work was indexed, when only followed ones were) and after
    /// an iCloud restore (restored works skip `upsertMetadata`).
    @MainActor
    static func reindexLibrary(context: ModelContext) {
        let entries = ((try? context.fetch(FetchDescriptor<Work>())) ?? []).map { spotlightEntry(for: $0) }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [spotlightDomain]) { @Sendable _ in
            // Explicitly @Sendable: CoreSpotlight calls this off the main
            // actor, so it must not inherit this function's isolation.
            guard !entries.isEmpty else { return }
            CSSearchableIndex.default().indexSearchableItems(
                entries.map(searchableItem(for:)), completionHandler: nil)
        }
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
            // Following opts into the poller's new-chapter alerts — the one
            // notification source that works fully logged out — so this is
            // the moment to ask for permission, not the login-gated
            // Subscriptions tab.
            NotificationsAuthorization.requestAfterFollow()
        } else {
            work.followedAt = nil
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
            NotificationsAuthorization.requestAfterFollow()  // see toggleFollow
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
