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
    static func save(ao3Id: Int, anchor: ReadingAnchor, title: String, author: String, in context: ModelContext) {
        let descriptor = FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.ao3Id == ao3Id })
        if let rec = (try? context.fetch(descriptor))?.first {
            rec.chapterIndex = anchor.chapter
            rec.paragraphIndex = anchor.paragraph
            rec.title = title
            rec.author = author
            rec.updatedAt = .now
        } else {
            context.insert(ReadingProgress(
                ao3Id: ao3Id,
                chapterIndex: anchor.chapter,
                paragraphIndex: anchor.paragraph,
                title: title,
                author: author
            ))
        }
        try? context.save()
    }
}
