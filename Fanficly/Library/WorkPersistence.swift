import Foundation
import SwiftData

enum WorkPersistence {
    @MainActor
    static func upsert(payload: AO3WorkPayload, into context: ModelContext) -> Work {
        let work = upsertMetadata(summary: payload.summary, into: context, save: false)

        for ch in work.chapters { context.delete(ch) }
        work.chapters.removeAll()
        for ch in payload.chapters {
            let chapter = Chapter(work: work, index: ch.index, title: ch.title, bodyHTML: ch.bodyHTML)
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
        return work
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
        } else {
            work.followedAt = nil
        }
        try? context.save()
        return work.isFollowed
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
