import Foundation
import SwiftSoup

enum WorkPageParser {
    static func parse(html: String, workId: Int) throws -> AO3WorkPayload {
        let doc = try SwiftSoup.parse(html)

        let title = try doc.select("h2.title.heading").first()?.text() ?? ""
        let author = try doc.select("h3.byline.heading a[rel=author]").array()
            .map { try $0.text() }.joined(separator: ", ")

        let meta = try doc.select("dl.work.meta.group").first()
        let rating = try meta?.select("dd.rating a.tag").first()?.text() ?? "Not Rated"
        let warnings = try meta?.select("dd.warning a.tag").array().map { try $0.text() } ?? []
        let categories = try meta?.select("dd.category a.tag").array().map { try $0.text() } ?? []
        let fandoms = try meta?.select("dd.fandom a.tag").array().map { try $0.text() } ?? []
        let relationships = try meta?.select("dd.relationship a.tag").array().map { try $0.text() } ?? []
        let characters = try meta?.select("dd.character a.tag").array().map { try $0.text() } ?? []
        let freeforms = try meta?.select("dd.freeform a.tag").array().map { try $0.text() } ?? []
        let language = try meta?.select("dd.language").first()?.text().trimmingCharacters(in: .whitespaces) ?? "English"

        let statsDl = try meta?.select("dl.stats").first()
        let wordCount = parseInt(try statsDl?.select("dd.words").first()?.text() ?? "0")
        let kudos = parseInt(try statsDl?.select("dd.kudos").first()?.text() ?? "0")
        let hits = parseInt(try statsDl?.select("dd.hits").first()?.text() ?? "0")
        let bookmarksCount = parseInt(try statsDl?.select("dd.bookmarks").first()?.text() ?? "0")
        let commentsCount = parseInt(try statsDl?.select("dd.comments").first()?.text() ?? "0")

        let chaptersText = try statsDl?.select("dd.chapters").first()?.text() ?? "1/1"
        let (chapterCount, totalChapters) = parseChapterFraction(chaptersText)
        let isComplete: Bool = (totalChapters != nil && chapterCount == totalChapters)

        let summary = try doc.select("div.summary blockquote.userstuff").first()?.html() ?? ""

        let chapters = try parseChapters(doc: doc)

        let publishedAt = parseAO3Date(try statsDl?.select("dd.published").first()?.text() ?? "")
        let updatedAt = parseAO3Date(try statsDl?.select("dd.status").first()?.text() ?? "") ?? publishedAt

        let summaryStruct = AO3WorkSummary(
            id: workId,
            title: title,
            author: author,
            summary: summary,
            rating: rating,
            warnings: warnings,
            categories: categories,
            fandoms: fandoms,
            characters: characters,
            relationships: relationships,
            freeforms: freeforms,
            wordCount: wordCount,
            chapterCount: chapterCount,
            totalChapters: totalChapters,
            language: language,
            kudos: kudos,
            hits: hits,
            isComplete: isComplete,
            updatedAt: updatedAt
        )

        _ = (bookmarksCount, commentsCount)
        return AO3WorkPayload(summary: summaryStruct, chapters: chapters)
    }

    private static func parseChapters(doc: Document) throws -> [AO3ChapterPayload] {
        let chapterDivs = try doc.select("div.chapter[id^=chapter-]")
        if !chapterDivs.isEmpty() {
            return try chapterDivs.array().enumerated().map { index, div in
                let title = try div.select("h3.title").first()?.text() ?? ""
                let bodyEl = try div.select("div.userstuff").first()
                let body = try bodyEl?.html() ?? ""
                return AO3ChapterPayload(index: index + 1, title: title, bodyHTML: body)
            }
        }

        if let single = try doc.select("div#chapters div.userstuff").first() {
            let title = try doc.select("h2.title.heading").first()?.text() ?? ""
            return [AO3ChapterPayload(index: 1, title: title, bodyHTML: try single.html())]
        }

        return []
    }

    private static func parseInt(_ s: String) -> Int {
        Int(s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private static func parseChapterFraction(_ s: String) -> (current: Int, total: Int?) {
        let parts = s.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        let current = Int(parts.first ?? "1") ?? 1
        let total: Int?
        if parts.count > 1, parts[1] == "?" {
            total = nil
        } else if parts.count > 1, let n = Int(parts[1]) {
            total = n
        } else {
            total = current
        }
        return (current, total)
    }

    private static func parseAO3Date(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: trimmed)
    }
}
