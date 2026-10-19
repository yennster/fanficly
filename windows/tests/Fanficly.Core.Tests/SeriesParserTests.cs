using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Series pages and a work's "Part N of" spans (the Swift app's
/// <c>WorkMetadataParserTests</c> series cases). The markup follows otwarchive's
/// <c>series/show</c>, <c>SeriesHelper#series_data_for_work</c> and blurb views.</summary>
public class SeriesParserTests
{
    private static string Blurb(int id, string title) => $"""
        <li id="work_{id}" class="work blurb group work-{id} user-1" role="article">
          <div class="header module">
            <h4 class="heading">
              <a href="/works/{id}">{title}</a>
              by
              <a rel="author" href="/users/quillwright/pseuds/quillwright">quillwright</a>
            </h4>
            <h5 class="fandoms heading"><a class="tag" href="/tags/Original%20Work/works">Original Work</a></h5>
            <ul class="required-tags">
              <li><span class="rating-general-audience rating"><span class="text">General Audiences</span></span></li>
              <li><span class="complete-yes iswip"><span class="text">Complete Work</span></span></li>
            </ul>
            <p class="datetime">12 Mar 2024</p>
          </div>
          <dl class="stats">
            <dt class="words">Words:</dt><dd class="words">1,200</dd>
            <dt class="chapters">Chapters:</dt><dd class="chapters">1/1</dd>
          </dl>
        </li>
        """;

    private static string SeriesPage(string[] works, bool complete = false, string pagination = "") => $"""
        <html><body><div id="main" class="series-show region">
        <h2 class="heading">
          The Lighthouse Letters
        </h2>
        <h3 class="landmark heading">Series Metadata</h3>
        <div class="wrapper">
          <dl class="series meta group">
            <dt>Creator:</dt>
            <dd><a rel="author" href="/users/quillwright/pseuds/quill">quill (quillwright)</a></dd>
            <dt>Series Begun:</dt><dd>2023-01-02</dd>
            <dt>Series Updated:</dt><dd>2024-03-12</dd>
            <dt>Description:</dt>
            <dd><blockquote class="userstuff"><p>Letters from the coast.</p></blockquote></dd>
            <dt class="stats">Stats:</dt>
            <dd class="stats">
              <dl class="stats">
                <dt class="words">Words:</dt><dd class="words">3,600</dd>
                <dt class="works">Works:</dt><dd class="works">{works.Length}</dd>
                <dt>Complete:</dt><dd>{(complete ? "Yes" : "No")}</dd>
              </dl>
            </dd>
          </dl>
        </div>
        <h3 class="landmark heading">Listing Series</h3>
        {pagination}
        <ul class="series work index group">
        {string.Join("\n", works)}
        </ul>
        </div></body></html>
        """;

    [Fact]
    public void SeriesPage_SingleWork()
    {
        var series = SeriesParser.Parse(SeriesPage([Blurb(11, "First Letter")], complete: true), seriesId: 9);
        Assert.Equal(9, series.Id);
        Assert.Equal("The Lighthouse Letters", series.Title);
        Assert.Equal("quill (quillwright)", series.Creator);
        Assert.Equal("quillwright", series.CreatorUsername);
        Assert.Contains("Letters from the coast.", series.DescriptionHtml);
        Assert.Equal(1, series.WorkCount);
        Assert.True(series.IsComplete);
        Assert.Equal([11], series.Works.Select(w => w.Id));
        Assert.Equal("First Letter", series.Works[0].Title);
        Assert.Equal(1, series.CurrentPage);
        Assert.Equal(1, series.TotalPages);
    }

    [Fact]
    public void SeriesPage_SeveralWorksKeepSeriesOrder()
    {
        var html = SeriesPage(
            [Blurb(30, "Part One"), Blurb(10, "Part Two"), Blurb(20, "Part Three")],
            pagination: """
            <ol class="pagination actions" role="navigation">
              <li class="previous"><span class="disabled">← Previous</span></li>
              <li><span class="current">1</span></li>
              <li><a rel="next" href="/series/9?page=2">2</a></li>
              <li class="next"><a rel="next" href="/series/9?page=2">Next →</a></li>
            </ol>
            """);
        var series = SeriesParser.Parse(html, seriesId: 9);
        Assert.Equal([30, 10, 20], series.Works.Select(w => w.Id));
        Assert.Equal(["Part One", "Part Two", "Part Three"], series.Works.Select(w => w.Title));
        Assert.False(series.IsComplete);
        Assert.Equal(1, series.CurrentPage);
        Assert.Equal(2, series.TotalPages);
    }

    /// <summary>An unrevealed work shows AO3's "Mystery Work" blurb, with no link to
    /// open; it's dropped and the rest keep their order. (A deleted work leaves no
    /// entry at all: AO3 removes it from the series.)</summary>
    [Fact]
    public void SeriesPage_SkipsEntryWithNoWorkLink()
    {
        const string mystery = """
            <li id="work_15" class="mystery work blurb group work-15" role="article">
              <div class="mystery header picture module">
                <h4 class="heading">Mystery Work</h4>
                <h5 class="heading">Part of <a href="/collections/exchange">Exchange</a></h5>
                <div class="icon"></div>
              </div>
              <h6 class="landmark heading">Summary</h6>
              <blockquote class="userstuff summary">
                <p>This is part of an ongoing challenge and will be revealed soon!</p>
              </blockquote>
            </li>
            """;
        var series = SeriesParser.Parse(SeriesPage([Blurb(11, "One"), mystery, Blurb(12, "Three")]), seriesId: 9);
        Assert.Equal([11, 12], series.Works.Select(w => w.Id));
    }

    [Fact]
    public void SeriesPage_CoCreatorsAndNoDescription()
    {
        const string html = """
            <html><body>
            <h2 class="heading">Shared Shore</h2>
            <dl class="series meta group">
              <dt>Creators:</dt>
              <dd><a rel="author" href="/users/ana/pseuds/ana">ana</a>, <a rel="author" href="/users/bo/pseuds/bo">bo</a></dd>
              <dt class="stats">Stats:</dt>
              <dd class="stats"><dl class="stats"><dt class="works">Works:</dt><dd class="works">0</dd></dl></dd>
            </dl>
            <ul class="series work index group"></ul>
            </body></html>
            """;
        var series = SeriesParser.Parse(html, seriesId: 4);
        Assert.Equal("Shared Shore", series.Title);
        Assert.Equal("ana, bo", series.Creator);
        Assert.Equal("ana", series.CreatorUsername);
        Assert.Equal("", series.DescriptionHtml);
        Assert.Equal(0, series.WorkCount);
        Assert.Empty(series.Works);
    }

    [Fact]
    public void SeriesPage_FailsClosed()
    {
        var notSeries = Assert.Throws<AO3Exception>(() =>
            SeriesParser.Parse("<html><body><div id=\"main\" class=\"errors-404\"><h2 class=\"heading\">Error 404</h2></div></body></html>", 9));
        Assert.Equal(AO3ErrorKind.ParseFailed, notSeries.Kind);
        var login = Assert.Throws<AO3Exception>(() =>
            SeriesParser.Parse("<html><body><div id=\"main\" class=\"sessions-new\"><form action=\"/users/login\"></form></div></body></html>", 9));
        Assert.Equal(AO3ErrorKind.Unauthorized, login.Kind);
    }

    private static string WorkMeta(string series) => $"""
        <html><body>
        <dl class="work meta group">
          <dt class="rating tags">Rating:</dt>
          <dd class="rating tags"><ul class="commas"><li><a class="tag" href="/tags/General%20Audiences/works">General Audiences</a></li></ul></dd>
          {series}
          <dt class="stats">Stats:</dt>
          <dd class="stats"><dl class="stats">
            <dt class="chapters">Chapters:</dt><dd class="chapters">1/1</dd>
          </dl></dd>
        </dl>
        <div id="workskin"><div class="preface group"><h2 class="title heading">Two</h2></div>
          <div id="chapters"><div class="userstuff"><p>Text.</p></div></div>
        </div>
        </body></html>
        """;

    [Fact]
    public void WorkPage_PartOfOneSeries_WithNeighbours()
    {
        var html = WorkMeta("""
            <dt class="series">Series:</dt>
            <dd class="series">
              <span class="series"><a class="previous" href="/works/11">← Previous Work</a><span class="divider"> </span><span class="position">Part 2 of <a href="/series/9">The Lighthouse Letters</a></span><span class="divider"> </span><a class="next" href="/works/13">Next Work →</a></span>
            </dd>
            """);
        var meta = WorkMetadataParser.Parse(html, workId: 12);
        Assert.Equal([new AO3SeriesPart(9, "The Lighthouse Letters", 2, PreviousWorkId: 11, NextWorkId: 13)], meta.Series);
        var payload = WorkPageParser.Parse(html, workId: 12);
        Assert.Equal(meta.Series, payload.Summary.Series);
    }

    [Fact]
    public void WorkPage_InTwoSeries_LastPartHasNoNext()
    {
        var html = WorkMeta("""
            <dt class="series">Series:</dt>
            <dd class="series">
              <span class="series"><span class="position">Part 1 of <a href="/series/9">The Lighthouse Letters</a></span><span class="divider"> </span><a class="next" href="/works/13">Next Work →</a></span>
              <span class="series"><a class="previous" href="/works/40">← Previous Work</a><span class="divider"> </span><span class="position">Part 5 of <a href="/series/77">Coastal Year</a></span></span>
            </dd>
            """);
        var parts = WorkMetadataParser.Parse(html, workId: 12).Series;
        Assert.Equal([9, 77], parts.Select(p => p.SeriesId));
        Assert.Equal([1, 5], parts.Select(p => p.Position));
        Assert.Null(parts[0].PreviousWorkId);
        Assert.Equal(13, parts[0].NextWorkId);
        Assert.Equal(40, parts[1].PreviousWorkId);
        Assert.Null(parts[1].NextWorkId);
        Assert.Equal("Coastal Year", parts[1].Title);
    }

    /// <summary>The end-of-work "Series this work belongs to" module repeats the same
    /// spans outside the meta block; it isn't read as another series.</summary>
    [Fact]
    public void WorkPage_EndOfWorkSeriesModuleIsNotReadAgain()
    {
        const string span = """<span class="series"><span class="position">Part 1 of <a href="/series/9">The Lighthouse Letters</a></span></span>""";
        var html = WorkMeta($"""<dt class="series">Series:</dt><dd class="series">{span}</dd>""")
            .Replace("</body>", $"""<div id="series" class="series module"><h3 class="heading">Series this work belongs to:</h3><ul><li>{span}</li></ul></div></body>""", StringComparison.Ordinal);
        Assert.Single(WorkMetadataParser.Parse(html, workId: 12).Series);
        Assert.Single(WorkPageParser.Parse(html, workId: 12).Summary.Series);
    }

    [Fact]
    public void WorkPage_SameSeriesTwiceIsListedOnce()
    {
        const string span = """<span class="series"><span class="position">Part 1 of <a href="/series/9">The Lighthouse Letters</a></span></span>""";
        var html = WorkMeta($"""<dt class="series">Series:</dt><dd class="series">{span}{span}</dd>""");
        Assert.Single(WorkMetadataParser.Parse(html, workId: 12).Series);
    }

    [Fact]
    public void WorkPage_NoSeries()
    {
        var html = WorkMeta("");
        Assert.Empty(WorkMetadataParser.Parse(html, workId: 12).Series);
        Assert.Empty(WorkPageParser.Parse(html, workId: 12).Summary.Series);
    }

    [Fact]
    public void SeriesId_FromHref()
    {
        Assert.Equal(9, SeriesParser.SeriesId("/series/9"));
        Assert.Equal(123, SeriesParser.SeriesId("https://archiveofourown.org/series/123?page=2"));
        Assert.Null(SeriesParser.SeriesId("/works/9"));
    }
}
