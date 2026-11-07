using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Find in this work (#183): on-device search of the loaded chapters
/// (Swift: <c>WorkFindTests</c>).</summary>
public class WorkFindTests
{
    private static WorkFind.Chapter Chapter(int index, params string[] paragraphs) => new(index, "", paragraphs);

    private static string Highlighted(WorkFind.Match match) =>
        match.Snippet.Substring(match.HighlightStart, match.HighlightLength);

    [Fact]
    public void EmptyQueryFindsNothing()
    {
        var chapters = new[] { Chapter(1, "The ring was gold.") };
        Assert.Empty(WorkFind.Search("", chapters).Matches);
        Assert.Empty(WorkFind.Search("   ", chapters).Matches);
        Assert.Empty(WorkFind.Search(null, chapters).Matches);
    }

    [Fact]
    public void FindsParagraphsInReadingOrder_WithTheirChapterAndIndex()
    {
        var chapters = new[]
        {
            Chapter(2, "Nothing here.", "She took off the ring."),
            Chapter(1, "The Ring was gold.", "No match.", "A ring, another ring."),
        };
        var result = WorkFind.Search("ring", chapters);
        Assert.Equal(
            [new ReadingAnchor(1, 0), new ReadingAnchor(1, 2), new ReadingAnchor(2, 1)],
            result.Matches.Select(m => m.Anchor).ToArray());
        Assert.Equal([1, 2, 1], result.Matches.Select(m => m.Count).ToArray());
        Assert.Equal(4, result.Total);
        Assert.False(result.Truncated);
    }

    [Fact]
    public void IgnoresCaseAccentsAndCurlyQuotes()
    {
        var chapters = new[] { Chapter(1, "“Don’t,” said Zoë.", "Plain text.") };
        Assert.Single(WorkFind.Search("don't", chapters).Matches);
        Assert.Single(WorkFind.Search("\"Don't,\"", chapters).Matches);
        Assert.Single(WorkFind.Search("ZOE", chapters).Matches);
        Assert.Single(WorkFind.Search("  zoë  ", chapters).Matches);
    }

    [Fact]
    public void SkipsEmptySlots()
    {
        // Image slots and scene breaks are "" in SpeechParagraphs; they keep their index.
        var chapters = new[] { Chapter(1, "", "a ring") };
        Assert.Equal([1], WorkFind.Search("ring", chapters).Matches.Select(m => m.Paragraph).ToArray());
    }

    [Fact]
    public void LimitListsTheFirstParagraphs_ButCountsEveryMatch()
    {
        var chapters = new[] { Chapter(1, Enumerable.Repeat("ring ring", 10).ToArray()) };
        var result = WorkFind.Search("ring", chapters, limit: 3);
        Assert.Equal([0, 1, 2], result.Matches.Select(m => m.Paragraph).ToArray());
        Assert.True(result.Truncated);
        Assert.Equal(20, result.Total);
    }

    [Fact]
    public void SnippetHighlightsTheMatch()
    {
        const string text = "“Don’t,” she said.";
        var match = Assert.Single(WorkFind.Search("don't", [Chapter(1, text)]).Matches);
        Assert.Equal(text, match.Snippet);
        Assert.Equal("Don’t", Highlighted(match));
    }

    [Fact]
    public void LongParagraphSnippetStartsAtAWordAndMarksCuts()
    {
        var before = string.Concat(Enumerable.Repeat("lorem ipsum dolor ", 10));
        var after = string.Concat(Enumerable.Repeat(" sit amet consectetur", 20));
        var match = Assert.Single(WorkFind.Search("ring", [Chapter(1, before + "the ring" + after)]).Matches);
        Assert.StartsWith("…", match.Snippet);
        Assert.EndsWith("…", match.Snippet);
        Assert.False(match.Snippet[1..].StartsWith(' '));
        Assert.Contains(match.Snippet[1..].Split(' ')[0], new[] { "lorem", "ipsum", "dolor" });
        Assert.Equal("ring", Highlighted(match));
        Assert.True(match.Snippet.Length <= WorkFind.SnippetLength + 2);
    }

    [Fact]
    public void ParagraphsMatchTheReadersOwn()
    {
        // The reader's paragraph indices: SpeechParagraphs is index-aligned with
        // the rendered paragraphs every mode anchors to.
        const string html = "<p>First.</p><p>The ring.</p><p>Last.</p>";
        var chapters = WorkFind.Chapters([new AO3ChapterPayload(1, "", html, null)], includeImages: false);
        Assert.Equal([1], WorkFind.Search("ring", chapters).Matches.Select(m => m.Paragraph).ToArray());
        Assert.Equal(HTMLToAttributed.ConvertParagraphs(html).Count, chapters[0].Paragraphs.Count);
    }

    [Fact]
    public void ChapterLabel()
    {
        Assert.Equal("Chapter 3", WorkFind.ChapterLabel(3, ""));
        Assert.Equal("Chapter 3: The Ring", WorkFind.ChapterLabel(3, "The Ring"));
    }
}
