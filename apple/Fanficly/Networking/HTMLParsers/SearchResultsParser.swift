import Foundation
import SwiftSoup

enum SearchResultsParser {
    /// Parse a blurb listing. `blurbSelector` defaults to the works-listing
    /// markup used by search and author pages; the bookmarks page uses
    /// `li.bookmark.blurb` (same inner blurb, different container), so it passes
    /// that instead and reuses everything else.
    static func parse(html: String, blurbSelector: String = "li.work.blurb") throws -> AO3SearchResults {
        let doc = try SwiftSoup.parse(html)
        try AO3PageCheck.rejectLoginPage(doc)
        let blurbs = try doc.select(blurbSelector)
        // No blurbs only means "no results" on a real listing; a stray error
        // page or markup drift must not read as an empty search.
        if blurbs.isEmpty(), try !isListingPage(doc) {
            throw AO3Error.parseFailed(reason: "Not a works listing")
        }
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

        return AO3SearchResults(works: works, totalPages: totalPages, currentPage: currentPage,
                                totalFound: try totalFound(in: doc))
    }

    /// A works, bookmarks or readings listing, even an empty one: the index `<ol>` that
    /// author, tag and bookmark pages always render, the Rails controller-action
    /// class on `#main`, or the "No results found" line search shows instead of
    /// the list.
    private static func isListingPage(_ doc: Document) throws -> Bool {
        if try !doc.select("ol.work.index, ol.bookmark.index").isEmpty() { return true }
        if AO3PageCheck.mainHasClass(doc, ["works-search", "works-index", "works-collected",
                                           "bookmarks-search", "bookmarks-index", "readings-index"]) {
            return true
        }
        for p in try doc.select("#main p").array() {
            if try p.text().contains("No results found") { return true }
        }
        return false
    }

    /// AO3's readings page (`/users/<name>/readings`, which with
    /// `?show=to-read` is Marked for Later). Each entry is
    /// `li.reading.work.blurb` with id `work_<id>` around the usual work blurb;
    /// deleted works keep an entry with no id and no title link, so
    /// `parseBlurb` skips them. Fails closed: the page is login-only, so a
    /// login form means the session expired, and a page without the
    /// `readings-index` shell (AO3 sends readers with history turned off to
    /// their preferences) is never read as an empty list.
    static func parseReadings(html: String) throws -> AO3SearchResults {
        let doc = try SwiftSoup.parse(html)
        if SubscriptionsParser.looksLikeLoginPage(doc) {
            throw AO3Error.unauthorized
        }
        if try doc.select("div.readings-index").isEmpty() {
            if try !doc.select("div.preferences-index").isEmpty() {
                throw AO3Error.parseFailed(reason: "Your AO3 reading history is turned off. Check \"Turn on History\" in your AO3 preferences to see this list.")
            }
            throw AO3Error.parseFailed(reason: "AO3 sent a page that isn't your readings list. Try again, or check the list on the AO3 website.")
        }
        return try parse(html: html, blurbSelector: "li.reading.work.blurb")
    }

    /// The `<h3 class="heading">126,555 Found …</h3>` count on search pages.
    static func totalFound(in doc: Document) throws -> Int? {
        for heading in try doc.select("h3.heading").array() {
            let text = try heading.text()
            guard let range = text.range(of: #"^[\d,.]+(?=\s+Found)"#, options: .regularExpression) else { continue }
            return Int(text[range].filter(\.isNumber))
        }
        return nil
    }

    static func parseBlurb(_ li: Element) throws -> AO3WorkSummary? {
        let titleAnchor = try li.select("h4.heading a").first()

        // Work id: search/author pages tag the <li> as `work_<id>`; the
        // bookmarks page tags it `bookmark_<id>`, so fall back to the
        // `/works/<id>` title link. Bookmarks of series / external / deleted
        // works have no such link and are skipped (nil).
        let idAttr = try li.attr("id")
        let id: Int
        if let n = Int(idAttr.replacingOccurrences(of: "work_", with: "")) {
            id = n
        } else if let href = try titleAnchor?.attr("href"), let n = workId(fromHref: href) {
            id = n
        } else {
            return nil
        }

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

    /// The numeric work id from a title link href like `/works/12345` or
    /// `/works/12345/chapters/678`. Returns nil for non-work links (series,
    /// external URLs), so those bookmark blurbs are skipped.
    static func workId(fromHref href: String) -> Int? {
        guard let r = href.range(of: "/works/") else { return nil }
        let seg = href[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        return Int(seg)
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

/// Fail-closed checks shared by the parsers of pages a guest can open. They
/// can't reuse `SubscriptionsParser`'s "any login form" test: every page AO3
/// serves a logged-out reader carries the header's small login form.
enum AO3PageCheck {
    /// AO3's login page, where it redirects a stale session or a guest opening
    /// a restricted work (URLSession follows the redirect, so it arrives as a
    /// 200). Only the login page has a login form inside `#main`.
    static func isLoginPage(_ doc: Document) -> Bool {
        let hits = try? doc.select("div#main.sessions-new, #main #loginform, #main form[action*=/users/login]")
        return !(hits?.isEmpty() ?? true)
    }

    static func rejectLoginPage(_ doc: Document) throws {
        if isLoginPage(doc) { throw AO3Error.unauthorized }
    }

    /// `isLoginPage` for a body that isn't parsed yet (a download).
    static func isLoginPage(html: String) -> Bool {
        guard let doc = try? SwiftSoup.parse(html) else { return false }
        return isLoginPage(doc)
    }

    /// Whether an HTML download is the work itself: AO3's download template
    /// wraps the text in `div#chapters` with no site chrome around it. The
    /// login page and AO3 or Cloudflare error pages have no `div#chapters`;
    /// the work page, where AO3 redirects a download it won't serve
    /// (downloads off, a draft, a hidden work, a render failure), has one
    /// inside `div#main` and `#workskin`. Throws `unauthorized` for the login
    /// page.
    static func isWorkDownload(html: String) throws -> Bool {
        guard let doc = try? SwiftSoup.parse(html) else { return false }
        try rejectLoginPage(doc)
        let hasChapters = !((try? doc.select("div#chapters").isEmpty()) ?? true)
        let hasSiteChrome = !((try? doc.select("div#main, #workskin").isEmpty()) ?? true)
        return hasChapters && !hasSiteChrome
    }

    /// Whether `div#main` carries one of these classes (AO3 sets it to the
    /// Rails `controller-action`, e.g. `works-search`).
    static func mainHasClass(_ doc: Document, _ classes: [String]) -> Bool {
        guard let main = try? doc.select("div#main").first() else { return false }
        return classes.contains { main.hasClass($0) }
    }
}
