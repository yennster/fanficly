using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class SearchResultsParserTests
{
    private const string Html = """
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
    """;

    [Fact]
    public void ParsesTwoWorks()
    {
        var result = SearchResultsParser.Parse(Html);
        Assert.Equal(2, result.Works.Count);
    }

    [Fact]
    public void FirstWorkExtractsMetadata()
    {
        var work = SearchResultsParser.Parse(Html).Works[0];
        Assert.Equal(12345, work.Id);
        Assert.Equal("A Coffee Shop Tale", work.Title);
        Assert.Equal("alice", work.Author);
        Assert.Equal("alice", work.AuthorUsername);
        Assert.Equal("Mature", work.Rating);
        Assert.Equal(["Twilight"], work.Fandoms);
        Assert.Equal(["Edward Cullen/Bella Swan"], work.Relationships);
        Assert.Equal(["Edward Cullen", "Bella Swan"], work.Characters);
        Assert.Equal(["All Human", "Coffee Shop AU"], work.Freeforms);
        Assert.Equal(["No Archive Warnings Apply"], work.Warnings);
        Assert.Equal(["M/M"], work.Categories);
        Assert.True(work.IsComplete);
        Assert.Equal(45234, work.WordCount);
        Assert.Equal(1234, work.Kudos);
        Assert.Equal(23456, work.Hits);
        Assert.Equal(12, work.ChapterCount);
        Assert.Equal(12, work.TotalChapters);
        // Not asserted in the Swift suite, but worth pinning on Windows: the
        // summary is the blockquote's text and the date is local midnight.
        Assert.Equal("Bella works at a coffee shop. Edward orders too many lattes.", work.Summary);
        Assert.Equal(new DateTime(2024, 3, 12), work.UpdatedAt?.LocalDateTime);
    }

    [Fact]
    public void SecondWorkIsWIP()
    {
        var work = SearchResultsParser.Parse(Html).Works[1];
        Assert.Equal(67890, work.Id);
        Assert.Equal("A WIP", work.Title);
        Assert.Equal("Explicit", work.Rating);
        Assert.Equal(["Major Character Death"], work.Warnings);
        Assert.Equal(["F/F"], work.Categories);
        Assert.False(work.IsComplete);
        Assert.Equal(3, work.ChapterCount);
        Assert.Null(work.TotalChapters);
    }

    [Fact]
    public void PaginationCount()
    {
        var result = SearchResultsParser.Parse(Html);
        // Current page is marked by an inner `<span class="current">`, as AO3
        // renders it on real pages — the <li> has no "current" class.
        Assert.Equal(2, result.CurrentPage);
        Assert.Equal(3, result.TotalPages);
    }

    [Fact]
    public void CurrentPageFromLiClass()
    {
        // Some AO3 pages put the "current" class on the <li> itself; both forms
        // must resolve so "Load more" advances past page 2.
        const string liForm = """
        <html><body>
        <ol class="work index group"></ol>
        <ol class="pagination actions">
          <li><a href="?page=1">1</a></li>
          <li class="current">3</li>
          <li><a href="?page=4">4</a></li>
          <li><a href="?page=9">9</a></li>
        </ol>
        </body></html>
        """;
        var result = SearchResultsParser.Parse(liForm);
        Assert.Equal(3, result.CurrentPage);
        Assert.Equal(9, result.TotalPages);
    }

    [Fact]
    public void EmptyResultsDoNotCrash()
    {
        var result = SearchResultsParser.Parse("<html><body><ol class=\"work index group\"></ol></body></html>");
        Assert.Empty(result.Works);
    }

    // MARK: - Bookmarks page

    /// <summary>The bookmarks page wraps each work in `li.bookmark.blurb` and tags the
    /// &lt;li&gt; with `bookmark_&lt;id&gt;`, not `work_&lt;id&gt;`, so the work id must come from
    /// the `/works/&lt;id&gt;` title link. Series/external bookmarks (no /works/ link)
    /// must be skipped.</summary>
    private const string BookmarksHtml = """
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
    """;

    [Fact]
    public void BookmarksParseSkipsNonWorkAndReadsWorkIdFromLink()
    {
        var result = SearchResultsParser.Parse(BookmarksHtml, blurbSelector: "li.bookmark.blurb");
        // The series bookmark (no /works/ link) is skipped.
        Assert.Single(result.Works);
        var work = result.Works[0];
        Assert.Equal(98765, work.Id); // id must come from the /works/<id> link, not the bookmark_<id> li
        Assert.Equal("Bookmarked Fic", work.Title);
        Assert.Equal("carol", work.Author);
        Assert.Equal(["Harry Potter"], work.Fandoms);
        Assert.Equal(10000, work.WordCount);
        Assert.Equal(5, work.ChapterCount);
        Assert.Equal(5, work.TotalChapters);
    }

    // MARK: - Readings page (Marked for Later)

    /// <summary>Markup from AO3's readings templates (otwarchive
    /// readings/index.html.erb + _reading_blurb.html.erb), the Swift tests'
    /// fixture: each entry is `li.reading.work.blurb` with id `work_&lt;id&gt;`,
    /// wrapping the usual work blurb plus a "Last visited" module; a deleted work
    /// keeps an entry with no id and no title link. Pagination is AO3's pagy nav.</summary>
    private const string ReadingsHtml = """
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
    """;

    [Fact]
    public void ReadingsParseListsWorksAndSkipsDeleted()
    {
        var result = SearchResultsParser.ParseReadings(ReadingsHtml);
        var work = Assert.Single(result.Works); // the deleted entry has no work and is skipped
        Assert.Equal(4242, work.Id);
        Assert.Equal("Saved For Later", work.Title);
        Assert.Equal("erin", work.Author);
        Assert.Equal("erin", work.AuthorUsername);
        Assert.Equal(["Good Omens"], work.Fandoms);
        Assert.Equal(2500, work.WordCount);
        Assert.Equal(2, work.ChapterCount);
        Assert.Null(work.TotalChapters);
        Assert.Equal(2, result.CurrentPage);
        Assert.Equal(3, result.TotalPages);
    }

    [Fact]
    public void ReadingsParseEmptyList()
    {
        // AO3 renders no list and no pagination when nothing is marked.
        const string empty = """
        <html><body><div id="main" class="readings-index dashboard region" role="main">
        <h2 class="heading">Marked for Later</h2>
        <h3 class="landmark heading">List of Marked for Later Items</h3>
        </div></body></html>
        """;
        var result = SearchResultsParser.ParseReadings(empty);
        Assert.Empty(result.Works);
        Assert.Equal(1, result.TotalPages);
    }

    [Fact]
    public void ReadingsParseLoginPageFailsClosed()
    {
        // An expired session: AO3 redirects to the login form, served as a 200.
        const string login = """
        <html><body><div id="main" class="user_sessions-new region">
        <form id="new_user_session_small" action="/users/login" method="post">
          <input name="user[login]"><input name="user[password]" type="password">
        </form></div></body></html>
        """;
        var e = Assert.Throws<AO3Exception>(() => SearchResultsParser.ParseReadings(login));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
    }

    [Fact]
    public void ReadingsParseOtherPageFailsClosed()
    {
        // History turned off: AO3 redirects to the preferences page.
        var prefs = Assert.Throws<AO3Exception>(() => SearchResultsParser.ParseReadings(
            "<html><body><div id=\"main\" class=\"preferences-index dashboard region\"></div></body></html>"));
        Assert.Equal(AO3ErrorKind.ParseFailed, prefs.Kind);
        Assert.Contains("Turn on History", prefs.Reason);
        // Anything else (markup drift, an error page) is never an empty list.
        var other = Assert.Throws<AO3Exception>(() => SearchResultsParser.ParseReadings("<html><body><p>Oops</p></body></html>"));
        Assert.Equal(AO3ErrorKind.ParseFailed, other.Kind);
    }

    [Fact]
    public void WorkIdFromHref()
    {
        Assert.Equal(12345, SearchResultsParser.WorkId("/works/12345"));
        Assert.Equal(12345, SearchResultsParser.WorkId("/works/12345/chapters/678"));
        Assert.Null(SearchResultsParser.WorkId("/series/4242"));
        Assert.Null(SearchResultsParser.WorkId(""));
    }

    // Failing closed (RM-001)

    [Fact]
    public void EmptySearchReturnsNoWorks()
    {
        var html = AO3PageFixtures.GuestPage("works-search", """
            <h2 class="heading">Search Results</h2>
            <p>No results found. You may want to edit your search to make it less specific.</p>
            """);
        Assert.Empty(SearchResultsParser.Parse(html).Works);
    }

    [Fact]
    public void EmptyAuthorWorksReturnsNoWorks()
    {
        var html = AO3PageFixtures.GuestPage("works-index dashboard", """
            <h2 class="heading">0 Works by alice</h2>
            <h3 class="landmark heading">Listing Works</h3>
            <ol class="work index group"></ol>
            """);
        Assert.Empty(SearchResultsParser.Parse(html).Works);
    }

    [Fact]
    public void EmptyBookmarksReturnNoWorks()
    {
        var html = AO3PageFixtures.GuestPage("bookmarks-index dashboard", """
            <h2 class="heading">0 Bookmarks by alice</h2>
            <ol class="bookmark index group"></ol>
            """);
        Assert.Empty(SearchResultsParser.Parse(html, "li.bookmark.blurb").Works);
    }

    /// <summary>Every guest page has the header's login form; it must not read as
    /// the login page.</summary>
    [Fact]
    public void GuestResultsPageStillParses()
    {
        var html = AO3PageFixtures.GuestPage("works-search", """
            <ol class="work index group">
              <li id="work_12345" class="work blurb group" role="article">
                <div class="header module"><h4 class="heading"><a href="/works/12345">A Coffee Shop Tale</a></h4></div>
              </li>
            </ol>
            """);
        Assert.Equal([12345], SearchResultsParser.Parse(html).Works.Select(w => w.Id));
    }

    [Theory]
    [InlineData("li.work.blurb")]
    [InlineData("li.bookmark.blurb")]
    public void LoginPageThrowsUnauthorized(string selector)
    {
        var e = Assert.Throws<AO3Exception>(() => SearchResultsParser.Parse(AO3PageFixtures.LoginPage, selector));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
    }

    public static TheoryData<string> GarbagePages =>
        [AO3PageFixtures.ErrorPage, AO3PageFixtures.ForeignPage, "<html><body></body></html>"];

    [Theory]
    [MemberData(nameof(GarbagePages))]
    public void GarbagePageThrowsParseFailed(string html)
    {
        var e = Assert.Throws<AO3Exception>(() => SearchResultsParser.Parse(html));
        Assert.Equal(AO3ErrorKind.ParseFailed, e.Kind);
    }
}

/// <summary>Page shells for the fail-closed parser tests, cut down from otwarchive's
/// own templates (<c>layouts/application</c>, <c>users/sessions/new</c>,
/// <c>public/502.html</c>). AO3 sets <c>#main</c>'s class to the Rails
/// <c>controller-action</c>. The Swift tests use the same shells.</summary>
internal static class AO3PageFixtures
{
    /// <summary>The header every logged-out page carries, small login form included.</summary>
    public const string GuestHeader = """
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
        """;

    public static string GuestPage(string mainClass, string body) => $"""
        <html><body><div id="outer" class="wrapper">
        {GuestHeader}
        <div id="inner" class="wrapper">
          <div id="main" class="{mainClass} region" role="main">
          {body}
          </div>
        </div>
        </div></body></html>
        """;

    /// <summary>Where AO3 sends a stale session or a guest opening a restricted work.</summary>
    public static readonly string LoginPage = GuestPage("sessions-new system session", """
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
        """);

    /// <summary>AO3's static 502 page.</summary>
    public static readonly string ErrorPage = GuestPage("system errors error-502", """
        <h2 class="heading">Error 502</h2>
        <p>The page was responding too slowly.</p>
        """);

    /// <summary>Not AO3 at all: a captive portal or a proxy's block page.</summary>
    public const string ForeignPage = """
        <html><head><title>Sign in to Wi-Fi</title></head>
        <body><h1>Welcome</h1><a href="/tags/accept/works">Accept and continue</a></body></html>
        """;
}
