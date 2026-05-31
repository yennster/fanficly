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
}
