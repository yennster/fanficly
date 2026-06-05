import Foundation
import SwiftSoup

enum SearchResultsParser {
    static func parse(html: String) throws -> AO3SearchResults {
        let doc = try SwiftSoup.parse(html)
        let blurbs = try doc.select("li.work.blurb")
        let works = try blurbs.compactMap(parseBlurb)

        let pagination = try doc.select("ol.pagination li")
        var currentPage = 1
        var totalPages = 1
        for li in pagination.array() {
            guard let num = Int(try li.text().trimmingCharacters(in: .whitespaces)) else { continue }
            totalPages = max(totalPages, num)
            // AO3 (Rails will_paginate) marks the current page with a "current"
            // class. Depending on the page it lands on the <li> itself OR on an
            // inner <span>/<em> — e.g. `<li><span class="current">2</span></li>`,
            // where the <li> has no class. Check both, or currentPage stuck at 1
            // and "Load more" keeps re-requesting the same page.
            let liIsCurrent = try li.attr("class").contains("current")
            let innerIsCurrent = try !li.select(".current").array().isEmpty
            if liIsCurrent || innerIsCurrent { currentPage = num }
        }

        return AO3SearchResults(works: works, totalPages: totalPages, currentPage: currentPage)
    }

    static func parseBlurb(_ li: Element) throws -> AO3WorkSummary? {
        let idAttr = try li.attr("id")
        guard let id = Int(idAttr.replacingOccurrences(of: "work_", with: "")) else { return nil }

        let titleAnchor = try li.select("h4.heading a").first()
        let title = try titleAnchor?.text() ?? ""

        let authorAnchors = try li.select("h4.heading a[rel=author]").array()
        let author = try authorAnchors.map { try $0.text() }.joined(separator: ", ")
        let authorUsername = authorLogin(fromHref: (try? authorAnchors.first?.attr("href")) ?? "")

        let fandoms = try li.select("h5.fandoms a.tag").array().map { try $0.text() }

        let requiredTagTexts: [String] = try li.select("ul.required-tags span.text").array().map { try $0.text() }
        let rating: String = requiredTagTexts.first { isRating($0) } ?? "Not Rated"
        let warnings: [String] = requiredTagTexts.filter { isWarning($0) }
        let categories: [String] = requiredTagTexts.filter { isCategory($0) }
        let isComplete: Bool = requiredTagTexts.contains { $0 == "Complete Work" }

        let relationships = try li.select("ul.tags li.relationships a.tag").array().map { try $0.text() }
        let characters = try li.select("ul.tags li.characters a.tag").array().map { try $0.text() }
        let freeforms = try li.select("ul.tags li.freeforms a.tag").array().map { try $0.text() }

        let summaryHTML = try li.select("blockquote.summary").first()?.text() ?? ""

        let language = try li.select("dd.language").first()?.text() ?? "English"

        let wordsText = try li.select("dd.words").first()?.text() ?? "0"
        let wordCount = Int(wordsText.replacingOccurrences(of: ",", with: "")) ?? 0

        let kudosText = try li.select("dd.kudos").first()?.text() ?? "0"
        let kudos = Int(kudosText.replacingOccurrences(of: ",", with: "")) ?? 0

        let hitsText = try li.select("dd.hits").first()?.text() ?? "0"
        let hits = Int(hitsText.replacingOccurrences(of: ",", with: "")) ?? 0

        let chaptersText = try li.select("dd.chapters").first()?.text() ?? "1/1"
        let (chapterCount, totalChapters) = parseChapterFraction(chaptersText)

        let dateText = try li.select("p.datetime").first()?.text() ?? ""
        let updatedAt = parseAO3Date(dateText)

        return AO3WorkSummary(
            id: id,
            title: title,
            author: author,
            authorUsername: authorUsername,
            summary: summaryHTML,
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
    }

    /// The AO3 login from an author byline href like
    /// `/users/HoweverSheWrites/pseuds/HoweverSheWrites` → `HoweverSheWrites`.
    /// Returns "" for anonymous works (no/empty href).
    static func authorLogin(fromHref href: String) -> String {
        guard let r = href.range(of: "/users/") else { return "" }
        let seg = href[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        return seg.removingPercentEncoding ?? seg
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM yyyy"
        return formatter.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    private static func isRating(_ s: String) -> Bool {
        ["General Audiences", "Teen And Up Audiences", "Mature", "Explicit", "Not Rated"].contains(s)
    }

    private static func isWarning(_ s: String) -> Bool {
        [
            "No Archive Warnings Apply",
            "Creator Chose Not To Use Archive Warnings",
            "Graphic Depictions Of Violence",
            "Major Character Death",
            "Rape/Non-Con",
            "Underage",
        ].contains(s)
    }

    private static func isCategory(_ s: String) -> Bool {
        ["F/F", "F/M", "Gen", "M/M", "Multi", "Other"].contains(s)
    }
}
