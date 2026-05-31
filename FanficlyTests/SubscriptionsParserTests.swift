import XCTest
@testable import Fanficly

final class SubscriptionsParserTests: XCTestCase {
    func test_parsesWorkSubscriptions() throws {
        let html = """
        <html><body>
        <dl class="subscription index group">
          <dt>
            <a href="/works/12345">A Coffee Shop Tale</a>
            by
            <a rel="author" href="/users/alice/pseuds/alice">alice</a>
          </dt>
          <dd><a class="delete">Unsubscribe</a></dd>
          <dt>
            <a href="/works/67890">Another Story</a>
            by
            <a rel="author" href="/users/bob">bob</a>
          </dt>
          <dd><a class="delete">Unsubscribe</a></dd>
        </dl>
        </body></html>
        """
        let subs = try SubscriptionsParser.parse(html: html)
        XCTAssertEqual(subs.count, 2)
        XCTAssertEqual(subs[0].kind, .work)
        XCTAssertEqual(subs[0].resourceId, "12345")
        XCTAssertEqual(subs[0].title, "A Coffee Shop Tale")
        XCTAssertEqual(subs[0].author, "alice")
        XCTAssertEqual(subs[1].kind, .work)
        XCTAssertEqual(subs[1].resourceId, "67890")
    }

    func test_parsesSeriesSubscriptions() throws {
        let html = """
        <html><body>
        <dl class="subscription index group">
          <dt>
            <a href="/series/100">A Long Saga</a>
            by
            <a rel="author" href="/users/carol">carol</a>
          </dt>
        </dl>
        </body></html>
        """
        let subs = try SubscriptionsParser.parse(html: html)
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].kind, .series)
        XCTAssertEqual(subs[0].resourceId, "100")
        XCTAssertEqual(subs[0].author, "carol")
    }

    func test_parsesUserSubscriptions() throws {
        let html = """
        <html><body>
        <dl class="subscription index group">
          <dt>
            <a href="/users/dave">dave</a>
          </dt>
        </dl>
        </body></html>
        """
        let subs = try SubscriptionsParser.parse(html: html)
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].kind, .user)
        XCTAssertEqual(subs[0].resourceId, "dave")
        XCTAssertNil(subs[0].author)
    }

    func test_dedupes() throws {
        let html = """
        <html><body>
        <dl class="subscription">
          <dt><a href="/works/1">Same</a></dt>
          <dt><a href="/works/1">Same</a></dt>
        </dl>
        </body></html>
        """
        XCTAssertEqual(try SubscriptionsParser.parse(html: html).count, 1)
    }

    func test_emptyHTMLIsEmpty() throws {
        XCTAssertTrue(try SubscriptionsParser.parse(html: "<html></html>").isEmpty)
    }
}
