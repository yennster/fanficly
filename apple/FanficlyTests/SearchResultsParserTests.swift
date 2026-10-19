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
      <li class="previous"><a href="?page=1">Previous</a></li>
      <li><a href="?page=1">1</a></li>
      <li><span class="current">2</span></li>
      <li><a href="?page=3">3</a></li>
      <li class="next"><a rel="next" href="?page=3">Next</a></li>
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
        XCTAssertEqual(work.authorUsername, "alice")
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
        // Current page is marked by an inner `<span class="current">`, as AO3
        // renders it on real pages — the <li> has no "current" class.
        XCTAssertEqual(result.currentPage, 2)
        XCTAssertEqual(result.totalPages, 3)
    }

    func test_currentPageFromLiClass() throws {
        // Some AO3 pages put the "current" class on the <li> itself; both forms
        // must resolve so "Load more" advances past page 2.
        let liForm = """
        <html><body>
        <ol class="work index group"></ol>
        <ol class="pagination actions">
          <li><a href="?page=1">1</a></li>
          <li class="current">3</li>
          <li><a href="?page=4">4</a></li>
          <li><a href="?page=9">9</a></li>
        </ol>
        </body></html>
        """
        let result = try SearchResultsParser.parse(html: liForm)
        XCTAssertEqual(result.currentPage, 3)
        XCTAssertEqual(result.totalPages, 9)
    }

    func test_emptyResultsDoNotCrash() throws {
        let empty = "<html><body><ol class=\"work index group\"></ol></body></html>"
        let result = try SearchResultsParser.parse(html: empty)
        XCTAssertTrue(result.works.isEmpty)
    }

    // MARK: - Bookmarks page

    /// The bookmarks page wraps each work in `li.bookmark.blurb` and tags the
    /// <li> with `bookmark_<id>`, not `work_<id>`, so the work id must come from
    /// the `/works/<id>` title link. Series/external bookmarks (no /works/ link)
    /// must be skipped.
    private let bookmarksHTML = """
    <html><body>
    <ol class="bookmark index group">
      <li id="bookmark_555" class="bookmark blurb group" role="article">
        <div class="header module">
          <h4 class="heading">
            <a href="/works/98765">Bookmarked Fic</a>
            by
            <a rel="author" href="/users/carol/pseuds/carol">carol</a>
          </h4>
          <h5 class="fandoms heading">
            <a class="tag" href="/tags/Harry%20Potter/works">Harry Potter</a>
          </h5>
          <ul class="required-tags">
            <li><a><span class="text">Teen And Up Audiences</span></a></li>
            <li><a><span class="text">No Archive Warnings Apply</span></a></li>
          </ul>
        </div>
        <dl class="stats">
          <dt class="words">Words:</dt><dd class="words">10,000</dd>
          <dt class="chapters">Chapters:</dt><dd class="chapters">5/5</dd>
          <dt class="kudos">Kudos:</dt><dd class="kudos">300</dd>
        </dl>
      </li>
      <li id="bookmark_777" class="bookmark blurb group" role="article">
        <div class="header module">
          <h4 class="heading">
            <a href="/series/4242">A Bookmarked Series</a>
            by
            <a rel="author" href="/users/dave/pseuds/dave">dave</a>
          </h4>
        </div>
      </li>
    </ol>
    </body></html>
    """

    func test_bookmarksParseSkipsNonWorkAndReadsWorkIdFromLink() throws {
        let result = try SearchResultsParser.parse(html: bookmarksHTML, blurbSelector: "li.bookmark.blurb")
        // The series bookmark (no /works/ link) is skipped.
        XCTAssertEqual(result.works.count, 1)
        let work = result.works[0]
        XCTAssertEqual(work.id, 98765, "id must come from the /works/<id> link, not the bookmark_<id> li")
        XCTAssertEqual(work.title, "Bookmarked Fic")
        XCTAssertEqual(work.author, "carol")
        XCTAssertEqual(work.fandoms, ["Harry Potter"])
        XCTAssertEqual(work.wordCount, 10000)
        XCTAssertEqual(work.chapterCount, 5)
        XCTAssertEqual(work.totalChapters, 5)
    }

    // MARK: - Readings page (Marked for Later)

    /// Markup from AO3's readings templates (otwarchive
    /// `readings/index.html.erb` + `_reading_blurb.html.erb`): each entry is
    /// `li.reading.work.blurb` with id `work_<id>`, wrapping the usual work
    /// blurb plus a "Last visited" module; a deleted work keeps an entry with
    /// no id and no title link. Pagination is AO3's pagy nav.
    private let readingsHTML = """
    <html><body>
    <div id="main" class="readings-index dashboard region" role="main">
    <h2 class="heading">Marked for Later</h2>
    <h4 class="landmark heading">Pages Navigation</h4>
    <ol class="pagination actions pagy" role="navigation">
      <li class="previous"><a href="/users/me/readings?page=1&amp;show=to-read">← Previous</a></li>
      <li><a href="/users/me/readings?page=1&amp;show=to-read">1</a></li>
      <li><a role="link" aria-disabled="true" aria-current="page" class="current">2</a></li>
      <li><a href="/users/me/readings?page=3&amp;show=to-read">3</a></li>
      <li class="next"><a href="/users/me/readings?page=3&amp;show=to-read">Next →</a></li>
    </ol>
    <h3 class="landmark heading">List of Marked for Later Items</h3>
    <ol class="reading work index group">
      <li id="work_4242" class="reading work blurb group work-4242 user-1" role="article">
        <div class="header module">
          <h4 class="heading">
            <a href="/works/4242">Saved For Later</a>
            by
            <a rel="author" href="/users/erin/pseuds/erin">erin</a>
          </h4>
          <h5 class="fandoms heading">
            <a class="tag" href="/tags/Good%20Omens/works">Good Omens</a>
          </h5>
          <ul class="required-tags">
            <li><a><span class="text">General Audiences</span></a></li>
            <li><a><span class="text">No Archive Warnings Apply</span></a></li>
            <li><a><span class="text">Work in Progress</span></a></li>
          </ul>
          <p class="datetime">12 Oct 2026</p>
        </div>
        <dl class="stats">
          <dt class="words">Words:</dt><dd class="words">2,500</dd>
          <dt class="chapters">Chapters:</dt><dd class="chapters">2/?</dd>
        </dl>
        <div class="user module group">
          <h4 class="viewed heading">
            <span>Last visited:</span> 14 Oct 2026
            (Latest version.)
            Visited once
            (Marked for Later.)
          </h4>
          <ul class="actions"><li><form action="/users/me/readings/9" method="post"><input type="submit" value="Delete from History"></form></li></ul>
        </div>
      </li>
      <li class="deleted reading work blurb group" role="article">
        <div class="user module group">
          <h4 class="viewed heading">(Deleted work, last visited 01 Jan 2026)</h4>
        </div>
      </li>
    </ol>
    </div>
    </body></html>
    """

    func test_readingsParseListsWorksAndSkipsDeleted() throws {
        let result = try SearchResultsParser.parseReadings(html: readingsHTML)
        XCTAssertEqual(result.works.count, 1, "the deleted entry has no work and is skipped")
        let work = result.works[0]
        XCTAssertEqual(work.id, 4242)
        XCTAssertEqual(work.title, "Saved For Later")
        XCTAssertEqual(work.author, "erin")
        XCTAssertEqual(work.authorUsername, "erin")
        XCTAssertEqual(work.fandoms, ["Good Omens"])
        XCTAssertEqual(work.wordCount, 2500)
        XCTAssertEqual(work.chapterCount, 2)
        XCTAssertNil(work.totalChapters)
        XCTAssertEqual(result.currentPage, 2)
        XCTAssertEqual(result.totalPages, 3)
    }

    func test_readingsParseEmptyList() throws {
        // AO3 renders no list and no pagination when nothing is marked.
        let empty = """
        <html><body><div id="main" class="readings-index dashboard region" role="main">
        <h2 class="heading">Marked for Later</h2>
        <h3 class="landmark heading">List of Marked for Later Items</h3>
        </div></body></html>
        """
        let result = try SearchResultsParser.parseReadings(html: empty)
        XCTAssertTrue(result.works.isEmpty)
        XCTAssertEqual(result.totalPages, 1)
    }

    func test_readingsParseLoginPageFailsClosed() {
        // An expired session: AO3 redirects to the login form, served as a 200.
        let login = """
        <html><body><div id="main" class="user_sessions-new region">
        <form id="new_user_session_small" action="/users/login" method="post">
          <input name="user[login]"><input name="user[password]" type="password">
        </form></div></body></html>
        """
        XCTAssertThrowsError(try SearchResultsParser.parseReadings(html: login)) { error in
            XCTAssertEqual(error as? AO3Error, .unauthorized)
        }
    }

    func test_readingsParseOtherPageFailsClosed() {
        // History turned off: AO3 redirects to the preferences page.
        let prefs = "<html><body><div id=\"main\" class=\"preferences-index dashboard region\"></div></body></html>"
        XCTAssertThrowsError(try SearchResultsParser.parseReadings(html: prefs)) { error in
            guard case AO3Error.parseFailed(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("Turn on History"), reason)
        }
        // Anything else (markup drift, an error page) is never an empty list.
        XCTAssertThrowsError(try SearchResultsParser.parseReadings(html: "<html><body><p>Oops</p></body></html>"))
    }

    func test_workIdFromHref() {
        XCTAssertEqual(SearchResultsParser.workId(fromHref: "/works/12345"), 12345)
        XCTAssertEqual(SearchResultsParser.workId(fromHref: "/works/12345/chapters/678"), 12345)
        XCTAssertNil(SearchResultsParser.workId(fromHref: "/series/4242"))
        XCTAssertNil(SearchResultsParser.workId(fromHref: ""))
    }

    // MARK: - Failing closed (RM-001)

    func test_emptySearch_returnsNoWorks() throws {
        let html = AO3PageFixtures.guestPage(mainClass: "works-search", body: """
        <h2 class="heading">Search Results</h2>
        <p>No results found. You may want to edit your search to make it less specific.</p>
        """)
        XCTAssertTrue(try SearchResultsParser.parse(html: html).works.isEmpty)
    }

    func test_emptyAuthorWorks_returnsNoWorks() throws {
        let html = AO3PageFixtures.guestPage(mainClass: "works-index dashboard", body: """
        <h2 class="heading">0 Works by alice</h2>
        <h3 class="landmark heading">Listing Works</h3>
        <ol class="work index group"></ol>
        """)
        XCTAssertTrue(try SearchResultsParser.parse(html: html).works.isEmpty)
    }

    func test_emptyBookmarks_returnsNoWorks() throws {
        let html = AO3PageFixtures.guestPage(mainClass: "bookmarks-index dashboard", body: """
        <h2 class="heading">0 Bookmarks by alice</h2>
        <ol class="bookmark index group"></ol>
        """)
        XCTAssertTrue(try SearchResultsParser.parse(html: html, blurbSelector: "li.bookmark.blurb").works.isEmpty)
    }

    /// Every guest page has the header's login form; it must not read as the
    /// login page.
    func test_guestResultsPage_stillParses() throws {
        let html = AO3PageFixtures.guestPage(mainClass: "works-search", body: """
        <ol class="work index group">
          <li id="work_12345" class="work blurb group" role="article">
            <div class="header module"><h4 class="heading"><a href="/works/12345">A Coffee Shop Tale</a></h4></div>
          </li>
        </ol>
        """)
        XCTAssertEqual(try SearchResultsParser.parse(html: html).works.map(\.id), [12345])
    }

    func test_loginPage_throwsUnauthorized() {
        for selector in ["li.work.blurb", "li.bookmark.blurb"] {
            XCTAssertThrowsError(try SearchResultsParser.parse(html: AO3PageFixtures.loginPage, blurbSelector: selector)) { error in
                XCTAssertEqual(error as? AO3Error, .unauthorized)
            }
        }
    }

    func test_garbagePage_throwsParseFailed() {
        for html in [AO3PageFixtures.errorPage, AO3PageFixtures.foreignPage, "<html><body></body></html>"] {
            XCTAssertThrowsError(try SearchResultsParser.parse(html: html)) { error in
                guard case AO3Error.parseFailed = error else {
                    return XCTFail("Expected parseFailed, got \(error)")
                }
            }
        }
    }
}

/// Page shells for the fail-closed parser tests, cut down from otwarchive's own
/// templates (`layouts/application`, `users/sessions/new`, `public/502.html`).
/// AO3 sets `#main`'s class to the Rails `controller-action`.
enum AO3PageFixtures {
    /// The header every logged-out page carries, small login form included.
    static let guestHeader = """
    <div id="header" class="region" role="banner">
      <h1 class="heading"><a href="/"><span>Archive of Our Own</span></a></h1>
      <div id="login" class="dropdown">
        <p class="user actions"><a id="login-dropdown" href="/users/login?return_to=%2Fworks">Log In</a></p>
        <div id="small_login" class="simple login">
          <form class="new_user" id="new_user_session_small" action="/users/login?return_to=%2Fworks" accept-charset="UTF-8" method="post">
            <dl>
              <dt><label for="user_session_login_small">Username or email:</label></dt>
              <dd><input autocomplete="on" id="user_session_login_small" type="text" name="user[login]" /></dd>
              <dt><label for="user_password">Password:</label></dt>
              <dd><input type="password" name="user[password]" id="user_password" /></dd>
            </dl>
          </form>
        </div>
      </div>
    </div>
    """

    static func guestPage(mainClass: String, body: String) -> String {
        """
        <html><body><div id="outer" class="wrapper">
        \(guestHeader)
        <div id="inner" class="wrapper">
          <div id="main" class="\(mainClass) region" role="main">
          \(body)
          </div>
        </div>
        </div></body></html>
        """
    }

    /// Where AO3 sends a stale session or a guest opening a restricted work.
    static let loginPage = guestPage(mainClass: "sessions-new system session", body: """
    <h3 class="heading">Sorry!</h3>
    <p>This work is only available to registered users of the Archive.</p>
    <div id="loginform">
      <form class="new_user" id="new_user" action="/users/login" accept-charset="UTF-8" method="post">
        <dl>
          <dt><label for="user_login">Username or email:</label></dt>
          <dd><input type="text" name="user[login]" id="user_login" /></dd>
          <dt><label for="user_password">Password:</label></dt>
          <dd><input type="password" name="user[password]" id="user_password" /></dd>
        </dl>
      </form>
    </div>
    """)

    /// AO3's static 502 page.
    static let errorPage = guestPage(mainClass: "system errors error-502", body: """
    <h2 class="heading">Error 502</h2>
    <p>The page was responding too slowly.</p>
    """)

    /// Not AO3 at all: a captive portal or a proxy's block page.
    static let foreignPage = """
    <html><head><title>Sign in to Wi-Fi</title></head>
    <body><h1>Welcome</h1><a href="/tags/accept/works">Accept and continue</a></body></html>
    """
}
