import XCTest
@testable import Fanficly

final class WorkMetadataParserTests: XCTestCase {
    func test_parsesChapterCountAndStatus() throws {
        let html = """
        <html><body>
        <dl class="stats">
          <dt class="chapters">Chapters:</dt><dd class="chapters">12/20</dd>
          <dt class="status">Updated:</dt><dd class="status">2024-03-12</dd>
        </dl>
        </body></html>
        """
        let meta = try WorkMetadataParser.parse(html: html, workId: 5)
        XCTAssertEqual(meta.id, 5)
        XCTAssertEqual(meta.chapterCount, 12)
        XCTAssertEqual(meta.totalChapters, 20)
        XCTAssertNotNil(meta.updatedAt)
    }

    func test_wipWithUnknownTotal() throws {
        let html = """
        <html><body><dl class="stats">
          <dt class="chapters">Chapters:</dt><dd class="chapters">3/?</dd>
        </dl></body></html>
        """
        let meta = try WorkMetadataParser.parse(html: html, workId: 1)
        XCTAssertEqual(meta.chapterCount, 3)
        XCTAssertNil(meta.totalChapters)
    }

    func test_missingStatsDefaults() throws {
        let meta = try WorkMetadataParser.parse(html: "<html></html>", workId: 2)
        XCTAssertEqual(meta.chapterCount, 1)
    }

    // MARK: - Series (markup from otwarchive's series/show.html.erb,
    // works/_work_blurb.html.erb and SeriesHelper#series_data_for_work)

    private func blurb(id: Int, title: String) -> String {
        """
        <li id="work_\(id)" class="work blurb group work-\(id) user-1" role="article">
          <div class="header module">
            <h4 class="heading">
              <a href="/works/\(id)">\(title)</a>
              by
              <a rel="author" href="/users/quillwright/pseuds/quillwright">quillwright</a>
            </h4>
            <h5 class="fandoms heading"><a class="tag" href="/tags/Original%20Work/works">Original Work</a></h5>
            <ul class="required-tags">
              <li><span class="rating-general-audience rating"><span class="text">General Audiences</span></span></li>
              <li><span class="complete-yes iswip"><span class="text">Complete Work</span></span></li>
            </ul>
            <p class="datetime">12 Mar 2024</p>
          </div>
          <dl class="stats">
            <dt class="words">Words:</dt><dd class="words">1,200</dd>
            <dt class="chapters">Chapters:</dt><dd class="chapters">1/1</dd>
          </dl>
        </li>
        """
    }

    private func seriesPage(works: [String], complete: Bool = false, pagination: String = "") -> String {
        """
        <html><body><div id="main" class="series-show region">
        <h2 class="heading">
          The Lighthouse Letters
        </h2>
        <h3 class="landmark heading">Series Metadata</h3>
        <div class="wrapper">
          <dl class="series meta group">
            <dt>Creator:</dt>
            <dd><a rel="author" href="/users/quillwright/pseuds/quill">quill (quillwright)</a></dd>
            <dt>Series Begun:</dt><dd>2023-01-02</dd>
            <dt>Series Updated:</dt><dd>2024-03-12</dd>
            <dt>Description:</dt>
            <dd><blockquote class="userstuff"><p>Letters from the coast.</p></blockquote></dd>
            <dt class="stats">Stats:</dt>
            <dd class="stats">
              <dl class="stats">
                <dt class="words">Words:</dt><dd class="words">3,600</dd>
                <dt class="works">Works:</dt><dd class="works">\(works.count)</dd>
                <dt>Complete:</dt><dd>\(complete ? "Yes" : "No")</dd>
              </dl>
            </dd>
          </dl>
        </div>
        <h3 class="landmark heading">Listing Series</h3>
        \(pagination)
        <ul class="series work index group">
        \(works.joined(separator: "\n"))
        </ul>
        </div></body></html>
        """
    }

    func test_seriesPage_singleWork() throws {
        let series = try SeriesParser.parse(html: seriesPage(works: [blurb(id: 11, title: "First Letter")],
                                                             complete: true), seriesId: 9)
        XCTAssertEqual(series.id, 9)
        XCTAssertEqual(series.title, "The Lighthouse Letters")
        XCTAssertEqual(series.creator, "quill (quillwright)")
        XCTAssertEqual(series.creatorUsername, "quillwright")
        XCTAssertTrue(series.descriptionHTML.contains("Letters from the coast."))
        XCTAssertEqual(series.workCount, 1)
        XCTAssertTrue(series.isComplete)
        XCTAssertEqual(series.works.map(\.id), [11])
        XCTAssertEqual(series.works.first?.title, "First Letter")
        XCTAssertEqual(series.currentPage, 1)
        XCTAssertEqual(series.totalPages, 1)
    }

    func test_seriesPage_severalWorksKeepSeriesOrder() throws {
        let html = seriesPage(works: [
            blurb(id: 30, title: "Part One"),
            blurb(id: 10, title: "Part Two"),
            blurb(id: 20, title: "Part Three"),
        ], pagination: """
        <ol class="pagination actions" role="navigation">
          <li class="previous"><span class="disabled">← Previous</span></li>
          <li><span class="current">1</span></li>
          <li><a rel="next" href="/series/9?page=2">2</a></li>
          <li class="next"><a rel="next" href="/series/9?page=2">Next →</a></li>
        </ol>
        """)
        let series = try SeriesParser.parse(html: html, seriesId: 9)
        XCTAssertEqual(series.works.map(\.id), [30, 10, 20])
        XCTAssertEqual(series.works.map(\.title), ["Part One", "Part Two", "Part Three"])
        XCTAssertFalse(series.isComplete)
        XCTAssertEqual(series.currentPage, 1)
        XCTAssertEqual(series.totalPages, 2)
    }

    /// An unrevealed work in a series shows AO3's "Mystery Work" blurb, with
    /// no link to open; it's dropped and the rest keep their order.
    func test_seriesPage_skipsEntryWithNoWorkLink() throws {
        let mystery = """
        <li id="work_15" class="mystery work blurb group work-15" role="article">
          <div class="mystery header picture module">
            <h4 class="heading">Mystery Work</h4>
            <h5 class="heading">Part of <a href="/collections/exchange">Exchange</a></h5>
            <div class="icon"></div>
          </div>
          <h6 class="landmark heading">Summary</h6>
          <blockquote class="userstuff summary">
            <p>This is part of an ongoing challenge and will be revealed soon!</p>
          </blockquote>
        </li>
        """
        let html = seriesPage(works: [blurb(id: 11, title: "One"), mystery, blurb(id: 12, title: "Three")])
        let series = try SeriesParser.parse(html: html, seriesId: 9)
        XCTAssertEqual(series.works.map(\.id), [11, 12])
    }

    func test_seriesPage_coCreatorsAndNoDescription() throws {
        let html = """
        <html><body>
        <h2 class="heading">Shared Shore</h2>
        <dl class="series meta group">
          <dt>Creators:</dt>
          <dd><a rel="author" href="/users/ana/pseuds/ana">ana</a>, <a rel="author" href="/users/bo/pseuds/bo">bo</a></dd>
          <dt class="stats">Stats:</dt>
          <dd class="stats"><dl class="stats"><dt class="works">Works:</dt><dd class="works">0</dd></dl></dd>
        </dl>
        <ul class="series work index group"></ul>
        </body></html>
        """
        let series = try SeriesParser.parse(html: html, seriesId: 4)
        XCTAssertEqual(series.creator, "ana, bo")
        XCTAssertEqual(series.creatorUsername, "ana")
        XCTAssertEqual(series.descriptionHTML, "")
        XCTAssertTrue(series.works.isEmpty)
    }

    /// An error page or the login page must not read as an empty series.
    func test_seriesPage_failsClosed() {
        XCTAssertThrowsError(try SeriesParser.parse(
            html: #"<html><body><div id="main" class="errors-404"><h2 class="heading">Error 404</h2></div></body></html>"#,
            seriesId: 9)) { error in
            guard case AO3Error.parseFailed = error else { return XCTFail("expected parseFailed, got \(error)") }
        }
        XCTAssertThrowsError(try SeriesParser.parse(
            html: #"<html><body><div id="main" class="sessions-new"><form action="/users/login"></form></div></body></html>"#,
            seriesId: 9)) { error in
            guard case AO3Error.unauthorized = error else { return XCTFail("expected unauthorized, got \(error)") }
        }
    }

    private func workMeta(series: String) -> String {
        """
        <html><body>
        <dl class="work meta group">
          <dt class="rating tags">Rating:</dt>
          <dd class="rating tags"><ul class="commas"><li><a class="tag" href="/tags/General%20Audiences/works">General Audiences</a></li></ul></dd>
          \(series)
          <dt class="stats">Stats:</dt>
          <dd class="stats"><dl class="stats">
            <dt class="chapters">Chapters:</dt><dd class="chapters">1/1</dd>
          </dl></dd>
        </dl>
        <div id="workskin"><div class="preface group"><h2 class="title heading">Two</h2></div>
          <div id="chapters"><div class="userstuff"><p>Text.</p></div></div>
        </div>
        </body></html>
        """
    }

    func test_workPage_partOfOneSeries_withNeighbours() throws {
        let html = workMeta(series: """
        <dt class="series">Series:</dt>
        <dd class="series">
          <span class="series"><a class="previous" href="/works/11">← Previous Work</a><span class="divider"> </span><span class="position">Part 2 of <a href="/series/9">The Lighthouse Letters</a></span><span class="divider"> </span><a class="next" href="/works/13">Next Work →</a></span>
        </dd>
        """)
        let meta = try WorkMetadataParser.parse(html: html, workId: 12)
        XCTAssertEqual(meta.series, [AO3SeriesPart(seriesId: 9, title: "The Lighthouse Letters", position: 2,
                                                   previousWorkId: 11, nextWorkId: 13)])
        let payload = try WorkPageParser.parse(html: html, workId: 12)
        XCTAssertEqual(payload.summary.series, meta.series)
    }

    func test_workPage_inTwoSeries_lastPartHasNoNext() throws {
        let html = workMeta(series: """
        <dt class="series">Series:</dt>
        <dd class="series">
          <span class="series"><span class="position">Part 1 of <a href="/series/9">The Lighthouse Letters</a></span><span class="divider"> </span><a class="next" href="/works/13">Next Work →</a></span>
          <span class="series"><a class="previous" href="/works/40">← Previous Work</a><span class="divider"> </span><span class="position">Part 5 of <a href="/series/77">Coastal Year</a></span></span>
        </dd>
        """)
        let parts = try WorkMetadataParser.parse(html: html, workId: 12).series
        XCTAssertEqual(parts.map(\.seriesId), [9, 77])
        XCTAssertEqual(parts.map(\.position), [1, 5])
        XCTAssertNil(parts[0].previousWorkId)
        XCTAssertEqual(parts[0].nextWorkId, 13)
        XCTAssertEqual(parts[1].previousWorkId, 40)
        XCTAssertNil(parts[1].nextWorkId)
        XCTAssertEqual(parts[1].title, "Coastal Year")
    }

    /// The end-of-work "Series this work belongs to" module repeats the same
    /// spans outside the meta block; each series is still listed once.
    func test_workPage_seriesModuleDoesNotDuplicate() throws {
        let span = #"<span class="series"><span class="position">Part 1 of <a href="/series/9">The Lighthouse Letters</a></span></span>"#
        let html = workMeta(series: """
        <dt class="series">Series:</dt><dd class="series">\(span)</dd>
        """).replacingOccurrences(of: "</body>", with: """
        <div id="series" class="series module"><h3 class="heading">Series this work belongs to:</h3>
        <ul><li>\(span)</li></ul></div></body>
        """)
        XCTAssertEqual(try WorkMetadataParser.parse(html: html, workId: 12).series.count, 1)
    }

    func test_workPage_noSeries() throws {
        let html = workMeta(series: "")
        XCTAssertTrue(try WorkMetadataParser.parse(html: html, workId: 12).series.isEmpty)
        XCTAssertTrue(try WorkPageParser.parse(html: html, workId: 12).summary.series.isEmpty)
    }

    func test_seriesId_fromHref() {
        XCTAssertEqual(SeriesParser.seriesId(fromHref: "/series/9"), 9)
        XCTAssertEqual(SeriesParser.seriesId(fromHref: "https://archiveofourown.org/series/123?page=2"), 123)
        XCTAssertNil(SeriesParser.seriesId(fromHref: "/works/9"))
    }
}
