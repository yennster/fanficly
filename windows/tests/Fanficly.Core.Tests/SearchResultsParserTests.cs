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

    [Fact]
    public void WorkIdFromHref()
    {
        Assert.Equal(12345, SearchResultsParser.WorkId("/works/12345"));
        Assert.Equal(12345, SearchResultsParser.WorkId("/works/12345/chapters/678"));
        Assert.Null(SearchResultsParser.WorkId("/series/4242"));
        Assert.Null(SearchResultsParser.WorkId(""));
    }
}
