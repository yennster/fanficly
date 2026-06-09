import Foundation
import SwiftData

enum ReadingProgressStore {
    @MainActor
    static func load(ao3Id: Int, in context: ModelContext) -> ReadingAnchor? {
        let descriptor = FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.ao3Id == ao3Id })
        guard let rec = (try? context.fetch(descriptor))?.first else { return nil }
        return ReadingAnchor(chapter: rec.chapterIndex, paragraph: rec.paragraphIndex)
    }

    @MainActor
    static func save(ao3Id: Int, anchor: ReadingAnchor, title: String, author: String,
                     progress: Double? = nil, syncWidgetImmediately: Bool = false, in context: ModelContext) {
        let now = Date.now
        let descriptor = FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.ao3Id == ao3Id })
        if let rec = (try? context.fetch(descriptor))?.first {
            rec.chapterIndex = anchor.chapter
            rec.paragraphIndex = anchor.paragraph
            rec.title = title
            rec.author = author
            rec.updatedAt = now
        } else {
            context.insert(ReadingProgress(
                ao3Id: ao3Id,
                chapterIndex: anchor.chapter,
                paragraphIndex: anchor.paragraph,
                title: title,
                author: author
            ))
        }

        let workDescriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == ao3Id })
        if let work = (try? context.fetch(workDescriptor))?.first {
            work.lastReadAt = now
            work.lastReadChapter = anchor.chapter
            if let progress {
                work.lastReadProgress = progress
            }
        }

        try? context.save()

        if let progress {
            WidgetProgressStore.save(
                id: ao3Id,
                title: title,
                author: author,
                progress: progress,
                chapter: anchor.chapter,
                paragraph: anchor.paragraph,
                updatedAt: now,
                syncImmediately: syncWidgetImmediately
            )
        }
    }
}
