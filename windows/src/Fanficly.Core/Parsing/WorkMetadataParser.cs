namespace Fanficly.Core;

/// <summary>Reads just the chapter count and last-update date from a work page —
/// what the subscription poller needs to spot new chapters.</summary>
public static class WorkMetadataParser
{
    public static AO3WorkMetadata Parse(string html, int workId)
    {
        var doc = HtmlDom.Parse(html);
        var stats = doc.SelectFirst("dl.stats");
        var (current, total) = HtmlDom.ParseChapterFraction(stats?.SelectFirst("dd.chapters")?.Text() ?? "1/1");
        var updatedAt = HtmlDom.ParseDate(stats?.SelectFirst("dd.status")?.Text() ?? "", "yyyy-MM-dd");
        return new AO3WorkMetadata(workId, current, total, updatedAt);
    }
}
