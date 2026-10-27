import Foundation
import SwiftSoup

public struct AO3WorkMetadata: Sendable, Equatable {
    public let id: Int
    public let chapterCount: Int
    public let totalChapters: Int?
    public let updatedAt: Date?
    /// The day the work was first posted (`dd.published`). The poller asks for
    /// it when it has no baseline to tell a new work from an updated one.
    public var publishedAt: Date? = nil
    /// "Part N of <series>" for each series the work is in (see `SeriesParser.parts`).
    public var series: [AO3SeriesPart] = []
}

enum WorkMetadataParser {
    static func parse(html: String, workId: Int) throws -> AO3WorkMetadata {
        let doc = try SwiftSoup.parse(html)
        try AO3PageCheck.rejectLoginPage(doc)
        // Fail closed: a Cloudflare challenge, AO3's "Retry later" page or an
        // error page has no chapter count, and reading it as "1/1" would reset
        // the poller's new-chapter baseline and send a false alert on the next
        // real check.
        guard let stats = try doc.select("dl.stats").first(),
              let chaptersText = try stats.select("dd.chapters").first()?.text() else {
            throw AO3Error.parseFailed(reason: "No chapter count on the work page")
        }
        guard let chapters = parseChapterFraction(chaptersText) else {
            throw AO3Error.parseFailed(reason: "Unreadable chapter count on the work page")
        }

        let statusText = try stats.select("dd.status").first()?.text() ?? ""
        let updatedAt = parseAO3Date(statusText)
        let publishedAt = parseAO3Date(try stats.select("dd.published").first()?.text() ?? "")

        return AO3WorkMetadata(
            id: workId,
            chapterCount: chapters.current,
            totalChapters: chapters.total,
            updatedAt: updatedAt,
            publishedAt: publishedAt,
            series: SeriesParser.parts(in: doc)
        )
    }

    /// Nil when the posted count isn't a number, so drift can't read as 1.
    private static func parseChapterFraction(_ s: String) -> (current: Int, total: Int?)? {
        let parts = s.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let current = parts.first.flatMap({ Int($0) }) else { return nil }
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

/// Series markup, from AO3's own views (otwarchive `series/show.html.erb` and
/// `SeriesHelper#series_data_for_work`).
enum SeriesParser {
    /// A work's series from its meta block. Each series is one
    /// `<span class="series">`: an optional `a.previous`, then
    /// `<span class="position">Part 2 of <a href="/series/9">Title</a></span>`,
    /// then an optional `a.next`. A work in two series has two spans.
    static func parts(in doc: Document) -> [AO3SeriesPart] {
        guard let spans = try? doc.select("dl.work.meta dd.series span.series, dd.series span.series") else { return [] }
        var seen = Set<Int>()
        var parts: [AO3SeriesPart] = []
        for span in spans.array() {
            guard let link = try? span.select("span.position a[href*=/series/]").first(),
                  let seriesId = seriesId(fromHref: (try? link.attr("href")) ?? ""),
                  seen.insert(seriesId).inserted else { continue }
            let positionText = (try? span.select("span.position").first()?.text()) ?? ""
            let position = positionText.range(of: #"\d+"#, options: .regularExpression)
                .flatMap { Int(positionText[$0]) } ?? 1
            let previous = (try? span.select("a.previous").first()?.attr("href")).flatMap(SearchResultsParser.workId(fromHref:))
            let next = (try? span.select("a.next").first()?.attr("href")).flatMap(SearchResultsParser.workId(fromHref:))
            parts.append(AO3SeriesPart(
                seriesId: seriesId,
                title: ((try? link.text()) ?? "").trimmingCharacters(in: .whitespaces),
                position: position,
                previousWorkId: previous,
                nextWorkId: next
            ))
        }
        return parts
    }

    /// A series page: `h2.heading` title, a `dl.series.meta` of dt/dd pairs
    /// (Creator(s), Description, Stats with Works and Complete), then the works
    /// as ordinary blurbs in `ul.series.work.index`, paginated like search.
    static func parse(html: String, seriesId: Int) throws -> AO3Series {
        let doc = try SwiftSoup.parse(html)
        try AO3PageCheck.rejectLoginPage(doc)
        // An error page or markup drift must not read as an empty series.
        if try doc.select("dl.series.meta").isEmpty(), !AO3PageCheck.mainHasClass(doc, ["series-show"]) {
            throw AO3Error.parseFailed(reason: "Not a series page")
        }
        let titleEl = try doc.select("#main h2.heading").first() ?? doc.select("h2.heading").first()
        let title = try titleEl?.text().trimmingCharacters(in: .whitespaces) ?? ""

        var creator = ""
        var creatorUsername = ""
        var descriptionHTML = ""
        var isComplete = false
        if let meta = try doc.select("dl.series.meta").first() {
            for dt in try meta.select("dt").array() {
                guard let dd = try dt.nextElementSibling(), dd.tagName() == "dd" else { continue }
                let label = try dt.text().trimmingCharacters(in: .whitespaces).lowercased()
                switch label {
                case "creator:", "creators:":
                    let anchors = try dd.select("a[rel=author]").array()
                    if anchors.isEmpty {
                        creator = try dd.text().trimmingCharacters(in: .whitespaces)
                    } else {
                        creator = try anchors.map { try $0.text() }.joined(separator: ", ")
                        creatorUsername = SearchResultsParser.authorLogin(fromHref: try anchors[0].attr("href"))
                    }
                case "description:":
                    descriptionHTML = try dd.select("blockquote.userstuff").first()?.html() ?? ""
                case "complete:":
                    isComplete = try dd.text().trimmingCharacters(in: .whitespaces).lowercased() == "yes"
                default:
                    break
                }
            }
        }
        let workCount = try doc.select("dl.series.meta dd.works").first()
            .flatMap { Int(try $0.text().filter(\.isNumber)) }

        // Unrevealed works render a "Mystery Work" blurb with no title link;
        // there's nothing to open, so they're dropped. The rest keep AO3's order.
        let selector = "ul.series li.work.blurb"
        // The blurb parser fails closed on a page with no blurbs; a series page
        // was already checked above, so no blurbs here is an empty series.
        let listing = try doc.select(selector).isEmpty()
            ? AO3SearchResults(works: [], totalPages: 1, currentPage: 1)
            : SearchResultsParser.parse(html: html, blurbSelector: selector)
        let linked = Set(try doc.select(selector).array().compactMap { li -> Int? in
            guard let href = try li.select("h4.heading a[href*=/works/]").first()?.attr("href") else { return nil }
            return SearchResultsParser.workId(fromHref: href)
        })

        return AO3Series(
            id: seriesId,
            title: title,
            creator: creator,
            creatorUsername: creatorUsername,
            descriptionHTML: descriptionHTML,
            workCount: workCount,
            isComplete: isComplete,
            works: listing.works.filter { linked.contains($0.id) },
            currentPage: listing.currentPage,
            totalPages: listing.totalPages
        )
    }

    /// `9` from `/series/9` (or a full `https://…/series/9` URL).
    static func seriesId(fromHref href: String) -> Int? {
        guard let r = href.range(of: "/series/") else { return nil }
        let seg = href[r.upperBound...].split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        return Int(seg)
    }
}
