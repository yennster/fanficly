using System.Text.RegularExpressions;
using AngleSharp.Dom;

namespace Fanficly.Core;

/// <summary>Reads series from AO3: the "Part 2 of &lt;series&gt;" line on a work page,
/// and a series page (<c>/series/&lt;id&gt;</c>). Ports the Swift <c>SeriesParser</c>.</summary>
public static partial class SeriesParser
{
    /// <summary>A work's series from its meta block. Each series is one
    /// <c>&lt;span class="series"&gt;</c>: an optional <c>a.previous</c>, then
    /// <c>&lt;span class="position"&gt;Part 2 of &lt;a href="/series/9"&gt;Title&lt;/a&gt;&lt;/span&gt;</c>,
    /// then an optional <c>a.next</c>. A work in two series has two spans. Each series
    /// is kept once; the end-of-work series module (<c>div#series</c>), which repeats
    /// the spans, sits outside <c>dd.series</c> and isn't read.</summary>
    public static IReadOnlyList<AO3SeriesPart> Parts(IDocument doc)
    {
        var seen = new HashSet<int>();
        var parts = new List<AO3SeriesPart>();
        foreach (var span in doc.Select("dl.work.meta dd.series span.series, dd.series span.series"))
        {
            if (span.SelectFirst("span.position a[href*='/series/']") is not { } link
                || SeriesId(link.Attr("href")) is not { } seriesId
                || !seen.Add(seriesId)) continue;
            var positionText = span.SelectFirst("span.position")?.Text() ?? "";
            var digits = FirstNumber().Match(positionText);
            var position = digits.Success ? HtmlDom.ParseSwiftInt(digits.Value) ?? 1 : 1;
            parts.Add(new AO3SeriesPart(
                seriesId,
                link.Text().TrimSwiftWhitespaces(),
                position,
                NeighbourId(span, "a.previous"),
                NeighbourId(span, "a.next")));
        }
        return parts;
    }

    /// <summary>A series page: <c>h2.heading</c> title, a <c>dl.series.meta</c> of dt/dd
    /// pairs (Creator(s), Description, Stats with Works and Complete), then the works
    /// as ordinary blurbs in <c>ul.series.work.index</c>, paginated like search.</summary>
    /// <exception cref="AO3Exception">Unauthorized for the login page; ParseFailed for
    /// any page that isn't a series page.</exception>
    public static AO3Series Parse(string html, int seriesId)
    {
        var doc = HtmlDom.Parse(html);
        AO3PageCheck.RejectLoginPage(doc);
        // An error page or markup drift must not read as an empty series.
        if (doc.SelectFirst("dl.series.meta") is null && !AO3PageCheck.MainHasClass(doc, "series-show"))
            throw AO3Exception.ParseFailed("Not a series page");

        var title = (doc.SelectFirst("#main h2.heading") ?? doc.SelectFirst("h2.heading"))?.Text().TrimSwiftWhitespaces() ?? "";

        var creator = "";
        var creatorUsername = "";
        var descriptionHtml = "";
        var isComplete = false;
        if (doc.SelectFirst("dl.series.meta") is { } dl)
        {
            foreach (var dt in dl.Select("dt"))
            {
                if (dt.NextElementSibling is not { LocalName: "dd" } dd) continue;
                switch (dt.Text().TrimSwiftWhitespaces().ToLowerInvariant())
                {
                    case "creator:":
                    case "creators:":
                        var anchors = dd.Select("a[rel='author']");
                        if (anchors.Count == 0)
                        {
                            creator = dd.Text().TrimSwiftWhitespaces();
                        }
                        else
                        {
                            creator = string.Join(", ", anchors.Select(a => a.Text()));
                            creatorUsername = SearchResultsParser.AuthorLogin(anchors[0].Attr("href"));
                        }
                        break;
                    case "description:":
                        descriptionHtml = dd.SelectFirst("blockquote.userstuff").InnerHtml();
                        break;
                    case "complete:":
                        isComplete = dd.Text().TrimSwiftWhitespaces().Equals("yes", StringComparison.OrdinalIgnoreCase);
                        break;
                }
            }
        }
        var worksText = doc.SelectFirst("dl.series.meta dd.works")?.Text() ?? "";
        var workCount = HtmlDom.ParseSwiftInt(new string(worksText.Where(char.IsAsciiDigit).ToArray()));

        // Unrevealed works render a "Mystery Work" blurb with no title link;
        // there's nothing to open, so they're dropped. The rest keep AO3's order.
        var works = doc.Select("ul.series li.work.blurb")
            .Where(li => li.SelectFirst("h4.heading a[href*='/works/']") is not null)
            .Select(SearchResultsParser.ParseBlurb)
            .OfType<AO3WorkSummary>()
            .ToList();
        var (currentPage, totalPages) = HtmlDom.Pagination(doc);

        return new AO3Series
        {
            Id = seriesId,
            Title = title,
            Creator = creator,
            CreatorUsername = creatorUsername,
            DescriptionHtml = descriptionHtml,
            WorkCount = workCount,
            IsComplete = isComplete,
            Works = works,
            CurrentPage = currentPage,
            TotalPages = totalPages,
        };
    }

    /// <summary><c>9</c> from <c>/series/9</c> (or a full <c>https://…/series/9</c> URL).</summary>
    public static int? SeriesId(string href)
    {
        var r = href.IndexOf("/series/", StringComparison.Ordinal);
        if (r < 0) return null;
        var rest = href[(r + "/series/".Length)..];
        var end = rest.IndexOfAny(['/', '?', '#']);
        return HtmlDom.ParseSwiftInt(end < 0 ? rest : rest[..end]);
    }

    private static int? NeighbourId(IElement span, string selector) =>
        span.SelectFirst(selector) is { } a ? SearchResultsParser.WorkId(a.Attr("href")) : null;

    [GeneratedRegex(@"\d+")]
    private static partial Regex FirstNumber();
}
