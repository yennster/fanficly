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

    func test_cleanChapterTitle_stripsAO3Prefix() {
        XCTAssertEqual(WorkPageParser.cleanChapterTitle("Chapter 1: The Real Title", index: 1), "The Real Title")
        XCTAssertEqual(WorkPageParser.cleanChapterTitle("Chapter 6: Chapter 6", index: 6), "")
        XCTAssertEqual(WorkPageParser.cleanChapterTitle("Chapter 3", index: 3), "")
        XCTAssertEqual(WorkPageParser.cleanChapterTitle("A Standalone Title", index: 2), "A Standalone Title")
        XCTAssertEqual(WorkPageParser.cleanChapterTitle("Chapter 10: Chapter 10", index: 10), "")
    }

    func test_landmarkChapterTextStripped() throws {
        let html = """
        <html><body><div id="workskin">
        <div class="chapter" id="chapter-1">
          <div class="chapter preface group"><h3 class="title">Chapter 1</h3></div>
          <h3 class="landmark heading">Chapter Text</h3>
          <div class="userstuff module"><p>The actual story begins.</p></div>
        </div>
        </div></body></html>
        """
        let payload = try WorkPageParser.parse(html: html, workId: 5)
        XCTAssertEqual(payload.chapters.count, 1)
        XCTAssertEqual(payload.chapters[0].title, "")
        XCTAssertFalse(payload.chapters[0].bodyHTML.contains("Chapter Text"))
        XCTAssertTrue(payload.chapters[0].bodyHTML.contains("The actual story begins."))
    }

    func test_extractsChapters() throws {
        let payload = try WorkPageParser.parse(html: html, workId: 12345)
        XCTAssertEqual(payload.chapters.count, 2)
        // AO3's "Chapter N: " prefix is stripped; only the custom title remains.
        XCTAssertEqual(payload.chapters[0].title, "Latte")
        XCTAssertTrue(payload.chapters[0].bodyHTML.contains("Bella poured"))
        XCTAssertTrue(payload.chapters[0].bodyHTML.contains("<em>It was hot.</em>"))
        XCTAssertEqual(payload.chapters[1].title, "Espresso")
    }

    func test_chapterId_fromHref() {
        XCTAssertEqual(WorkPageParser.chapterId(fromHref: "/works/12345/chapters/678"), 678)
        XCTAssertEqual(WorkPageParser.chapterId(fromHref: "https://archiveofourown.org/works/9/chapters/42?view_adult=true"), 42)
        XCTAssertNil(WorkPageParser.chapterId(fromHref: "/works/12345"))
        XCTAssertNil(WorkPageParser.chapterId(fromHref: "/users/alice"))
    }

    func test_extractsChapterIds_fromHeadingLinks() throws {
        let html = """
        <html><body><div id="chapters" class="userstuff">
          <div class="chapter" id="chapter-1">
            <div class="chapter preface group"><h3 class="title"><a href="/works/12345/chapters/678">Chapter 1</a>: Latte</h3></div>
            <div class="userstuff module"><p>One.</p></div>
          </div>
          <div class="chapter" id="chapter-2">
            <div class="chapter preface group"><h3 class="title"><a href="/works/12345/chapters/690">Chapter 2</a>: Espresso</h3></div>
            <div class="userstuff module"><p>Two.</p></div>
          </div>
        </div></body></html>
        """
        let payload = try WorkPageParser.parse(html: html, workId: 12345)
        XCTAssertEqual(payload.chapters.count, 2)
        XCTAssertEqual(payload.chapters[0].aoId, 678)
        XCTAssertEqual(payload.chapters[1].aoId, 690)
    }

    func test_extractsChapterIds_fromSelectFallback() throws {
        // No per-chapter heading links → fall back to the chapter jump menu.
        let html = """
        <html><body>
          <select id="selected_id" name="selected_id">
            <option value="678">1. Latte</option>
            <option value="690" selected>2. Espresso</option>
          </select>
          <div id="chapters" class="userstuff">
            <div class="chapter" id="chapter-1"><div class="userstuff module"><p>One.</p></div></div>
            <div class="chapter" id="chapter-2"><div class="userstuff module"><p>Two.</p></div></div>
          </div>
        </body></html>
        """
        let payload = try WorkPageParser.parse(html: html, workId: 12345)
        XCTAssertEqual(payload.chapters[0].aoId, 678)
        XCTAssertEqual(payload.chapters[1].aoId, 690)
    }

    func test_chapterId_nilWhenAbsent() throws {
        // The base fixture's chapters have no links/selector → no ids (callers
        // then fall back to work-level comments).
        let payload = try WorkPageParser.parse(html: html, workId: 12345)
        XCTAssertNil(payload.chapters[0].aoId)
    }
}

final class CommentsParserTests: XCTestCase {
    private let html = """
    <html><body>
    <div id="comments_placeholder">
      <ol class="thread">
        <li id="comment_111" class="comment group" role="article">
          <h4 class="byline heading"><a href="/users/alice/pseuds/alice">alice</a></h4>
          <span class="posted datetime">10 Mar 2024</span>
          <blockquote class="userstuff"><p>Loved this chapter!</p></blockquote>
          <ol class="thread">
            <li id="comment_222" class="comment group" role="article">
              <h4 class="byline heading"><a href="/users/bob/pseuds/bob">bob</a></h4>
              <span class="posted datetime">11 Mar 2024</span>
              <blockquote class="userstuff"><p>Agreed, so good.</p></blockquote>
            </li>
          </ol>
        </li>
        <li id="comment_333" class="comment group" role="article">
          <h4 class="byline heading">GuestReader (Guest)</h4>
          <span class="posted datetime">12 Mar 2024</span>
          <blockquote class="userstuff"><p>Found this as a guest.</p></blockquote>
        </li>
      </ol>
    </div>
    </body></html>
    """

    func test_parsesThreadWithDepth() throws {
        let comments = try CommentsParser.parse(html: html)
        XCTAssertEqual(comments.count, 3)

        XCTAssertEqual(comments[0].id, "111")
        XCTAssertEqual(comments[0].commenterName, "alice")
        XCTAssertEqual(comments[0].commenterUsername, "alice")
        XCTAssertEqual(comments[0].depth, 0)
        XCTAssertTrue(comments[0].bodyHTML.contains("Loved this chapter"))

        // Nested reply is one level deep.
        XCTAssertEqual(comments[1].id, "222")
        XCTAssertEqual(comments[1].depth, 1)

        // Guest comment has no username.
        XCTAssertEqual(comments[2].commenterName, "GuestReader (Guest)")
        XCTAssertEqual(comments[2].commenterUsername, "")
        XCTAssertEqual(comments[2].depth, 0)
    }

    func test_parsesCommentsDespitePrecedingEmptyWrapper() throws {
        // Mirrors real AO3: an empty <div id="comments"> precedes
        // #comments_placeholder, which holds pagination <li>s + the real
        // comments. The old container-scoped parser locked onto the empty
        // wrapper and returned nothing; pagination <li>s must also be ignored.
        let html = """
        <html><body>
        <div id="comments" class="comments"></div>
        <div id="comments_placeholder">
          <ol class="pagination actions"><li class="previous"><span>Prev</span></li><li><span class="current">1</span></li></ol>
          <ol class="thread">
            <li class="odd comment group user-1" id="comment_999" role="article">
              <h4 class="heading byline"><a href="/users/zed/pseuds/zed">zed</a> <span class="parent"> on <a href="/works/1/chapters/2">Chapter 1</a></span></h4>
              <span class="posted datetime">10 Mar 2024</span>
              <blockquote class="userstuff"><p>Great chapter!</p></blockquote>
            </li>
          </ol>
        </div>
        </body></html>
        """
        let comments = try CommentsParser.parse(html: html)
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments[0].id, "999")
        XCTAssertEqual(comments[0].commenterName, "zed")
        XCTAssertEqual(comments[0].depth, 0)
        XCTAssertTrue(comments[0].bodyHTML.contains("Great chapter"))
    }

    func test_defaultPseudId() {
        let formHTML = """
        <form><select name="comment[pseud_id]">
          <option value="10">main</option>
          <option value="20" selected>writing_pseud</option>
        </select></form>
        """
        XCTAssertEqual(CommentsParser.defaultPseudId(html: formHTML), "20")
        XCTAssertNil(CommentsParser.defaultPseudId(html: "<html></html>"))
    }

    func test_newCommentForm_capturesActionAndFields() throws {
        // A nested reply form (inside an existing comment) plus the page-level
        // composer; we must pick the composer and capture its action + fields.
        let html = """
        <html><body>
        <ol class="thread">
          <li id="comment_1" class="comment group">
            <form action="/comments/1" class="reply"><textarea name="comment[comment_content]"></textarea></form>
          </li>
        </ol>
        <div id="add_comment_placeholder">
          <form action="/works/12345/chapters/678/comments" method="post">
            <input type="hidden" name="authenticity_token" value="TOK123">
            <input type="hidden" name="comment[commentable_id]" value="678">
            <input type="hidden" name="comment[commentable_type]" value="Chapter">
            <select name="comment[pseud_id]"><option value="20" selected>me</option></select>
            <textarea name="comment[comment_content]"></textarea>
          </form>
        </div>
        </body></html>
        """
        let base = URL(string: "https://archiveofourown.org")!
        let form = try XCTUnwrap(CommentsParser.newCommentForm(html: html, base: base))
        XCTAssertEqual(form.action.absoluteString, "https://archiveofourown.org/works/12345/chapters/678/comments")
        XCTAssertEqual(form.fields["authenticity_token"], "TOK123")
        XCTAssertEqual(form.fields["comment[commentable_id]"], "678")
        XCTAssertEqual(form.fields["comment[commentable_type]"], "Chapter")
        XCTAssertEqual(form.fields["comment[pseud_id]"], "20")
    }

    func test_newCommentForm_nilWhenNoComposer() {
        XCTAssertNil(CommentsParser.newCommentForm(html: "<html><body><p>no form</p></body></html>",
                                                   base: URL(string: "https://archiveofourown.org")!))
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

    func test_usernameFromGreetingDropdown() throws {
        let html = """
        <html><body>
        <div id="greeting"><ul class="user navigation actions">
          <li class="dropdown"><a class="dropdown-toggle" href="/users/yennster">yennster</a></li>
          <li><a href="/users/logout">Log Out</a></li>
        </ul></div>
        </body></html>
        """
        XCTAssertEqual(try LoginParser.currentUsername(html: html), "yennster")
    }

    func test_currentUsernameSkipsActionLinks() throws {
        // A logged-out page links to /users/login — must not be read as a name.
        let html = "<html><body><div id=\"header\"><a href=\"/users/login\">Log In</a></div></body></html>"
        XCTAssertNil(try LoginParser.currentUsername(html: html))
    }

    func test_hasLoginForm() throws {
        let withForm = "<html><body><form id=\"new_user\"><input name=\"user[login]\"></form></body></html>"
        XCTAssertTrue(try LoginParser.hasLoginForm(html: withForm))
        let dashboard = "<html><body><div id=\"greeting\">Hi!</div></body></html>"
        XCTAssertFalse(try LoginParser.hasLoginForm(html: dashboard))
    }
}
