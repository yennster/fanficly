using System.Text.RegularExpressions;
using AngleSharp.Dom;

namespace Fanficly.Core;

/// <summary>Parses a listing of work blurbs: search results, an author's works,
/// and (with a different container selector) the bookmarks page.</summary>
public static partial class SearchResultsParser
{
    /// <summary>Parse a blurb listing. <paramref name="blurbSelector"/> defaults to the
    /// works-listing markup used by search and author pages; the bookmarks page
    /// uses <c>li.bookmark.blurb</c> (same inner blurb, different container), so it
    /// passes that instead and reuses everything else.</summary>
    public static AO3SearchResults Parse(string html, string blurbSelector = "li.work.blurb")
    {
        var doc = HtmlDom.Parse(html);
        var works = doc.Select(blurbSelector).Select(ParseBlurb).OfType<AO3WorkSummary>().ToList();
        var (currentPage, totalPages) = HtmlDom.Pagination(doc);
        return new AO3SearchResults(works, totalPages, currentPage, TotalFound(doc));
    }

    [GeneratedRegex(@"^[\d,.]+(?=\s+Found)")]
    private static partial Regex FoundRegex();

    /// <summary>The <c>&lt;h3 class="heading"&gt;126,555 Found …&lt;/h3&gt;</c> count on search pages.</summary>
    internal static int? TotalFound(IDocument doc)
    {
        foreach (var heading in doc.Select("h3.heading"))
        {
            var m = FoundRegex().Match(heading.Text());
            if (!m.Success) continue;
            return HtmlDom.ParseSwiftInt(new string(m.Value.Where(char.IsDigit).ToArray()));
        }
        return null;
    }

    public static AO3WorkSummary? ParseBlurb(IElement li)
    {
        var titleAnchor = li.SelectFirst("h4.heading a");

        // Work id: search/author pages tag the <li> as `work_<id>`; the bookmarks
        // page tags it `bookmark_<id>`, so fall back to the `/works/<id>` title
        // link. Bookmarks of series / external / deleted works have no such link
        // and are skipped (null).
        int id;
        if (HtmlDom.ParseSwiftInt(li.Attr("id").Replace("work_", "", StringComparison.Ordinal)) is { } n)
            id = n;
        else if (titleAnchor is not null && WorkId(titleAnchor.Attr("href")) is { } fromHref)
            id = fromHref;
        else
            return null;

        var title = titleAnchor?.Text() ?? "";

        var authorAnchors = li.Select("h4.heading a[rel='author']");
        var author = string.Join(", ", authorAnchors.Select(a => a.Text()));
        var authorUsername = AuthorLogin(authorAnchors.Count > 0 ? authorAnchors[0].Attr("href") : "");

        var fandoms = Texts(li, "h5.fandoms a.tag");

        var requiredTagTexts = Texts(li, "ul.required-tags span.text");
        var rating = requiredTagTexts.FirstOrDefault(IsRating) ?? "Not Rated";
        var warnings = requiredTagTexts.Where(IsWarning).ToList();
        var categories = requiredTagTexts.Where(IsCategory).ToList();
        var isComplete = requiredTagTexts.Contains("Complete Work");

        var relationships = Texts(li, "ul.tags li.relationships a.tag");
        var characters = Texts(li, "ul.tags li.characters a.tag");
        var freeforms = Texts(li, "ul.tags li.freeforms a.tag");

        var summary = li.SelectFirst("blockquote.summary")?.Text() ?? "";
        var language = li.SelectFirst("dd.language")?.Text() ?? "English";

        var wordCount = Number(li.SelectFirst("dd.words")?.Text() ?? "0");
        var kudos = Number(li.SelectFirst("dd.kudos")?.Text() ?? "0");
        var hits = Number(li.SelectFirst("dd.hits")?.Text() ?? "0");

        var (chapterCount, totalChapters) = HtmlDom.ParseChapterFraction(li.SelectFirst("dd.chapters")?.Text() ?? "1/1");

        var updatedAt = HtmlDom.ParseDate(li.SelectFirst("p.datetime")?.Text() ?? "", "dd MMM yyyy");

        return new AO3WorkSummary
        {
            Id = id,
            Title = title,
            Author = author,
            AuthorUsername = authorUsername,
            Summary = summary,
            Rating = rating,
            Warnings = warnings,
            Categories = categories,
            Fandoms = fandoms,
            Characters = characters,
            Relationships = relationships,
            Freeforms = freeforms,
            WordCount = wordCount,
            ChapterCount = chapterCount,
            TotalChapters = totalChapters,
            Language = language,
            Kudos = kudos,
            Hits = hits,
            IsComplete = isComplete,
            UpdatedAt = updatedAt,
        };
    }

    /// <summary>The numeric work id from a title link href like <c>/works/12345</c> or
    /// <c>/works/12345/chapters/678</c>. Null for non-work links (series, external
    /// URLs), so those bookmark blurbs are skipped.</summary>
    public static int? WorkId(string href)
    {
        var r = href.IndexOf("/works/", StringComparison.Ordinal);
        if (r < 0) return null;
        var seg = href[(r + "/works/".Length)..].SwiftSplit('/').FirstOrDefault() ?? "";
        return HtmlDom.ParseSwiftInt(seg);
    }

    /// <summary>The AO3 login from an author byline href like
    /// <c>/users/HoweverSheWrites/pseuds/HoweverSheWrites</c> → <c>HoweverSheWrites</c>.
    /// "" for anonymous works (no/empty href).</summary>
    public static string AuthorLogin(string href)
    {
        var r = href.IndexOf("/users/", StringComparison.Ordinal);
        if (r < 0) return "";
        var seg = href[(r + "/users/".Length)..].SwiftSplit('/').FirstOrDefault() ?? "";
        try { return Uri.UnescapeDataString(seg); }
        catch (UriFormatException) { return seg; }
    }

    private static List<string> Texts(IElement scope, string selector) =>
        scope.Select(selector).Select(e => e.Text()).ToList();

    private static int Number(string text) => HtmlDom.ParseSwiftInt(text.Replace(",", "", StringComparison.Ordinal)) ?? 0;

    private static bool IsRating(string s) =>
        s is "General Audiences" or "Teen And Up Audiences" or "Mature" or "Explicit" or "Not Rated";

    private static bool IsWarning(string s) =>
        s is "No Archive Warnings Apply"
            or "Creator Chose Not To Use Archive Warnings"
            or "Graphic Depictions Of Violence"
            or "Major Character Death"
            or "Rape/Non-Con"
            or "Underage";

    private static bool IsCategory(string s) => s is "F/F" or "F/M" or "Gen" or "M/M" or "Multi" or "Other";
}
