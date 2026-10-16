using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class WorkMetadataParserTests
{
    [Fact]
    public void ParsesChapterCountAndStatus()
    {
        const string html = """
        <html><body>
        <dl class="stats">
          <dt class="chapters">Chapters:</dt><dd class="chapters">12/20</dd>
          <dt class="status">Updated:</dt><dd class="status">2024-03-12</dd>
        </dl>
        </body></html>
        """;
        var meta = WorkMetadataParser.Parse(html, workId: 5);
        Assert.Equal(5, meta.Id);
        Assert.Equal(12, meta.ChapterCount);
        Assert.Equal(20, meta.TotalChapters);
        Assert.NotNull(meta.UpdatedAt);
    }

    [Fact]
    public void WipWithUnknownTotal()
    {
        const string html = """
        <html><body><dl class="stats">
          <dt class="chapters">Chapters:</dt><dd class="chapters">3/?</dd>
        </dl></body></html>
        """;
        var meta = WorkMetadataParser.Parse(html, workId: 1);
        Assert.Equal(3, meta.ChapterCount);
        Assert.Null(meta.TotalChapters);
    }

    [Fact]
    public void MissingStatsDefaults()
    {
        var meta = WorkMetadataParser.Parse("<html></html>", workId: 2);
        Assert.Equal(1, meta.ChapterCount);
    }
}
