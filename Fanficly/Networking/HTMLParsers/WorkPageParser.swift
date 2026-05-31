import Foundation
import SwiftSoup

enum WorkPageParser {
    static func parse(html: String, workId: Int) throws -> AO3WorkPayload {
        let doc = try SwiftSoup.parse(html)

        // Strip AO3's screen-reader-only landmark headings ("Chapter Text",
        // "Work Text", "Notes", etc.) so they don't render in the body.
        try? doc.select("h3.landmark, .landmark.heading").remove()

        let title = try firstNonEmptyText(in: doc, selectors: [
            "#workskin .preface.group h2.title.heading",
            "#workskin h2.title.heading",
            "h2.title.heading",
            "h2.title",
        ])
        let author: String = {
            if let byline = try? doc.select("h3.byline").first() {
                let linkTexts = (try? byline.select("a").array().compactMap { try? $0.text() }) ?? []
                let nonEmpty = linkTexts.filter { !$0.isEmpty }
                if !nonEmpty.isEmpty {
                    return nonEmpty.joined(separator: ", ")
                }
                if let txt = try? byline.text().trimmingCharacters(in: .whitespaces), !txt.isEmpty {
                    let lower = txt.lowercased()
                    if lower.hasPrefix("by ") { return String(txt.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                    return txt
                }
            }
            if let creator = try? doc.select("dl.work.meta dd.creator a, dl.work.meta dd.creator").first()?.text() {
                return creator.trimmingCharacters(in: .whitespaces)
            }
            return "Anonymous"
        }()

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
        let isComplete = (totalChapters != nil && chapterCount == totalChapters)

        let summary = try doc.select("#workskin .summary blockquote.userstuff, .summary blockquote.userstuff").first()?.html() ?? ""

        let chapters = try parseChapters(doc: doc, totalDeclared: chapterCount)

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

    private static func parseChapters(doc: Document, totalDeclared: Int) throws -> [AO3ChapterPayload] {
        let nestedChapters = try doc.select("div.chapter[id^=chapter-]")
        if !nestedChapters.isEmpty() {
            return try nestedChapters.array().enumerated().map { index, div in
                let rawTitle = try div.select("h3.title").first()?.text() ?? ""
                let bodyEl = try div.select("div.userstuff").first()
                let body = try bodyEl?.html() ?? ""
                return AO3ChapterPayload(index: index + 1, title: cleanChapterTitle(rawTitle, index: index + 1), bodyHTML: body)
            }
        }

        let workskinChapters = try doc.select("#workskin > div.chapter, #workskin div[role=article]")
        if !workskinChapters.isEmpty() {
            return try workskinChapters.array().enumerated().map { index, div in
                let rawTitle = try div.select("h3.title, h2.title").first()?.text() ?? ""
                let body = try (div.select("div.userstuff").first()?.html()) ?? ""
                return AO3ChapterPayload(index: index + 1, title: cleanChapterTitle(rawTitle, index: index + 1), bodyHTML: body)
            }
        }

        if let single = try doc.select("#workskin .userstuff, div#chapters div.userstuff, div#chapters").first() {
            return [AO3ChapterPayload(index: 1, title: "", bodyHTML: try single.html())]
        }

        return []
    }

    /// AO3 prefixes each chapter heading with "Chapter N: ". Strip that so
    /// the UI can render the chapter number itself, and treat a bare
    /// "Chapter N" (author gave no real title) as no title at all.
    static func cleanChapterTitle(_ raw: String, index: Int) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        // Strip a leading "Chapter <number>: " or "Chapter <number>".
        if let r = t.range(of: #"^Chapter\s+\d+\s*:?\s*"#, options: .regularExpression) {
            t = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        // What remains being just "Chapter N" (any number) means no real title.
        if t.range(of: #"^Chapter\s+\d+$"#, options: .regularExpression) != nil {
            return ""
        }
        return t
    }

    private static func firstNonEmptyText(in doc: Document, selectors: [String]) throws -> String {
        for sel in selectors {
            if let el = try doc.select(sel).first() {
                let text = try el.text().trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return text }
            }
        }
        return ""
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
