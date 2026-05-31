import XCTest
@testable import Fanficly

final class SearchResultsParserTests: XCTestCase {

    private let html = """
    <html><body>
    <ol class="work index group">
      <li id="work_12345" class="work blurb group" role="article">
        <div class="header module">
          <h4 class="heading">
            <a href="/works/12345">A Coffee Shop Tale</a>
            by
            <a rel="author" href="/users/alice/pseuds/alice">alice</a>
          </h4>
          <h5 class="fandoms heading">
            <span class="landmark">Fandoms:</span>
            <a class="tag" href="/tags/Twilight/works">Twilight</a>
          </h5>
          <ul class="required-tags">
            <li><a class="help symbol question modal"><span class="text">Mature</span><span class="rating-mature rating"></span></a></li>
            <li><a class="help symbol question modal"><span class="text">No Archive Warnings Apply</span><span class="warning-yes warnings"></span></a></li>
            <li><a class="help symbol question modal"><span class="text">M/M</span><span class="category-slash category"></span></a></li>
            <li><a class="help symbol question modal"><span class="text">Complete Work</span><span class="complete-yes iswip"></span></a></li>
          </ul>
          <p class="datetime">12 Mar 2024</p>
        </div>
        <h6 class="landmark heading">Tags</h6>
        <ul class="tags commas">
          <li class="warnings"><strong><a class="tag">No Archive Warnings Apply</a></strong></li>
          <li class="relationships"><a class="tag">Edward Cullen/Bella Swan</a></li>
          <li class="characters"><a class="tag">Edward Cullen</a></li>
          <li class="characters"><a class="tag">Bella Swan</a></li>
          <li class="freeforms"><a class="tag">All Human</a></li>
          <li class="freeforms"><a class="tag">Coffee Shop AU</a></li>
        </ul>
        <h6 class="landmark heading">Summary</h6>
        <blockquote class="userstuff summary"><p>Bella works at a coffee shop. Edward orders too many lattes.</p></blockquote>
        <dl class="stats">
          <dt class="language">Language:</dt><dd class="language">English</dd>
          <dt class="words">Words:</dt><dd class="words">45,234</dd>
          <dt class="chapters">Chapters:</dt><dd class="chapters">12/12</dd>
          <dt class="comments">Comments:</dt><dd class="comments">234</dd>
          <dt class="kudos">Kudos:</dt><dd class="kudos">1,234</dd>
          <dt class="hits">Hits:</dt><dd class="hits">23,456</dd>
        </dl>
      </li>
      <li id="work_67890" class="work blurb group" role="article">
        <div class="header module">
          <h4 class="heading">
            <a href="/works/67890">A WIP</a>
            by
            <a rel="author" href="/users/bob/pseuds/bob">bob</a>
          </h4>
          <ul class="required-tags">
            <li><a><span class="text">Explicit</span></a></li>
            <li><a><span class="text">Major Character Death</span></a></li>
            <li><a><span class="text">F/F</span></a></li>
          </ul>
          <p class="datetime">01 Jan 2025</p>
        </div>
        <dl class="stats">
          <dt class="words">Words:</dt><dd class="words">5,000</dd>
          <dt class="chapters">Chapters:</dt><dd class="chapters">3/?</dd>
          <dt class="kudos">Kudos:</dt><dd class="kudos">42</dd>
          <dt class="hits">Hits:</dt><dd class="hits">500</dd>
        </dl>
      </li>
    </ol>
    <ol class="pagination actions">
      <li class="current"><span>1</span></li>
      <li><a href="?page=2">2</a></li>
      <li><a href="?page=3">3</a></li>
      <li class="next"><a rel="next" href="?page=2">Next</a></li>
    </ol>
    </body></html>
    """

    func test_parsesTwoWorks() throws {
        let result = try SearchResultsParser.parse(html: html)
        XCTAssertEqual(result.works.count, 2)
    }

    func test_firstWorkExtractsMetadata() throws {
        let result = try SearchResultsParser.parse(html: html)
        let work = result.works[0]
        XCTAssertEqual(work.id, 12345)
        XCTAssertEqual(work.title, "A Coffee Shop Tale")
        XCTAssertEqual(work.author, "alice")
        XCTAssertEqual(work.rating, "Mature")
        XCTAssertEqual(work.fandoms, ["Twilight"])
        XCTAssertEqual(work.relationships, ["Edward Cullen/Bella Swan"])
        XCTAssertEqual(work.characters, ["Edward Cullen", "Bella Swan"])
        XCTAssertEqual(work.freeforms, ["All Human", "Coffee Shop AU"])
        XCTAssertEqual(work.warnings, ["No Archive Warnings Apply"])
        XCTAssertEqual(work.categories, ["M/M"])
        XCTAssertTrue(work.isComplete)
        XCTAssertEqual(work.wordCount, 45234)
        XCTAssertEqual(work.kudos, 1234)
        XCTAssertEqual(work.hits, 23456)
        XCTAssertEqual(work.chapterCount, 12)
        XCTAssertEqual(work.totalChapters, 12)
    }

    func test_secondWorkIsWIP() throws {
        let result = try SearchResultsParser.parse(html: html)
        let work = result.works[1]
        XCTAssertEqual(work.id, 67890)
        XCTAssertEqual(work.title, "A WIP")
        XCTAssertEqual(work.rating, "Explicit")
        XCTAssertEqual(work.warnings, ["Major Character Death"])
        XCTAssertEqual(work.categories, ["F/F"])
        XCTAssertFalse(work.isComplete)
        XCTAssertEqual(work.chapterCount, 3)
        XCTAssertNil(work.totalChapters)
    }

    func test_paginationCount() throws {
        let result = try SearchResultsParser.parse(html: html)
        XCTAssertEqual(result.currentPage, 1)
        XCTAssertEqual(result.totalPages, 3)
    }

    func test_emptyResultsDoNotCrash() throws {
        let empty = "<html><body><ol class=\"work index group\"></ol></body></html>"
        let result = try SearchResultsParser.parse(html: empty)
        XCTAssertTrue(result.works.isEmpty)
    }
}
