import Foundation
import SwiftSoup

enum WorkPageParser {
    static func parse(html: String, workId: Int) throws -> AO3WorkPayload {
        let doc = try SwiftSoup.parse(html)

        // Strip AO3's screen-reader-only landmark headings ("Chapter Text",
        // "Work Text", "Notes", etc.) so they don't render in the body.
        _ = try? doc.select("h3.landmark, .landmark.heading").remove()

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
        // First byline link's /users/<login> segment, for "more by this author".
        let authorUsername: String = {
            let byline = try? doc.select("h3.byline a").first()?.attr("href")          // String??
            let creator = try? doc.select("dl.work.meta dd.creator a").first()?.attr("href")
            let href = (byline ?? nil) ?? (creator ?? nil) ?? ""
            return SearchResultsParser.authorLogin(fromHref: href)
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
            authorUsername: authorUsername,
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
        // Ordered AO3 chapter ids (from the jump menu / index) so each rendered
        // chapter can map sequence → id for per-chapter comments.
        let orderedIds = chapterIndexIds(doc: doc)
        func idAt(_ index: Int) -> Int? { index < orderedIds.count ? orderedIds[index] : nil }

        let nestedChapters = try doc.select("div.chapter[id^=chapter-]")
        if !nestedChapters.isEmpty() {
            return try nestedChapters.array().enumerated().map { index, div in
                let rawTitle = try div.select("h3.title").first()?.text() ?? ""
                let bodyEl = try div.select("div.userstuff").first()
                let body = try bodyEl?.html() ?? ""
                return AO3ChapterPayload(index: index + 1,
                                         title: cleanChapterTitle(rawTitle, index: index + 1),
                                         bodyHTML: body,
                                         aoId: chapterAoId(in: div) ?? idAt(index))
            }
        }

        let workskinChapters = try doc.select("#workskin > div.chapter, #workskin div[role=article]")
        if !workskinChapters.isEmpty() {
            return try workskinChapters.array().enumerated().map { index, div in
                let rawTitle = try div.select("h3.title, h2.title").first()?.text() ?? ""
                let body = try (div.select("div.userstuff").first()?.html()) ?? ""
                return AO3ChapterPayload(index: index + 1,
                                         title: cleanChapterTitle(rawTitle, index: index + 1),
                                         bodyHTML: body,
                                         aoId: chapterAoId(in: div) ?? idAt(index))
            }
        }

        if let single = try doc.select("#workskin .userstuff, div#chapters div.userstuff, div#chapters").first() {
            return [AO3ChapterPayload(index: 1, title: "", bodyHTML: try single.html(), aoId: idAt(0))]
        }

        return []
    }

    /// A chapter's AO3 id from its heading link — full-work view links each
    /// chapter title to `/works/<id>/chapters/<chapterId>`.
    private static func chapterAoId(in div: Element) -> Int? {
        if let href = try? div.select("h3.title a[href], h3.landmark.heading a[href]").first()?.attr("href"),
           let id = chapterId(fromHref: href) { return id }
        if let href = try? div.select("a[href*=/chapters/]").first()?.attr("href"),
           let id = chapterId(fromHref: href) { return id }
        return nil
    }

    /// Ordered chapter ids from the chapter jump `<select id="selected_id">`
    /// (its option values are chapter ids) or, failing that, the chapter index
    /// links — so multi-chapter works map sequence → AO3 chapter id.
    private static func chapterIndexIds(doc: Document) -> [Int] {
        if let options = try? doc.select("select#selected_id option"), !options.isEmpty() {
            let ids = options.array().compactMap { Int(((try? $0.attr("value")) ?? "").trimmingCharacters(in: .whitespaces)) }
            if !ids.isEmpty { return ids }
        }
        if let links = try? doc.select("#chapter_index a[href*=/chapters/], ol.chapter.index a[href*=/chapters/]"), !links.isEmpty() {
            let ids = links.array().compactMap { chapterId(fromHref: (try? $0.attr("href")) ?? "") }
            if !ids.isEmpty { return ids }
        }
        return []
    }

    /// Extracts `123` from a `/works/9/chapters/123` style href.
    static func chapterId(fromHref href: String) -> Int? {
        guard let r = href.range(of: #"/chapters/(\d+)"#, options: .regularExpression) else { return nil }
        return Int(href[r].dropFirst("/chapters/".count))
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

/// Parses the comment thread (and the comment-form pseud id) from a work page
/// fetched with `?show_comments=true`. Comments nest via `ol.thread` inside
/// each `li.comment`; depth drives the reply indentation in the UI.
enum CommentsParser {
    static func parse(html: String) throws -> [AO3Comment] {
        let doc = try SwiftSoup.parse(html)
        // Scope to the comments region so work-body blockquotes aren't mistaken
        // for comments; fall back to the whole doc if the wrapper isn't found.
        let scope = try doc.select("#comments_placeholder, div#comments, ul.comments").first() ?? doc
        let comments = try scope.select("li.comment")
        return try comments.array().compactMap(parseComment)
    }

    private static func parseComment(_ li: Element) throws -> AO3Comment? {
        let idAttr = try li.attr("id")              // e.g. "comment_123456"
        guard idAttr.hasPrefix("comment_") else { return nil }
        let id = String(idAttr.dropFirst("comment_".count))
        guard !id.isEmpty else { return nil }

        let byline = try li.select("h4.byline, h4.heading.byline").first()
        let bylineAnchor = try byline?.select("a").first()
        let username = SearchResultsParser.authorLogin(fromHref: (try? bylineAnchor?.attr("href") ?? "") ?? "")
        let name: String = {
            if let t = (try? bylineAnchor?.text() ?? ""), !t.isEmpty { return t }
            if let t = (try? byline?.text() ?? ""), !t.isEmpty { return t }
            return "Anonymous"
        }()

        let dateText = (try? li.select("span.posted.datetime, p.datetime").first()?.text() ?? "") ?? ""
        // `.first()` is this comment's own body — it precedes any nested replies'
        // blockquotes in document order.
        let bodyHTML = (try? li.select("blockquote.userstuff").first()?.html() ?? "") ?? ""

        // Depth = number of ancestor li.comment (nested ol.thread → reply).
        var depth = 0
        var parent = li.parent()
        while let p = parent {
            if p.tagName() == "li", p.hasClass("comment") { depth += 1 }
            parent = p.parent()
        }

        return AO3Comment(
            id: id,
            commenterName: name,
            commenterUsername: username,
            dateText: dateText,
            bodyHTML: bodyHTML,
            depth: depth
        )
    }

    /// The user's default pseud id from the comment form's `<select>`, so a
    /// posted comment is attributed to the right pseud. Returns nil when no
    /// selector is present (logged out, or AO3 will use the default pseud).
    static func defaultPseudId(html: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html) else { return nil }
        guard let select = try? doc.select("select[name='comment[pseud_id]']").first() else { return nil }
        if let selected = try? select.select("option[selected]").first(),
           let value = try? selected.attr("value"), !value.isEmpty {
            return value
        }
        if let first = try? select.select("option").first(),
           let value = try? first.attr("value"), !value.isEmpty {
            return value
        }
        return nil
    }

    /// The page's top-level new-comment form, so a post can replay AO3's own
    /// request rather than hardcoding it: AO3 encodes the target chapter in the
    /// form's `action` (`/works/<id>/chapters/<cid>/comments`), so capturing the
    /// action plus the form's hidden inputs (CSRF token, any `commentable`
    /// fields) and the default pseud is enough to post to the right chapter.
    /// Returns nil when no composer is present (e.g. logged out). `base`
    /// resolves a relative action.
    static func newCommentForm(html: String, base: URL) -> (action: URL, fields: [String: String])? {
        guard let doc = try? SwiftSoup.parse(html),
              let forms = try? doc.select("form[action*=/comments]") else { return nil }
        let composers = forms.array().filter { hasCommentTextarea($0) }
        // Prefer the page-level composer over inline reply boxes nested in comments.
        guard let form = composers.first(where: { !isInsideComment($0) }) ?? composers.first else { return nil }

        let actionStr = (try? form.attr("action")) ?? ""
        guard !actionStr.isEmpty, let action = URL(string: actionStr, relativeTo: base)?.absoluteURL else { return nil }

        var fields: [String: String] = [:]
        if let hidden = try? form.select("input[type=hidden]") {
            for input in hidden.array() {
                let name = (try? input.attr("name")) ?? ""
                guard !name.isEmpty else { continue }
                fields[name] = (try? input.attr("value")) ?? ""
            }
        }
        if let pseud = defaultPseudId(html: html) { fields["comment[pseud_id]"] = pseud }
        return (action, fields)
    }

    private static func hasCommentTextarea(_ form: Element) -> Bool {
        guard let areas = try? form.select("textarea") else { return false }
        return areas.array().contains { ((try? $0.attr("name")) ?? "").contains("comment_content") }
    }

    private static func isInsideComment(_ el: Element) -> Bool {
        var node = el.parent()
        while let n = node {
            if n.tagName() == "li", n.hasClass("comment") { return true }
            node = n.parent()
        }
        return false
    }
}
