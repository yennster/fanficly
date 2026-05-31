import XCTest
@testable import Fanficly

final class WorkPageParserTests: XCTestCase {
    private let html = """
    <html><body>
    <div id="main">
      <div class="wrapper">
        <dl class="work meta group">
          <dt>Rating:</dt><dd class="rating"><ul><li><a class="tag" href="/tags/Mature/works">Mature</a></li></ul></dd>
          <dt>Archive Warning:</dt><dd class="warning"><ul><li><a class="tag">No Archive Warnings Apply</a></li></ul></dd>
          <dt>Category:</dt><dd class="category"><ul><li><a class="tag">M/M</a></li></ul></dd>
          <dt>Fandom:</dt><dd class="fandom"><ul><li><a class="tag">Twilight</a></li></ul></dd>
          <dt>Relationship:</dt><dd class="relationship"><ul><li><a class="tag">Edward Cullen/Bella Swan</a></li></ul></dd>
          <dt>Character:</dt><dd class="character"><ul><li><a class="tag">Edward Cullen</a></li><li><a class="tag">Bella Swan</a></li></ul></dd>
          <dt>Additional Tags:</dt><dd class="freeform"><ul><li><a class="tag">All Human</a></li><li><a class="tag">Slow Burn</a></li></ul></dd>
          <dt>Language:</dt><dd class="language">English</dd>
          <dt>Stats:</dt>
          <dd class="stats">
            <dl class="stats">
              <dt class="published">Published:</dt><dd class="published">2024-01-15</dd>
              <dt class="status">Updated:</dt><dd class="status">2024-03-12</dd>
              <dt class="words">Words:</dt><dd class="words">45,234</dd>
              <dt class="chapters">Chapters:</dt><dd class="chapters">2/2</dd>
              <dt class="comments">Comments:</dt><dd class="comments">234</dd>
              <dt class="kudos">Kudos:</dt><dd class="kudos">1,234</dd>
              <dt class="bookmarks">Bookmarks:</dt><dd class="bookmarks">100</dd>
              <dt class="hits">Hits:</dt><dd class="hits">23,456</dd>
            </dl>
          </dd>
        </dl>
        <div class="preface group">
          <h2 class="title heading">A Coffee Shop Tale</h2>
          <h3 class="byline heading"><a rel="author" href="/users/alice/pseuds/alice">alice</a></h3>
          <div class="summary module">
            <h3 class="heading">Summary</h3>
            <blockquote class="userstuff"><p>Bella works at a coffee shop.</p></blockquote>
          </div>
        </div>
        <div id="chapters" class="userstuff">
          <div class="chapter" id="chapter-1">
            <div class="chapter preface group">
              <h3 class="title">Chapter 1: Latte</h3>
            </div>
            <div class="userstuff module">
              <p>Bella poured the latte. <em>It was hot.</em></p>
            </div>
          </div>
          <div class="chapter" id="chapter-2">
            <div class="chapter preface group">
              <h3 class="title">Chapter 2: Espresso</h3>
            </div>
            <div class="userstuff module">
              <p>Edward returned the next morning.</p>
            </div>
          </div>
        </div>
      </div>
    </div>
    </body></html>
    """

    func test_extractsTitleAndAuthor() throws {
        let payload = try WorkPageParser.parse(html: html, workId: 12345)
        XCTAssertEqual(payload.summary.title, "A Coffee Shop Tale")
        XCTAssertEqual(payload.summary.author, "alice")
    }

    func test_extractsMetadata() throws {
        let payload = try WorkPageParser.parse(html: html, workId: 12345)
        let s = payload.summary
        XCTAssertEqual(s.rating, "Mature")
        XCTAssertEqual(s.warnings, ["No Archive Warnings Apply"])
        XCTAssertEqual(s.categories, ["M/M"])
        XCTAssertEqual(s.relationships, ["Edward Cullen/Bella Swan"])
        XCTAssertEqual(s.characters, ["Edward Cullen", "Bella Swan"])
        XCTAssertEqual(s.freeforms, ["All Human", "Slow Burn"])
        XCTAssertEqual(s.fandoms, ["Twilight"])
        XCTAssertEqual(s.wordCount, 45234)
        XCTAssertEqual(s.kudos, 1234)
        XCTAssertEqual(s.hits, 23456)
        XCTAssertEqual(s.chapterCount, 2)
        XCTAssertEqual(s.totalChapters, 2)
        XCTAssertTrue(s.isComplete)
    }

    func test_extractsChapters() throws {
        let payload = try WorkPageParser.parse(html: html, workId: 12345)
        XCTAssertEqual(payload.chapters.count, 2)
        XCTAssertEqual(payload.chapters[0].title, "Chapter 1: Latte")
        XCTAssertTrue(payload.chapters[0].bodyHTML.contains("Bella poured"))
        XCTAssertTrue(payload.chapters[0].bodyHTML.contains("<em>It was hot.</em>"))
        XCTAssertEqual(payload.chapters[1].title, "Chapter 2: Espresso")
    }
}

final class LoginParserTests: XCTestCase {
    func test_extractsTokenFromMeta() throws {
        let html = """
        <html><head><meta name="csrf-token" content="abc123token"/></head><body></body></html>
        """
        XCTAssertEqual(try LoginParser.authenticityToken(html: html), "abc123token")
    }

    func test_extractsTokenFromForm() throws {
        let html = """
        <html><body>
        <form action="/users/login" method="post">
          <input name="authenticity_token" type="hidden" value="formtoken456"/>
          <input name="user[login]"/>
          <input name="user[password]"/>
        </form>
        </body></html>
        """
        XCTAssertEqual(try LoginParser.authenticityToken(html: html), "formtoken456")
    }

    func test_detectsLoginFailure() throws {
        let html = """
        <html><body>
        <div id="flash_error">The password or username you entered doesn't match our records.</div>
        </body></html>
        """
        let msg = try LoginParser.detectLoginFailure(html: html)
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("password"))
    }

    func test_extractsCurrentUsername() throws {
        let html = """
        <html><body>
        <ul id="user-navigation">
          <li><a href="/users/alice">My Dashboard</a></li>
        </ul>
        </body></html>
        """
        XCTAssertEqual(try LoginParser.currentUsername(html: html), "alice")
    }

    func test_noUsernameWhenLoggedOut() throws {
        let html = "<html><body><ul id=\"user-navigation\"></ul></body></html>"
        XCTAssertNil(try LoginParser.currentUsername(html: html))
    }
}
