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

    // A page with neither a subscriptions list nor the index shell must fail
    // closed — reading it as "zero subscriptions" would make the poller
    // delete every real record.
    func test_pageWithoutSubscriptionMarkersThrows() {
        XCTAssertThrowsError(try SubscriptionsParser.parse(html: "<html></html>")) { error in
            guard case AO3Error.parseFailed = error else {
                return XCTFail("Expected parseFailed, got \(error)")
            }
        }
    }

    // With an expired session cookie AO3 302s /users/<name>/subscriptions to
    // the login page and URLSession follows it, so the parser receives login
    // HTML with a 200. It must throw — and in particular must not scrape the
    // page's /users/login link into a phantom "user:login" subscription.
    func test_loginPageThrowsUnauthorized() {
        let html = """
        <html><body class="logged-out">
        <div id="main" class="sessions-new">
          <h2 class="heading">Log In</h2>
          <form class="new_user" id="new_user" action="/users/login" method="post">
            <input name="authenticity_token" type="hidden" value="abc123">
            <label for="user_login">User name or email:</label>
            <input id="user_login" name="user[login]" type="text">
            <input id="user_password" name="user[password]" type="password">
            <input name="commit" type="submit" value="Log In">
          </form>
          <a href="/users/login">Log in</a>
          <a href="/users/password/new">Forgot password?</a>
        </div>
        </body></html>
        """
        XCTAssertThrowsError(try SubscriptionsParser.parse(html: html)) { error in
            XCTAssertEqual(error as? AO3Error, .unauthorized)
        }
    }

    // A user with zero subscriptions still gets the index shell — that must
    // parse as an empty list, not an error.
    func test_emptySubscriptionsIndexIsEmpty() throws {
        let html = """
        <html><body>
        <div id="main" class="subscriptions-index dashboard region">
          <h2 class="heading">My Subscriptions</h2>
          <p>You don't have any subscriptions yet.</p>
        </div>
        </body></html>
        """
        XCTAssertTrue(try SubscriptionsParser.parse(html: html).isEmpty)
    }

    func test_parsePage_readsPagination() throws {
        let html = """
        <html><body>
        <dl class="subscription index group">
          <dt><a href="/works/1">First</a></dt>
        </dl>
        <ol class="pagination actions">
          <li class="previous"><span class="disabled">← Previous</span></li>
          <li><span class="current">2</span></li>
          <li><a href="/users/x/subscriptions?page=3">3</a></li>
          <li class="next"><a href="/users/x/subscriptions?page=3">Next →</a></li>
        </ol>
        </body></html>
        """
        let page = try SubscriptionsParser.parsePage(html: html)
        XCTAssertEqual(page.subscriptions.count, 1)
        XCTAssertEqual(page.currentPage, 2)
        XCTAssertEqual(page.totalPages, 3)
    }

    func test_parsePage_defaultsToSinglePage() throws {
        let html = """
        <html><body>
        <dl class="subscription index group">
          <dt><a href="/works/1">Only</a></dt>
        </dl>
        </body></html>
        """
        let page = try SubscriptionsParser.parsePage(html: html)
        XCTAssertEqual(page.currentPage, 1)
        XCTAssertEqual(page.totalPages, 1)
    }
}
