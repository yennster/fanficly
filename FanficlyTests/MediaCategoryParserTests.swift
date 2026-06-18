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
}
