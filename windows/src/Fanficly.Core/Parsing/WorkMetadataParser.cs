namespace Fanficly.Core;

/// <summary>Reads just the chapter count and last-update date from a work page —
/// what the subscription poller needs to spot new chapters.</summary>
public static class WorkMetadataParser
{
    /// <summary>Null when the page has no chapter count: a login, error or
    /// Cloudflare page. Reading those as "1/1" would reset a work's new-chapter
    /// baseline and send a false alert on the next real check.</summary>
    public static AO3WorkMetadata? TryParse(string html, int workId) =>
        HtmlDom.Parse(html).SelectFirst("dl.stats dd.chapters") is null ? null : Parse(html, workId);

    public static AO3WorkMetadata Parse(string html, int workId)
    {
        var doc = HtmlDom.Parse(html);
        var stats = doc.SelectFirst("dl.stats");
        var (current, total) = HtmlDom.ParseChapterFraction(stats?.SelectFirst("dd.chapters")?.Text() ?? "1/1");
        var updatedAt = HtmlDom.ParseDate(stats?.SelectFirst("dd.status")?.Text() ?? "", "yyyy-MM-dd");
        return new AO3WorkMetadata(workId, current, total, updatedAt);
    }
}
