using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>AO3's default view of a work, one chapter to a page. The markup
/// follows otwarchive's <c>chapters/show</c> and <c>chapters/_chapter</c> views.</summary>
public class WorkChapterPageTests
{
    /// <summary>Chapter <paramref name="position"/> of a three-chapter work (ids 701–703).</summary>
    internal static string ChapterPage(int position, bool headingLink = true, bool menu = true, string chapters = "3/3")
    {
        var select = menu
            ? """<select name="selected_id" id="selected_id"><option value="701">1. Arrival</option><option value="702">2. The Long Night</option><option value="703">3. Morning</option></select>"""
            : "";
        var heading = headingLink ? $"""<a href="/works/55/chapters/{700 + position}">Chapter {position}</a>""" : $"Chapter {position}";
        return $"""
            <html><body>
            <div class="work">
              <ul class="work navigation actions">
                <li class="chapter"><ul id="chapter_index" class="expandable secondary hidden"><li>
                  <form action="/works/55/chapters" method="get"><p>{select}</p></form>
                </li></ul></li>
              </ul>
              <dl class="work meta group">
                <dd class="rating tags"><ul><li><a class="tag">Teen And Up Audiences</a></li></ul></dd>
                <dd class="stats"><dl class="stats">
                  <dd class="published">2024-01-15</dd>
                  <dd class="words">9,000</dd>
                  <dd class="chapters">{chapters}</dd>
                </dl></dd>
              </dl>
              <div id="workskin">
                <div class="preface group">
                  <h2 class="title heading">Three Nights</h2>
                  <h3 class="byline heading"><a rel="author" href="/users/alice/pseuds/alice">alice</a></h3>
                  <div class="summary module"><h3 class="heading">Summary:</h3>
                    <blockquote class="userstuff"><p>A short story.</p></blockquote></div>
                </div>
                <div id="chapters">
                  <div class="chapter" id="chapter-{position}">
                    <div class="chapter preface group">
                      <h3 class="title">{heading}: Title {position}</h3>
                    </div>
                    <div class="userstuff module" role="article">
                      <h3 class="landmark heading" id="work">Chapter Text</h3>
                      <p>Text of chapter {position}.</p>
                    </div>
                  </div>
                </div>
              </div>
            </div>
            </body></html>
            """;
    }

    [Fact]
    public void NumbersTheChapterByItsPlaceInTheChapterMenu()
    {
        var page = WorkPageParser.ParseChapterPage(ChapterPage(2), workId: 55);

        var chapter = Assert.Single(page.Payload.Chapters);
        Assert.Equal(2, chapter.Index);
        Assert.Equal(702, chapter.AoId);
        Assert.Equal("Title 2", chapter.Title);
        Assert.Contains("Text of chapter 2.", chapter.BodyHtml);
        Assert.DoesNotContain("Chapter Text", chapter.BodyHtml);
        Assert.Equal([701, 702, 703], page.ChapterIds);
        Assert.False(page.IsWholeWork);
        Assert.Equal("Three Nights", page.Payload.Summary.Title);
        Assert.Equal(3, page.Payload.Summary.ChapterCount);
    }

    [Fact]
    public void FallsBackToAO3sOwnNumberingWithoutAHeadingLink()
    {
        var page = WorkPageParser.ParseChapterPage(ChapterPage(3, headingLink: false), workId: 55);

        var chapter = Assert.Single(page.Payload.Chapters);
        Assert.Equal(3, chapter.Index);
        Assert.Equal(703, chapter.AoId);
    }

    [Fact]
    public void AChapteredWorkWithoutAMenuIsNeverTakenForTheWholeWork()
    {
        // Markup drift must not turn chapter 1 of 3 into a finished one-chapter work.
        var page = WorkPageParser.ParseChapterPage(ChapterPage(1, menu: false), workId: 55);

        Assert.Single(page.Payload.Chapters);
        Assert.Empty(page.ChapterIds);
        Assert.False(page.IsWholeWork);
    }

    [Fact]
    public void AOneShotIsTheWholeWork()
    {
        const string html = """
            <html><body>
            <dl class="work meta group"><dd class="stats"><dl class="stats"><dd class="chapters">1/1</dd></dl></dd></dl>
            <div id="workskin">
              <div class="preface group"><h2 class="title heading">One Shot</h2></div>
              <div id="chapters" role="article">
                <h3 class="landmark heading" id="work">Work Text:</h3>
                <div class="userstuff"><p>All of it.</p></div>
              </div>
            </div>
            </body></html>
            """;
        var page = WorkPageParser.ParseChapterPage(html, workId: 9);

        var chapter = Assert.Single(page.Payload.Chapters);
        Assert.Equal(1, chapter.Index);
        Assert.Contains("All of it.", chapter.BodyHtml);
        Assert.True(page.IsWholeWork);
    }

    [Fact]
    public void EveryChapterOnOnePageIsTheWholeWork()
    {
        // An account set to show whole works gets them without view_full_work.
        const string html = """
            <html><body>
            <select id="selected_id"><option value="1">1. A</option><option value="2">2. B</option></select>
            <dl class="work meta group"><dd class="stats"><dl class="stats"><dd class="chapters">2/2</dd></dl></dd></dl>
            <div id="chapters" role="article">
              <div class="chapter" id="chapter-1"><div class="userstuff module"><p>One.</p></div></div>
              <div class="chapter" id="chapter-2"><div class="userstuff module"><p>Two.</p></div></div>
            </div>
            </body></html>
            """;
        var page = WorkPageParser.ParseChapterPage(html, workId: 9);

        Assert.Equal([1, 2], page.Payload.Chapters.Select(c => c.Index));
        Assert.True(page.IsWholeWork);
    }
}
