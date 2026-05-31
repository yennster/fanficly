import Foundation
import SwiftData

enum WorkPersistence {
    @MainActor
    static func upsert(payload: AO3WorkPayload, into context: ModelContext) -> Work {
        let ao3Id = payload.summary.id
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == ao3Id })
        let existing = (try? context.fetch(descriptor))?.first

        let work: Work
        if let existing {
            existing.title = payload.summary.title
            existing.authorName = payload.summary.author
            existing.summary = payload.summary.summary
            existing.rating = payload.summary.rating
            existing.warnings = payload.summary.warnings
            existing.categories = payload.summary.categories
            existing.fandoms = payload.summary.fandoms
            existing.characters = payload.summary.characters
            existing.relationships = payload.summary.relationships
            existing.freeforms = payload.summary.freeforms
            existing.language = payload.summary.language
            existing.wordCount = payload.summary.wordCount
            existing.chapterCount = payload.summary.chapterCount
            existing.totalChapters = payload.summary.totalChapters
            existing.kudos = payload.summary.kudos
            existing.hits = payload.summary.hits
            existing.isComplete = payload.summary.isComplete
            existing.updatedAt = payload.summary.updatedAt
            for ch in existing.chapters { context.delete(ch) }
            existing.chapters.removeAll()
            work = existing
        } else {
            work = Work(
                ao3Id: payload.summary.id,
                title: payload.summary.title,
                authorName: payload.summary.author,
                summary: payload.summary.summary,
                rating: payload.summary.rating,
                warnings: payload.summary.warnings,
                categories: payload.summary.categories,
                fandoms: payload.summary.fandoms,
                characters: payload.summary.characters,
                relationships: payload.summary.relationships,
                freeforms: payload.summary.freeforms,
                language: payload.summary.language,
                wordCount: payload.summary.wordCount,
                chapterCount: payload.summary.chapterCount,
                totalChapters: payload.summary.totalChapters,
                kudos: payload.summary.kudos,
                hits: payload.summary.hits,
                isComplete: payload.summary.isComplete,
                updatedAt: payload.summary.updatedAt
            )
            context.insert(work)
        }

        for ch in payload.chapters {
            let chapter = Chapter(work: work, index: ch.index, title: ch.title, bodyHTML: ch.bodyHTML)
            context.insert(chapter)
        }

        try? context.save()
        return work
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
