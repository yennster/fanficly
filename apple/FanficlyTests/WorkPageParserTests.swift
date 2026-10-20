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

    // MARK: - Failing closed (RM-001)

    /// A real work page whose only chapter has no text still parses: the guest
    /// header's login form doesn't make it the login page.
    func test_guestWorkPageWithEmptyChapter_parses() throws {
        let html = AO3PageFixtures.guestPage(mainClass: "works-show", body: """
        <div class="wrapper"><dl class="work meta group">
          <dt class="rating tags">Rating:</dt><dd class="rating tags"><ul class="commas"><li><a class="tag" href="/tags/General%20Audiences/works">General Audiences</a></li></ul></dd>
        </dl></div>
        <div id="workskin">
          <div class="preface group"><h2 class="title heading">Blank Page</h2></div>
          <div id="chapters" role="article"><div class="userstuff"></div></div>
        </div>
        """)
        let payload = try WorkPageParser.parse(html: html, workId: 7)
        XCTAssertEqual(payload.summary.title, "Blank Page")
        XCTAssertEqual(payload.summary.rating, "General Audiences")
    }

    func test_restrictedWorkLoginPage_throwsUnauthorized() {
        XCTAssertThrowsError(try WorkPageParser.parse(html: AO3PageFixtures.loginPage, workId: 7)) { error in
            XCTAssertEqual(error as? AO3Error, .unauthorized)
        }
    }

    /// Anything without the work's markup (an error page, the adult gate, a
    /// foreign page) would otherwise parse to an untitled work with no
    /// chapters and overwrite a saved copy.
    func test_garbagePage_throwsParseFailed() {
        let adultGate = AO3PageFixtures.guestPage(mainClass: "works-show", body: """
        <p class="caution notice">This work could have adult content. If you continue, you have agreed that you are willing to see such content.</p>
        <ul class="actions"><li><a href="/works/7?view_adult=true">Yes, Continue</a></li></ul>
        """)
        for html in [AO3PageFixtures.errorPage, AO3PageFixtures.foreignPage, adultGate] {
            XCTAssertThrowsError(try WorkPageParser.parse(html: html, workId: 7)) { error in
                guard case AO3Error.parseFailed = error else {
                    return XCTFail("Expected parseFailed, got \(error)")
                }
            }
        }
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

    func test_replyDepth_ao3WrapperStructure() throws {
        // AO3's real markup: the reply's <li.comment> is NOT inside its parent's.
        // It sits in a further <ol class="thread"> within an *unclassed* wrapper
        // <li> that is a sibling of the parent. Depth must come from ancestor
        // threads, not ancestor comment <li>s (which would give the reply 0).
        let html = """
        <html><body><div id="comments_placeholder"><ol class="thread">
          <li class="odd comment group" id="comment_1" role="article">
            <h4 class="heading byline"><a href="/users/a/pseuds/a">a</a></h4>
            <blockquote class="userstuff"><p>Top-level.</p></blockquote>
          </li>
          <li>
            <ol class="thread">
              <li class="even comment group" id="comment_2" role="article">
                <h4 class="heading byline"><a href="/users/b/pseuds/b">b</a></h4>
                <blockquote class="userstuff"><p>A reply.</p></blockquote>
              </li>
            </ol>
          </li>
        </ol></div></body></html>
        """
        let comments = try CommentsParser.parse(html: html)
        XCTAssertEqual(comments.count, 2)
        XCTAssertEqual(comments[0].id, "1")
        XCTAssertEqual(comments[0].depth, 0)
        XCTAssertEqual(comments[1].id, "2")
        XCTAssertEqual(comments[1].depth, 1)
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

    /// AO3's comment pagination (will_paginate's list renderer): an
    /// `ol.pagination.actions` above and below the thread in
    /// `#comments_placeholder`, the current page as `<span class="current">`.
    private func pagedHTML(current: Int, total: Int) -> String {
        let pages = (1...total).map { n in
            n == current
                ? "<li><span class=\"current\">\(n)</span></li>"
                : "<li><a href=\"/works/1/chapters/2?page=\(n)&amp;show_comments=true#comments\">\(n)</a></li>"
        }.joined()
        let nav = """
        <h4 class="landmark heading">Pages Navigation</h4>
        <ol class="pagination actions" role="navigation" title="pagination">
          <li class="previous" title="previous"><span class="disabled">← Previous</span></li>
          \(pages)
          <li class="next" title="next"><a rel="next" href="/works/1/chapters/2?page=2&amp;show_comments=true#comments">Next →</a></li>
        </ol>
        """
        return """
        <html><body>
        <div id="comments" class="comments"></div>
        <div id="comments_placeholder">
          \(nav)
          <ol class="thread">
            <li class="odd comment group" id="comment_\(current)00" role="article">
              <h4 class="heading byline"><a href="/users/zed/pseuds/zed">zed</a></h4>
              <blockquote class="userstuff"><p>Page \(current).</p></blockquote>
            </li>
          </ol>
          \(nav)
        </div>
        </body></html>
        """
    }

    func test_parsePage_readsCommentPagination() throws {
        let page = try CommentsParser.parsePage(html: pagedHTML(current: 2, total: 4))
        XCTAssertEqual(page.currentPage, 2)
        XCTAssertEqual(page.totalPages, 4)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.comments.map(\.id), ["200"])

        let last = try CommentsParser.parsePage(html: pagedHTML(current: 4, total: 4))
        XCTAssertEqual(last.currentPage, 4)
        XCTAssertFalse(last.hasMore)
    }

    func test_parsePage_singlePageHasNoMore() throws {
        // A one-shot (or a short thread) has no pagination list at all.
        let page = try CommentsParser.parsePage(html: html)
        XCTAssertEqual(page.comments.count, 3)
        XCTAssertEqual(page.currentPage, 1)
        XCTAssertEqual(page.totalPages, 1)
        XCTAssertFalse(page.hasMore)
    }

    func test_parsePage_ignoresPaginationOutsideTheThread() throws {
        let html = """
        <html><body>
        <ol class="pagination actions"><li><span class="current">1</span></li><li><a href="#">9</a></li></ol>
        <div id="comments_placeholder"><ol class="thread">
          <li class="comment group" id="comment_1"><blockquote class="userstuff"><p>Hi</p></blockquote></li>
        </ol></div>
        </body></html>
        """
        let page = try CommentsParser.parsePage(html: html)
        XCTAssertEqual(page.totalPages, 1)
        XCTAssertFalse(page.hasMore)
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

    func test_newCommentForm_marksTheGuestForm() throws {
        let base = URL(string: "https://archiveofourown.org")!
        let guest = """
        <form action="/works/12/comments" method="post">
          <input type="hidden" name="authenticity_token" value="T">
          <input type="text" name="comment[name]"><input type="text" name="comment[email]">
          <textarea name="comment[comment_content]"></textarea>
        </form>
        """
        XCTAssertTrue(try XCTUnwrap(CommentsParser.newCommentForm(html: guest, base: base)).isGuest)
        let signedIn = """
        <form action="/works/12/comments" method="post">
          <input type="hidden" name="comment[pseud_id]" value="20">
          <textarea name="comment[comment_content]"></textarea>
        </form>
        """
        XCTAssertFalse(try XCTUnwrap(CommentsParser.newCommentForm(html: signedIn, base: base)).isGuest)
    }

    // MARK: postOutcome (otwarchive's CommentsController#create answers)

    private let action = URL(string: "https://archiveofourown.org/works/12/chapters/34/comments")!

    private func outcome(_ html: String, at path: String) -> CommentPostOutcome {
        CommentsParser.postOutcome(html: html, finalURL: URL(string: "https://archiveofourown.org" + path),
                                   formAction: action)
    }

    func test_postOutcome_postedOnTheCommentNotice() {
        let html = #"<div id="main"><div class="flash comment_notice">Comment created!</div></div>"#
        XCTAssertEqual(outcome(html, at: "/works/12/chapters/34"), .posted)
    }

    func test_postOutcome_postedOnTheModeratedCommentsPage() {
        XCTAssertEqual(outcome("<div id=\"main\"></div>", at: "/comments/987"), .posted)
    }

    func test_postOutcome_rejectedWhenTheFormIsReRendered() {
        let html = """
        <div id="main"><div class="flash error">Couldn't save comment!</div>
        <div id="error" class="error"><ul><li>Comment content can't be blank.</li></ul></div></div>
        """
        XCTAssertEqual(outcome(html, at: "/works/12/chapters/34/comments"),
                       .rejected(message: "Couldn't save comment! Comment content can't be blank."))
        // The same URL with no error markup is still a re-render, not a post.
        XCTAssertEqual(outcome("<div id=\"main\"></div>", at: "/works/12/chapters/34/comments"),
                       .rejected(message: "AO3 didn't save the comment."))
    }

    func test_postOutcome_rejectedOnARedirectWithAnError() {
        let html = #"<div id="main"><div class="flash comment_error">Sorry, you have been blocked by one or more of this work's creators.</div></div>"#
        XCTAssertEqual(outcome(html, at: "/works/12/chapters/34"),
                       .rejected(message: "Sorry, you have been blocked by one or more of this work's creators."))
    }

    func test_postOutcome_signedOutOnTheLoginPage() {
        let html = #"<div id="main" class="sessions-new"><form id="new_user" action="/users/login"></form></div>"#
        XCTAssertEqual(outcome(html, at: "/users/login"), .signedOut)
        XCTAssertEqual(outcome(html, at: "/works/12"), .signedOut)
    }

    func test_postOutcome_unconfirmedOtherwise() {
        XCTAssertEqual(outcome("<div id=\"main\"><p>Work text</p></div>", at: "/works/12/chapters/34"),
                       .rejected(message: CommentPostOutcome.unconfirmed))
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

/// Fixtures follow otwarchive's `bookmarks/_bookmark_form.html.erb` as Rails
/// renders it inside the work page's `#bookmark_form_placement`.
final class BookmarkFormParserTests: XCTestCase {
    private let base = URL(string: "https://archiveofourown.org")!

    private let newForm = """
    <html><body>
    <form action="/works/12345/chapters/678/comments" method="post">
      <input type="hidden" name="authenticity_token" value="COMMENTTOK">
      <textarea name="comment[comment_content]"></textarea>
    </form>
    <div id="bookmark_form_placement" class="wrapper toggled">
    <div class="post bookmark" id="bookmark-form">
      <form action="/works/12345/bookmarks" accept-charset="UTF-8" method="post">
        <input type="hidden" name="authenticity_token" value="TOK123" autocomplete="off">
        <fieldset>
          <h4 class="heading"><span class="byline">reader,
            <input value="20" autocomplete="off" type="hidden" name="bookmark[pseud_id]" id="bookmark_pseud_id">
          </span> save a bookmark!</h4>
          <textarea rows="4" id="bookmark_notes" class="observe_textlength" name="bookmark[bookmarker_notes]">
    </textarea>
          <input size="60" type="text" name="bookmark[tag_string]" id="bookmark_tag_string">
          <input type="text" name="bookmark[collection_names]" id="bookmark_collection_names">
          <input name="bookmark[private]" type="hidden" value="0" autocomplete="off"><input type="checkbox" value="1" name="bookmark[private]" id="bookmark_private">
          <input name="bookmark[rec]" type="hidden" value="0" autocomplete="off"><input type="checkbox" value="1" name="bookmark[rec]" id="bookmark_rec">
          <input type="submit" name="commit" value="Create">
        </fieldset>
      </form>
    </div>
    </div>
    </body></html>
    """

    private let existingForm = """
    <html><body>
    <div id="bookmark_form_placement" class="wrapper toggled">
    <div class="post bookmark" id="bookmark-form">
      <form action="/bookmarks/999" accept-charset="UTF-8" method="post">
        <input type="hidden" name="_method" value="put" autocomplete="off">
        <input type="hidden" name="authenticity_token" value="TOK456" autocomplete="off">
        <select name="bookmark[pseud_id]" title="choose pseud">
          <option value="20">reader</option>
          <option selected="selected" value="21">other_pseud</option>
        </select>
        <textarea rows="4" id="bookmark_notes" name="bookmark[bookmarker_notes]">
    Loved it.

    &lt;b&gt;Reread&lt;/b&gt; soon</textarea>
        <input size="60" type="text" value="comfort read, favourites" name="bookmark[tag_string]" id="bookmark_tag_string">
        <input type="text" value="my_collection" name="bookmark[collection_names]" id="bookmark_collection_names">
        <input name="bookmark[private]" type="hidden" value="0" autocomplete="off"><input type="checkbox" value="1" checked="checked" name="bookmark[private]" id="bookmark_private">
        <input name="bookmark[rec]" type="hidden" value="0" autocomplete="off"><input type="checkbox" value="1" name="bookmark[rec]" id="bookmark_rec">
        <input type="submit" name="commit" value="Update">
      </form>
    </div>
    </div>
    </body></html>
    """

    func test_newBookmark_readsActionTokenAndPseud() throws {
        let form = try XCTUnwrap(BookmarkFormParser.parse(html: newForm, base: base))
        XCTAssertEqual(form.action.absoluteString, "https://archiveofourown.org/works/12345/bookmarks")
        XCTAssertFalse(form.isExisting)
        XCTAssertEqual(form.hiddenFields["authenticity_token"], "TOK123")
        XCTAssertEqual(form.hiddenFields["bookmark[pseud_id]"], "20")
        XCTAssertNil(form.hiddenFields["_method"])
        XCTAssertEqual(form.notes, "")
        XCTAssertEqual(form.tags, "")
        XCTAssertFalse(form.isPrivate)
        XCTAssertFalse(form.isRec)
    }

    func test_existingBookmark_isPrefilledAndUpdates() throws {
        let form = try XCTUnwrap(BookmarkFormParser.parse(html: existingForm, base: base))
        XCTAssertEqual(form.action.absoluteString, "https://archiveofourown.org/bookmarks/999")
        XCTAssertTrue(form.isExisting)
        XCTAssertEqual(form.hiddenFields["_method"], "put")
        XCTAssertEqual(form.hiddenFields["authenticity_token"], "TOK456")
        XCTAssertEqual(form.hiddenFields["bookmark[pseud_id]"], "21", "the selected pseud, not the first")
        XCTAssertEqual(form.notes, "Loved it.\n\n<b>Reread</b> soon", "line breaks and HTML source survive")
        XCTAssertEqual(form.tags, "comfort read, favourites")
        XCTAssertEqual(form.collections, "my_collection")
        XCTAssertTrue(form.isPrivate)
        XCTAssertFalse(form.isRec)
    }

    func test_postFields_sendEditedValuesOnce() throws {
        var form = try XCTUnwrap(BookmarkFormParser.parse(html: existingForm, base: base))
        form.notes = "New notes"
        form.tags = "angst"
        form.isPrivate = false
        form.isRec = true
        let fields = form.postFields
        XCTAssertEqual(fields["_method"], "put")
        XCTAssertEqual(fields["authenticity_token"], "TOK456")
        XCTAssertEqual(fields["bookmark[pseud_id]"], "21")
        XCTAssertEqual(fields["bookmark[bookmarker_notes]"], "New notes")
        XCTAssertEqual(fields["bookmark[tag_string]"], "angst")
        XCTAssertEqual(fields["bookmark[collection_names]"], "my_collection", "collections are kept")
        XCTAssertEqual(fields["bookmark[private]"], "0")
        XCTAssertEqual(fields["bookmark[rec]"], "1")
        XCTAssertEqual(fields["commit"], "Update")
    }

    func test_newBookmark_commitsCreate() throws {
        let form = try XCTUnwrap(BookmarkFormParser.parse(html: newForm, base: base))
        XCTAssertEqual(form.postFields["commit"], "Create")
        XCTAssertEqual(form.postFields["bookmark[private]"], "0")
    }

    func test_nilWhenSignedOut() {
        let html = """
        <html><body><ul class="work navigation actions"><li class="comments"><a href="#comments">Comments</a></li></ul></body></html>
        """
        XCTAssertNil(BookmarkFormParser.parse(html: html, base: base))
    }

    func test_missingCollectionsField_isNotSent() throws {
        let html = newForm.replacingOccurrences(
            of: #"<input type="text" name="bookmark[collection_names]" id="bookmark_collection_names">"#, with: "")
        let form = try XCTUnwrap(BookmarkFormParser.parse(html: html, base: base))
        XCTAssertNil(form.collections)
        XCTAssertNil(form.postFields["bookmark[collection_names]"])
    }

    func test_isBookmarkPage_onlyForASavedBookmark() {
        XCTAssertTrue(BookmarkFormParser.isBookmarkPage(path: "/bookmarks/999"))
        XCTAssertFalse(BookmarkFormParser.isBookmarkPage(path: "/works/12345/bookmarks"))
        XCTAssertFalse(BookmarkFormParser.isBookmarkPage(path: "/"))
        XCTAssertFalse(BookmarkFormParser.isBookmarkPage(path: "/bookmarks/999/edit"))
    }

    func test_saveErrors_readsErrorFlash() {
        let html = #"<html><body><div class="flash error">You can't bookmark with that pseud.</div></body></html>"#
        XCTAssertEqual(BookmarkFormParser.flashErrors(html: html), ["You can't bookmark with that pseud."])
        XCTAssertEqual(BookmarkFormParser.saveErrors(html: html), [], "a flash isn't a form error")
    }

    func test_saveErrors_readsAO3ErrorList() {
        let html = """
        <html><body>
        <div id="error" class="error"><h4>Sorry! We couldn't save this bookmark because:</h4>
        <ul><li>Notes must be less than 5000 characters long.</li><li>Tag is too long</li></ul></div>
        </body></html>
        """
        XCTAssertEqual(BookmarkFormParser.saveErrors(html: html),
                       ["Notes must be less than 5000 characters long.", "Tag is too long"])
        XCTAssertEqual(BookmarkFormParser.saveErrors(html: "<html><body><div class=\"flash notice\">Bookmark was successfully updated.</div></body></html>"), [])
    }
}

/// The work page's kudos form, as AO3 renders it (`form_for(:kudo, …)` in
/// otwarchive's `comments/_commentable.html.erb`), and AO3's `/kudos.js` answers.
final class KudosParserTests: XCTestCase {
    func test_formFields_capturesTheHiddenInputs() throws {
        let html = """
        <html><body><ul class="work navigation actions">
          <li><form id="new_kudo" action="/kudos" accept-charset="UTF-8" method="post">
            <input type="hidden" name="authenticity_token" value="TOK" autocomplete="off" />
            <input value="12345" autocomplete="off" type="hidden" name="kudo[commentable_id]" id="kudo_commentable_id" />
            <input value="Work" autocomplete="off" type="hidden" name="kudo[commentable_type]" id="kudo_commentable_type" />
            <input type="submit" name="commit" value="Kudos ♥" id="kudo_submit" />
          </form></li>
        </ul></body></html>
        """
        let fields = try XCTUnwrap(KudosParser.formFields(html: html))
        XCTAssertEqual(fields["authenticity_token"], "TOK")
        XCTAssertEqual(fields["kudo[commentable_id]"], "12345")
        XCTAssertEqual(fields["kudo[commentable_type]"], "Work")
        XCTAssertNil(fields["commit"])
    }

    func test_formFields_nilWithoutTheKudosButton() {
        // Your own work, or a creator who blocked you: AO3 leaves the form out.
        XCTAssertNil(KudosParser.formFields(html: "<html><body><form id=\"new_comment\"></form></body></html>"))
        XCTAssertNil(KudosParser.formFields(html: "<form id=\"new_kudo\"><input type=\"hidden\" name=\"authenticity_token\" value=\"T\"></form>"))
    }

    func test_errorMessage_readsAO3sJSON() {
        let data = Data(#"{"error_message":"You have already left kudos here. :)"}"#.utf8)
        XCTAssertEqual(KudosParser.errorMessage(json: data), "You have already left kudos here. :)")
        XCTAssertNil(KudosParser.errorMessage(json: Data("Retry later".utf8)))
        XCTAssertNil(KudosParser.errorMessage(json: Data(#"{"error_message":"  "}"#.utf8)))
    }

    func test_isSignedIn_onlyWithTheGreeting() {
        let signedIn = """
        <html><body><header id="header">
          <nav id="greeting"><ul class="user navigation actions"><li class="dropdown">
            <a href="/users/reader">Hi, reader!</a></li></ul></nav>
        </header></body></html>
        """
        XCTAssertTrue(KudosParser.isSignedIn(html: signedIn))
        // AO3's signed-out header: the login dropdown and its small login form.
        let signedOut = """
        <html><body><header id="header">
          <div id="login" class="dropdown">
            <p class="user actions"><a id="login-dropdown" href="/users/login?return_to=%2Fworks%2F42">Log In</a></p>
            <div id="small_login" class="simple login"><form id="new_user" action="/users/login" method="post">
              <input type="text" name="user[login]" id="user_login" />
              <a href="/users/password/new">Forgot password?</a>
            </form></div>
          </div>
        </header></body></html>
        """
        XCTAssertFalse(KudosParser.isSignedIn(html: signedOut))
        XCTAssertFalse(KudosParser.isSignedIn(html: "<html><body></body></html>"))
    }

    func test_isAuthError_forARefusedToken() {
        let refused = Data(#"{"errors":{"auth_error":"Your current session has expired and we can't authenticate your request."}}"#.utf8)
        XCTAssertTrue(KudosParser.isAuthError(json: refused))
        XCTAssertNil(KudosParser.errorMessage(json: refused))
        XCTAssertFalse(KudosParser.isAuthError(json: Data(#"{"error_message":"You have already left kudos here. :)"}"#.utf8)))
    }

    func test_isAlreadyLeft_onlyForTheDuplicateAnswer() {
        XCTAssertTrue(KudosParser.isAlreadyLeft(message: "You have already left kudos here. :)"))
        XCTAssertFalse(KudosParser.isAlreadyLeft(message: "You can't leave kudos on your own work."))
        XCTAssertFalse(KudosParser.isAlreadyLeft(message: "Sorry, you have been blocked by one or more of this work's creators."))
    }
}
