import XCTest
@testable import Fanficly

final class MediaCategoryParserTests: XCTestCase {
    func test_parsesFandomLinks() throws {
        let html = """
        <html><body>
        <ol class="index group">
          <li><a class="tag" href="/tags/Marvel/works">Marvel</a> (12345)</li>
          <li><a class="tag" href="/tags/Star%20Wars%20-%20All%20Media%20Types/works">Star Wars - All Media Types</a> (9876)</li>
          <li><a class="tag" href="/tags/Twilight%20Series%20-%20Stephenie%20Meyer/works">Twilight Series - Stephenie Meyer</a> (1234)</li>
        </ol>
        </body></html>
        """
        let fandoms = try MediaCategoryParser.parse(html: html)
        XCTAssertEqual(fandoms.count, 3)
        let names = fandoms.map(\.canonicalName)
        XCTAssertTrue(names.contains("Marvel"))
        XCTAssertTrue(names.contains("Star Wars - All Media Types"))
        XCTAssertTrue(names.contains("Twilight Series - Stephenie Meyer"))
    }

    func test_ignoresNonWorksLinks() throws {
        let html = """
        <html><body>
        <a href="/tags/Marvel">Filter</a>
        <a href="/tags/Marvel/works">Marvel</a>
        <a href="/tags/Marvel/bookmarks">Bookmarks</a>
        </body></html>
        """
        let fandoms = try MediaCategoryParser.parse(html: html)
        XCTAssertEqual(fandoms.count, 1)
        XCTAssertEqual(fandoms.first?.canonicalName, "Marvel")
    }

    func test_dedupes() throws {
        let html = """
        <html><body>
        <a href="/tags/Marvel/works">Marvel</a>
        <a href="/tags/Marvel/works">Marvel</a>
        </body></html>
        """
        XCTAssertEqual(try MediaCategoryParser.parse(html: html).count, 1)
    }

    func test_sortsAlphabetically() throws {
        let html = """
        <html><body>
        <a href="/tags/Zelda/works">Zelda</a>
        <a href="/tags/Avengers/works">Avengers</a>
        <a href="/tags/Marvel/works">Marvel</a>
        </body></html>
        """
        let names = try MediaCategoryParser.parse(html: html).map(\.canonicalName)
        XCTAssertEqual(names, ["Avengers", "Marvel", "Zelda"])
    }

    func test_parsesWorkCounts() throws {
        let html = """
        <html><body>
        <ol class="index group">
          <li><a class="tag" href="/tags/Marvel/works">Marvel</a> (12,345)</li>
          <li><a class="tag" href="/tags/Twilight/works">Twilight</a></li>
        </ol>
        </body></html>
        """
        let fandoms = try MediaCategoryParser.parse(html: html)
        let marvel = fandoms.first { $0.canonicalName == "Marvel" }
        let twilight = fandoms.first { $0.canonicalName == "Twilight" }
        XCTAssertEqual(marvel?.workCount, 12345, "comma-separated count is parsed")
        XCTAssertNil(twilight?.workCount, "no parens → nil count")
    }

    func test_trailingCount() {
        XCTAssertEqual(MediaCategoryParser.trailingCount(in: "Harry Potter (123,456)"), 123456)
        XCTAssertEqual(MediaCategoryParser.trailingCount(in: "Foo (Bar) (42)"), 42)
        XCTAssertNil(MediaCategoryParser.trailingCount(in: "No count here"))
    }
}

final class WorkFiltersParserTests: XCTestCase {
    private let html = """
    <html><body>
    <form id="work-filters">
      <fieldset>
        <legend>Relationships</legend>
        <ul class="tags index group">
          <li><label for="include_relationship_ids_1"><input id="include_relationship_ids_1" name="include_relationship_ids[]" type="checkbox" value="1"> Hermione Granger/Draco Malfoy <span class="count">(8,500)</span></label></li>
          <li><label for="include_relationship_ids_2"><input id="include_relationship_ids_2" name="include_relationship_ids[]" type="checkbox" value="2"> Harry Potter/Draco Malfoy <span class="count">(12,000)</span></label></li>
        </ul>
      </fieldset>
      <fieldset>
        <legend>Characters</legend>
        <ul class="tags index group">
          <li><label for="include_character_ids_9"><input id="include_character_ids_9" name="include_character_ids[]" type="checkbox" value="9"> Draco Malfoy <span class="count">(20,000)</span></label></li>
        </ul>
      </fieldset>
    </form>
    </body></html>
    """

    func test_parsesRelationshipFacetsWithCounts() throws {
        let filters = try WorkFiltersParser.parse(html: html)
        XCTAssertEqual(filters.relationships.count, 2)
        let drarry = filters.relationships.first { $0.name == "Harry Potter/Draco Malfoy" }
        XCTAssertEqual(drarry?.count, 12000)
        XCTAssertEqual(filters.relationships.first { $0.name == "Hermione Granger/Draco Malfoy" }?.count, 8500)
    }

    func test_parsesCharacterFacets() throws {
        let filters = try WorkFiltersParser.parse(html: html)
        XCTAssertEqual(filters.characters.map(\.name), ["Draco Malfoy"])
        XCTAssertEqual(filters.characters.first?.count, 20000)
        XCTAssertTrue(filters.fandoms.isEmpty)
    }

    // Copied from the live filter sidebar on
    // https://archiveofourown.org/tags/Sherlock%20(TV)/works (July 2026):
    // ids are `include_work_search_<kind>_ids_<tag id>` and the name + count
    // share one plain span (no `span.count`). The exclude half repeats every
    // tag under `exclude_work_search_…` ids and must not be double-counted.
    private let liveHTML = """
    <html><body>
    <form id="work-filters">
      <dt id="toggle_include_fandom_tags" class="filter-toggle fandom tags">
        <span class="landmark">Include </span>Fandoms
      </dt>
      <dd id="include_fandom_tags" class="expandable fandom tags">
        <ul>
            <li>
              <label for="include_work_search_fandom_ids_150320251">
                  <input type="checkbox" name="include_work_search[fandom_ids][]" id="include_work_search_fandom_ids_150320251" value="150320251" />
                <span class="indicator" aria-hidden="true"></span><span>Sherlock (BBC TV 2010) (119208)</span>
    </label>                    </li>
        </ul>
      </dd>
      <dt id="toggle_include_relationship_tags" class="filter-toggle relationship tags">
        <span class="landmark">Include </span>Relationships
      </dt>
      <dd id="include_relationship_tags" class="expandable relationship tags">
        <ul>
            <li>
              <label for="include_work_search_relationship_ids_11006">
                  <input type="checkbox" name="include_work_search[relationship_ids][]" id="include_work_search_relationship_ids_11006" value="11006" />
                <span class="indicator" aria-hidden="true"></span><span>Sherlock Holmes/John Watson (57746)</span>
    </label>                    </li>
            <li>
              <label for="include_work_search_relationship_ids_142528">
                  <input type="checkbox" name="include_work_search[relationship_ids][]" id="include_work_search_relationship_ids_142528" value="142528" />
                <span class="indicator" aria-hidden="true"></span><span>Mycroft Holmes/Greg Lestrade (12345)</span>
    </label>                    </li>
        </ul>
      </dd>
      <dt id="toggle_include_character_tags" class="filter-toggle character tags">
        <span class="landmark">Include </span>Characters
      </dt>
      <dd id="include_character_tags" class="expandable character tags">
        <ul>
            <li>
              <label for="include_work_search_character_ids_4622">
                  <input type="checkbox" name="include_work_search[character_ids][]" id="include_work_search_character_ids_4622" value="4622" />
                <span class="indicator" aria-hidden="true"></span><span>Sherlock Holmes (93301)</span>
    </label>                    </li>
        </ul>
      </dd>
      <dt id="toggle_include_freeform_tags" class="filter-toggle freeform tags">
        <span class="landmark">Include </span>Additional Tags
      </dt>
      <dd id="include_freeform_tags" class="expandable freeform tags">
        <ul>
            <li>
              <label for="include_work_search_freeform_ids_110">
                  <input type="checkbox" name="include_work_search[freeform_ids][]" id="include_work_search_freeform_ids_110" value="110" />
                <span class="indicator" aria-hidden="true"></span><span>Fluff (17354)</span>
    </label>                    </li>
        </ul>
      </dd>
      <dt id="toggle_exclude_relationship_tags" class="filter-toggle relationship tags">
        <span class="landmark">Exclude </span>Relationships
      </dt>
      <dd id="exclude_relationship_tags" class="expandable relationship tags">
        <ul>
            <li>
              <label for="exclude_work_search_relationship_ids_11006">
                  <input type="checkbox" name="exclude_work_search[relationship_ids][]" id="exclude_work_search_relationship_ids_11006" value="11006" />
                <span class="indicator" aria-hidden="true"></span><span>Sherlock Holmes/John Watson (57746)</span>
    </label>                    </li>
        </ul>
      </dd>
    </form>
    </body></html>
    """

    func test_parsesLiveWorkSearchMarkup() throws {
        let filters = try WorkFiltersParser.parse(html: liveHTML)
        XCTAssertEqual(filters.relationships.map(\.name),
                       ["Sherlock Holmes/John Watson", "Mycroft Holmes/Greg Lestrade"])
        XCTAssertEqual(filters.relationships.first?.count, 57746,
                       "count comes from the trailing (N) in the plain span, not span.count")
        XCTAssertEqual(filters.characters.map(\.name), ["Sherlock Holmes"])
        XCTAssertEqual(filters.characters.first?.count, 93301)
        XCTAssertEqual(filters.freeforms.map(\.name), ["Fluff"])
        XCTAssertEqual(filters.freeforms.first?.count, 17354)
    }

    func test_liveMarkup_keepsParenthesesInsideTagNames() throws {
        let filters = try WorkFiltersParser.parse(html: liveHTML)
        XCTAssertEqual(filters.fandoms.map(\.name), ["Sherlock (BBC TV 2010)"],
                       "only the trailing count parens are stripped")
        XCTAssertEqual(filters.fandoms.first?.count, 119208)
    }

    func test_liveMarkup_ignoresExcludeSection() throws {
        let filters = try WorkFiltersParser.parse(html: liveHTML)
        XCTAssertEqual(filters.relationships.filter { $0.name == "Sherlock Holmes/John Watson" }.count, 1,
                       "the exclude half repeats every tag and must not double-count")
    }
}
