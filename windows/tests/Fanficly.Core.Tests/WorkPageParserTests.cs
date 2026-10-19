using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class WorkPageParserTests
{
    private const string Html = """
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
    """;

    [Fact]
    public void ExtractsTitleAndAuthor()
    {
        var payload = WorkPageParser.Parse(Html, workId: 12345);
        Assert.Equal("A Coffee Shop Tale", payload.Summary.Title);
        Assert.Equal("alice", payload.Summary.Author);
    }

    [Fact]
    public void ExtractsMetadata()
    {
        var s = WorkPageParser.Parse(Html, workId: 12345).Summary;
        Assert.Equal("Mature", s.Rating);
        Assert.Equal(["No Archive Warnings Apply"], s.Warnings);
        Assert.Equal(["M/M"], s.Categories);
        Assert.Equal(["Edward Cullen/Bella Swan"], s.Relationships);
        Assert.Equal(["Edward Cullen", "Bella Swan"], s.Characters);
        Assert.Equal(["All Human", "Slow Burn"], s.Freeforms);
        Assert.Equal(["Twilight"], s.Fandoms);
        Assert.Equal(45234, s.WordCount);
        Assert.Equal(1234, s.Kudos);
        Assert.Equal(23456, s.Hits);
        Assert.Equal(2, s.ChapterCount);
        Assert.Equal(2, s.TotalChapters);
        Assert.True(s.IsComplete);
        // Windows-only extras: the summary keeps its markup, the update date wins
        // over the publish date, and the author's login is read from the byline.
        Assert.Equal("<p>Bella works at a coffee shop.</p>", s.Summary);
        Assert.Equal(new DateTime(2024, 3, 12), s.UpdatedAt?.LocalDateTime);
        Assert.Equal("alice", s.AuthorUsername);
    }

    [Fact]
    public void CleanChapterTitle_StripsAO3Prefix()
    {
        Assert.Equal("The Real Title", WorkPageParser.CleanChapterTitle("Chapter 1: The Real Title", index: 1));
        Assert.Equal("", WorkPageParser.CleanChapterTitle("Chapter 6: Chapter 6", index: 6));
        Assert.Equal("", WorkPageParser.CleanChapterTitle("Chapter 3", index: 3));
        Assert.Equal("A Standalone Title", WorkPageParser.CleanChapterTitle("A Standalone Title", index: 2));
        Assert.Equal("", WorkPageParser.CleanChapterTitle("Chapter 10: Chapter 10", index: 10));
    }

    [Fact]
    public void LandmarkChapterTextStripped()
    {
        const string html = """
        <html><body><div id="workskin">
        <div class="chapter" id="chapter-1">
          <div class="chapter preface group"><h3 class="title">Chapter 1</h3></div>
          <h3 class="landmark heading">Chapter Text</h3>
          <div class="userstuff module"><p>The actual story begins.</p></div>
        </div>
        </div></body></html>
        """;
        var payload = WorkPageParser.Parse(html, workId: 5);
        Assert.Single(payload.Chapters);
        Assert.Equal("", payload.Chapters[0].Title);
        Assert.DoesNotContain("Chapter Text", payload.Chapters[0].BodyHtml);
        Assert.Contains("The actual story begins.", payload.Chapters[0].BodyHtml);
    }

    [Fact]
    public void ExtractsChapters()
    {
        var payload = WorkPageParser.Parse(Html, workId: 12345);
        Assert.Equal(2, payload.Chapters.Count);
        // AO3's "Chapter N: " prefix is stripped; only the custom title remains.
        Assert.Equal("Latte", payload.Chapters[0].Title);
        Assert.Contains("Bella poured", payload.Chapters[0].BodyHtml);
        Assert.Contains("<em>It was hot.</em>", payload.Chapters[0].BodyHtml);
        Assert.Equal("Espresso", payload.Chapters[1].Title);
    }

    [Fact]
    public void ChapterId_FromHref()
    {
        Assert.Equal(678, WorkPageParser.ChapterId("/works/12345/chapters/678"));
        Assert.Equal(42, WorkPageParser.ChapterId("https://archiveofourown.org/works/9/chapters/42?view_adult=true"));
        Assert.Null(WorkPageParser.ChapterId("/works/12345"));
        Assert.Null(WorkPageParser.ChapterId("/users/alice"));
    }

    [Fact]
    public void ExtractsChapterIds_FromHeadingLinks()
    {
        const string html = """
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
        """;
        var payload = WorkPageParser.Parse(html, workId: 12345);
        Assert.Equal(2, payload.Chapters.Count);
        Assert.Equal(678, payload.Chapters[0].AoId);
        Assert.Equal(690, payload.Chapters[1].AoId);
    }

    [Fact]
    public void ExtractsChapterIds_FromSelectFallback()
    {
        // No per-chapter heading links → fall back to the chapter jump menu.
        const string html = """
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
        """;
        var payload = WorkPageParser.Parse(html, workId: 12345);
        Assert.Equal(678, payload.Chapters[0].AoId);
        Assert.Equal(690, payload.Chapters[1].AoId);
    }

    [Fact]
    public void ChapterId_NilWhenAbsent()
    {
        // The base fixture's chapters have no links/selector → no ids (callers
        // then fall back to work-level comments).
        var payload = WorkPageParser.Parse(Html, workId: 12345);
        Assert.Null(payload.Chapters[0].AoId);
    }

    // Failing closed (RM-001)

    /// <summary>A real work page whose only chapter has no text still parses: the
    /// guest header's login form doesn't make it the login page.</summary>
    [Fact]
    public void GuestWorkPageWithEmptyChapterParses()
    {
        var html = AO3PageFixtures.GuestPage("works-show", """
            <div class="wrapper"><dl class="work meta group">
              <dt class="rating tags">Rating:</dt><dd class="rating tags"><ul class="commas"><li><a class="tag" href="/tags/General%20Audiences/works">General Audiences</a></li></ul></dd>
            </dl></div>
            <div id="workskin">
              <div class="preface group"><h2 class="title heading">Blank Page</h2></div>
              <div id="chapters" role="article"><div class="userstuff"></div></div>
            </div>
            """);
        var payload = WorkPageParser.Parse(html, 7);
        Assert.Equal("Blank Page", payload.Summary.Title);
        Assert.Equal("General Audiences", payload.Summary.Rating);
    }

    [Fact]
    public void RestrictedWorkLoginPageThrowsUnauthorized()
    {
        var e = Assert.Throws<AO3Exception>(() => WorkPageParser.Parse(AO3PageFixtures.LoginPage, 7));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
        e = Assert.Throws<AO3Exception>(() => WorkPageParser.ParseChapterPage(AO3PageFixtures.LoginPage, 7));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
    }

    public static TheoryData<string> GarbagePages =>
    [
        AO3PageFixtures.ErrorPage,
        AO3PageFixtures.ForeignPage,
        AO3PageFixtures.GuestPage("works-show", """
            <p class="caution notice">This work could have adult content. If you continue, you have agreed that you are willing to see such content.</p>
            <ul class="actions"><li><a href="/works/7?view_adult=true">Yes, Continue</a></li></ul>
            """),
    ];

    /// <summary>Anything without the work's markup (an error page, a foreign page,
    /// the adult gate) would otherwise parse to an untitled work with no chapters
    /// and overwrite a saved copy.</summary>
    [Theory]
    [MemberData(nameof(GarbagePages))]
    public void GarbagePageThrowsParseFailed(string html)
    {
        var e = Assert.Throws<AO3Exception>(() => WorkPageParser.Parse(html, 7));
        Assert.Equal(AO3ErrorKind.ParseFailed, e.Kind);
        e = Assert.Throws<AO3Exception>(() => WorkPageParser.ParseChapterPage(html, 7));
        Assert.Equal(AO3ErrorKind.ParseFailed, e.Kind);
    }
}

public class CommentsParserTests
{
    private const string Html = """
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
    """;

    [Fact]
    public void ParsesThreadWithDepth()
    {
        var comments = CommentsParser.Parse(Html);
        Assert.Equal(3, comments.Count);

        Assert.Equal("111", comments[0].Id);
        Assert.Equal("alice", comments[0].CommenterName);
        Assert.Equal("alice", comments[0].CommenterUsername);
        Assert.Equal(0, comments[0].Depth);
        Assert.Contains("Loved this chapter", comments[0].BodyHtml);

        // Nested reply is one level deep.
        Assert.Equal("222", comments[1].Id);
        Assert.Equal(1, comments[1].Depth);

        // Guest comment has no username.
        Assert.Equal("GuestReader (Guest)", comments[2].CommenterName);
        Assert.Equal("", comments[2].CommenterUsername);
        Assert.Equal(0, comments[2].Depth);
    }

    [Fact]
    public void ReplyDepth_Ao3WrapperStructure()
    {
        // AO3's real markup: the reply's <li.comment> is NOT inside its parent's.
        // It sits in a further <ol class="thread"> within an *unclassed* wrapper
        // <li> that is a sibling of the parent. Depth must come from ancestor
        // threads, not ancestor comment <li>s (which would give the reply 0).
        const string html = """
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
        """;
        var comments = CommentsParser.Parse(html);
        Assert.Equal(2, comments.Count);
        Assert.Equal("1", comments[0].Id);
        Assert.Equal(0, comments[0].Depth);
        Assert.Equal("2", comments[1].Id);
        Assert.Equal(1, comments[1].Depth);
    }

    [Fact]
    public void ParsesCommentsDespitePrecedingEmptyWrapper()
    {
        // Mirrors real AO3: an empty <div id="comments"> precedes
        // #comments_placeholder, which holds pagination <li>s + the real
        // comments. The old container-scoped parser locked onto the empty
        // wrapper and returned nothing; pagination <li>s must also be ignored.
        const string html = """
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
        """;
        var comments = CommentsParser.Parse(html);
        Assert.Single(comments);
        Assert.Equal("999", comments[0].Id);
        Assert.Equal("zed", comments[0].CommenterName);
        Assert.Equal(0, comments[0].Depth);
        Assert.Contains("Great chapter", comments[0].BodyHtml);
    }

    /// <summary>AO3's comment pagination (will_paginate's list renderer): an
    /// <c>ol.pagination.actions</c> above and below the thread in
    /// <c>#comments_placeholder</c>, the current page as <c>&lt;span class="current"&gt;</c>.</summary>
    private static string PagedHtml(int current, int total)
    {
        var pages = string.Concat(Enumerable.Range(1, total).Select(n => n == current
            ? $"<li><span class=\"current\">{n}</span></li>"
            : $"<li><a href=\"/works/1/chapters/2?page={n}&amp;show_comments=true#comments\">{n}</a></li>"));
        var nav = $"""
            <h4 class="landmark heading">Pages Navigation</h4>
            <ol class="pagination actions" role="navigation" title="pagination">
              <li class="previous" title="previous"><span class="disabled">← Previous</span></li>
              {pages}
              <li class="next" title="next"><a rel="next" href="/works/1/chapters/2?page=2&amp;show_comments=true#comments">Next →</a></li>
            </ol>
            """;
        return $"""
            <html><body>
            <div id="comments" class="comments"></div>
            <div id="comments_placeholder">
              {nav}
              <ol class="thread">
                <li class="odd comment group" id="comment_{current}00" role="article">
                  <h4 class="heading byline"><a href="/users/zed/pseuds/zed">zed</a></h4>
                  <blockquote class="userstuff"><p>Page {current}.</p></blockquote>
                </li>
              </ol>
              {nav}
            </div>
            </body></html>
            """;
    }

    [Fact]
    public void ParsePage_ReadsCommentPagination()
    {
        var page = CommentsParser.ParsePage(PagedHtml(2, 4));
        Assert.Equal(2, page.CurrentPage);
        Assert.Equal(4, page.TotalPages);
        Assert.True(page.HasMore);
        Assert.Equal(new[] { "200" }, page.Comments.Select(c => c.Id));

        var last = CommentsParser.ParsePage(PagedHtml(4, 4));
        Assert.Equal(4, last.CurrentPage);
        Assert.False(last.HasMore);
    }

    [Fact]
    public void ParsePage_SinglePageHasNoMore()
    {
        // A one-shot (or a short thread) has no pagination list at all.
        var page = CommentsParser.ParsePage(Html);
        Assert.Equal(3, page.Comments.Count);
        Assert.Equal(1, page.CurrentPage);
        Assert.Equal(1, page.TotalPages);
        Assert.False(page.HasMore);
    }

    [Fact]
    public void ParsePage_IgnoresPaginationOutsideTheThread()
    {
        const string html = """
            <html><body>
            <ol class="pagination actions"><li><span class="current">1</span></li><li><a href="#">9</a></li></ol>
            <div id="comments_placeholder"><ol class="thread">
              <li class="comment group" id="comment_1"><blockquote class="userstuff"><p>Hi</p></blockquote></li>
            </ol></div>
            </body></html>
            """;
        var page = CommentsParser.ParsePage(html);
        Assert.Equal(1, page.TotalPages);
        Assert.False(page.HasMore);
    }

    [Fact]
    public void DefaultPseudId()
    {
        const string formHtml = """
        <form><select name="comment[pseud_id]">
          <option value="10">main</option>
          <option value="20" selected>writing_pseud</option>
        </select></form>
        """;
        Assert.Equal("20", CommentsParser.DefaultPseudId(formHtml));
        Assert.Null(CommentsParser.DefaultPseudId("<html></html>"));
    }

    [Fact]
    public void NewCommentForm_CapturesActionAndFields()
    {
        // A nested reply form (inside an existing comment) plus the page-level
        // composer; we must pick the composer and capture its action + fields.
        const string html = """
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
        """;
        var form = CommentsParser.NewCommentForm(html, new Uri("https://archiveofourown.org"));
        Assert.NotNull(form);
        Assert.Equal("https://archiveofourown.org/works/12345/chapters/678/comments", form.Action.AbsoluteUri);
        Assert.Equal("TOK123", form.Fields["authenticity_token"]);
        Assert.Equal("678", form.Fields["comment[commentable_id]"]);
        Assert.Equal("Chapter", form.Fields["comment[commentable_type]"]);
        Assert.Equal("20", form.Fields["comment[pseud_id]"]);
    }

    [Fact]
    public void NewCommentForm_NilWhenNoComposer()
    {
        Assert.Null(CommentsParser.NewCommentForm("<html><body><p>no form</p></body></html>",
            new Uri("https://archiveofourown.org")));
    }
}

public class LoginParserTests
{
    [Fact]
    public void ExtractsTokenFromMeta()
    {
        const string html = """
        <html><head><meta name="csrf-token" content="abc123token"/></head><body></body></html>
        """;
        Assert.Equal("abc123token", LoginParser.AuthenticityToken(html));
    }

    [Fact]
    public void ExtractsTokenFromForm()
    {
        const string html = """
        <html><body>
        <form action="/users/login" method="post">
          <input name="authenticity_token" type="hidden" value="formtoken456"/>
          <input name="user[login]"/>
          <input name="user[password]"/>
        </form>
        </body></html>
        """;
        Assert.Equal("formtoken456", LoginParser.AuthenticityToken(html));
    }

    [Fact]
    public void DetectsLoginFailure()
    {
        const string html = """
        <html><body>
        <div id="flash_error">The password or username you entered doesn't match our records.</div>
        </body></html>
        """;
        var msg = LoginParser.DetectLoginFailure(html);
        Assert.NotNull(msg);
        Assert.Contains("password", msg);
    }

    [Fact]
    public void ExtractsCurrentUsername()
    {
        const string html = """
        <html><body>
        <ul id="user-navigation">
          <li><a href="/users/alice">My Dashboard</a></li>
        </ul>
        </body></html>
        """;
        Assert.Equal("alice", LoginParser.CurrentUsername(html));
    }

    [Fact]
    public void NoUsernameWhenLoggedOut()
    {
        Assert.Null(LoginParser.CurrentUsername("<html><body><ul id=\"user-navigation\"></ul></body></html>"));
    }

    [Fact]
    public void UsernameFromGreetingDropdown()
    {
        const string html = """
        <html><body>
        <div id="greeting"><ul class="user navigation actions">
          <li class="dropdown"><a class="dropdown-toggle" href="/users/yennster">yennster</a></li>
          <li><a href="/users/logout">Log Out</a></li>
        </ul></div>
        </body></html>
        """;
        Assert.Equal("yennster", LoginParser.CurrentUsername(html));
    }

    [Fact]
    public void CurrentUsernameSkipsActionLinks()
    {
        // A logged-out page links to /users/login — must not be read as a name.
        Assert.Null(LoginParser.CurrentUsername("<html><body><div id=\"header\"><a href=\"/users/login\">Log In</a></div></body></html>"));
    }

    [Fact]
    public void HasLoginForm()
    {
        Assert.True(LoginParser.HasLoginForm("<html><body><form id=\"new_user\"><input name=\"user[login]\"></form></body></html>"));
        Assert.False(LoginParser.HasLoginForm("<html><body><div id=\"greeting\">Hi!</div></body></html>"));
    }
}
