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
            // Following opts into the poller's new-chapter alerts — the one
            // notification source that works fully logged out — so this is
            // the moment to ask for permission, not the login-gated
            // Subscriptions tab.
            NotificationsAuthorization.requestAfterFollow()
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
            NotificationsAuthorization.requestAfterFollow()  // see toggleFollow
            return true
        }
    }

    /// Badges for one page of search/browse results, keyed by work id. One
    /// fetch per model for the whole page, never one per row.
    @MainActor
    static func resultBadges(for works: [AO3WorkSummary], in context: ModelContext) -> [Int: ResultBadge] {
        guard !works.isEmpty else { return [:] }
        let ids = works.map(\.id)
        let saved = (try? context.fetch(FetchDescriptor<Work>(predicate: #Predicate { ids.contains($0.ao3Id) }))) ?? []
        let started = (try? context.fetch(FetchDescriptor<ReadingProgress>(predicate: #Predicate { ids.contains($0.ao3Id) }))) ?? []
        let stats = (try? context.fetch(FetchDescriptor<ReadingStat>(predicate: #Predicate { ids.contains($0.ao3Id) }))) ?? []
        let savedById = Dictionary(saved.map { ($0.ao3Id, $0) }, uniquingKeysWith: { first, _ in first })
        let startedIds = Set(started.map(\.ao3Id))
        let statById = Dictionary(stats.map { ($0.ao3Id, $0) }, uniquingKeysWith: { first, _ in first })

        var badges: [Int: ResultBadge] = [:]
        for work in works {
            let savedWork = savedById[work.id]
            // The saved position, as the Library row shows it; a story read
            // without saving only has its stats row's furthest point.
            let progress = [savedWork?.lastReadProgress, statById[work.id]?.maxProgress]
                .compactMap { $0 }
                .first { $0 > 0 }
            badges[work.id] = resultBadge(
                inLibrary: savedWork != nil,
                started: startedIds.contains(work.id) || savedWork?.lastReadAt != nil,
                progress: progress,
                isComplete: work.isComplete
            )
        }
        return badges
    }

    /// The pure mapping behind a result row's badge. Reading status wins over
    /// "In Library"; "Finished" uses the Library row's rule (99%, or 95% of a
    /// complete work).
    static func resultBadge(inLibrary: Bool, started: Bool, progress: Double?, isComplete: Bool) -> ResultBadge? {
        if let raw = progress, raw.isFinite, raw > 0 {
            let p = min(raw, 1)
            if p >= 0.99 || (isComplete && p >= 0.95) { return .finished }
            return .percent(min(max(Int(p * 100), 1), 99))
        }
        if started { return .started }
        return inLibrary ? .inLibrary : nil
    }

    static let invalidEPUBSweepKey = "library.invalidEPUBSweep.v1"

    /// One-time: deletes `library/<id>.epub` files that aren't an e-book.
    /// Before downloads failed closed (#128), AO3's login page or an error
    /// page could be saved there, and `epubURL` only checks the file exists,
    /// so the work showed as Downloaded and nothing ever re-downloaded it.
    /// Returns the files it removed.
    @discardableResult
    static func removeInvalidEPUBsIfNeeded(defaults: UserDefaults = .standard,
                                           directory: URL? = nil) -> [URL] {
        guard !defaults.bool(forKey: invalidEPUBSweepKey) else { return [] }
        defaults.set(true, forKey: invalidEPUBSweepKey)
        let fm = FileManager.default
        guard let dir = directory ?? (try? fm.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ))?.appendingPathComponent("library", isDirectory: true),
              let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var removed: [URL] = []
        for file in files where file.pathExtension == "epub" {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let head = (try? handle.read(upToCount: 68)) ?? Data()
            try? handle.close()
            if !AO3Client.isEbook(head), (try? fm.removeItem(at: file)) != nil {
                removed.append(file)
            }
        }
        return removed
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

/// Works you've left kudos on, remembered on this device so the kudos button
/// reads "Kudos Left" instead of inviting a second tap. Cleared on logout, so
/// it always belongs to the signed-in account (AO3 counts one kudo per
/// account) and no username is kept beside it. Not in the iCloud library
/// backup: AO3 itself still refuses a duplicate, which reads as already left.
enum KudosStore {
    static let key = "kudos.leftWorkIds"

    static func hasLeft(workId: Int, defaults: UserDefaults = .standard) -> Bool {
        workIds(defaults).contains(workId)
    }

    static func markLeft(workId: Int, defaults: UserDefaults = .standard) {
        var ids = workIds(defaults)
        guard !ids.contains(workId) else { return }
        ids.append(workId)
        defaults.set(ids, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    private static func workIds(_ defaults: UserDefaults) -> [Int] {
        defaults.array(forKey: key) as? [Int] ?? []
    }
}

/// The small status badge on a search or browse result row (RM-002).
enum ResultBadge: Equatable, Sendable {
    case finished
    case percent(Int)
    /// Opened in the reader, but no fraction is known yet.
    case started
    case inLibrary

    var text: String {
        switch self {
        case .finished:           "Finished"
        case .percent(let value): "\(value)%"
        case .started:            "Started"
        case .inLibrary:          "In Library"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .finished:           "Finished reading"
        case .percent(let value): "\(value) percent read"
        case .started:            "Started reading"
        case .inLibrary:          "In your Library"
        }
    }

    var symbol: String {
        switch self {
        case .finished:  "checkmark.circle.fill"
        case .percent:   "book"
        case .started:   "book"
        case .inLibrary: "books.vertical"
        }
    }
}
