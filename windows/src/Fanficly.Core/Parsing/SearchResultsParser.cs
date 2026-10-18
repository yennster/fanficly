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
        AO3PageCheck.RejectLoginPage(doc);
        var blurbs = doc.Select(blurbSelector);
        // No blurbs only means "no results" on a real listing; a stray error
        // page or markup drift must not read as an empty search.
        if (blurbs.Count == 0 && !IsListingPage(doc)) throw AO3Exception.ParseFailed("Not a works listing");
        var works = blurbs.Select(ParseBlurb).OfType<AO3WorkSummary>().ToList();
        var (currentPage, totalPages) = HtmlDom.Pagination(doc);
        return new AO3SearchResults(works, totalPages, currentPage, TotalFound(doc));
    }

    /// <summary>A works, bookmarks or readings listing, even an empty one: the index
    /// <c>&lt;ol&gt;</c> that author, tag and bookmark pages always render, the Rails
    /// controller-action class on <c>#main</c>, or the "No results found" line search
    /// shows instead of the list.</summary>
    private static bool IsListingPage(IDocument doc) =>
        doc.SelectFirst("ol.work.index, ol.bookmark.index") is not null
        || AO3PageCheck.MainHasClass(doc, "works-search", "works-index", "works-collected", "bookmarks-search", "bookmarks-index", "readings-index")
        || doc.Select("#main p").Any(p => p.Text().Contains("No results found", StringComparison.Ordinal));

    /// <summary>AO3's readings page (<c>/users/&lt;name&gt;/readings</c>, which with
    /// <c>?show=to-read</c> is Marked for Later). Each entry is
    /// <c>li.reading.work.blurb</c> with id <c>work_&lt;id&gt;</c> around the usual work
    /// blurb; deleted works keep an entry with no id and no title link, so
    /// <see cref="ParseBlurb"/> skips them. Fails closed: the page is login-only,
    /// so a login form means the session expired, and a page without the
    /// <c>readings-index</c> shell (AO3 sends readers with history turned off to
    /// their preferences) is never read as an empty list.</summary>
    /// <exception cref="AO3Exception">Unauthorized for a login page; ParseFailed for
    /// any page that isn't the readings page.</exception>
    /// <summary>ParseReadings' reasons, written to be shown as they are (the
    /// Swift app's wording); see <c>ReadingListScreen</c>.</summary>
    public const string HistoryOffReason =
        "Your AO3 reading history is turned off. Check \"Turn on History\" in your AO3 preferences to see this list.";
    public const string NotReadingsReason =
        "AO3 sent a page that isn't your readings list. Try again, or check the list on the AO3 website.";

    public static AO3SearchResults ParseReadings(string html)
    {
        if (LoginParser.HasLoginForm(html)) throw AO3Exception.Unauthorized();
        var doc = HtmlDom.Parse(html);
        if (doc.Select("div.readings-index").Count == 0)
        {
            if (doc.Select("div.preferences-index").Count > 0)
                throw AO3Exception.ParseFailed(HistoryOffReason);
            throw AO3Exception.ParseFailed(NotReadingsReason);
        }
        return Parse(html, "li.reading.work.blurb");
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

/// <summary>Fail-closed checks shared by the parsers of pages a guest can open. They
/// can't reuse <see cref="SubscriptionsParser"/>'s "any login form" test: every page
/// AO3 serves a logged-out reader carries the header's small login form.</summary>
internal static class AO3PageCheck
{
    /// <summary>AO3's login page, where it redirects a stale session or a guest
    /// opening a restricted work (the HTTP client follows the redirect, so it arrives
    /// as a 200). Only the login page has a login form inside <c>#main</c>.</summary>
    public static bool IsLoginPage(IDocument doc) =>
        doc.SelectFirst("div#main.sessions-new, #main #loginform, #main form[action*='/users/login']") is not null;

    public static void RejectLoginPage(IDocument doc)
    {
        if (IsLoginPage(doc)) throw AO3Exception.Unauthorized();
    }

    /// <summary>Whether <c>div#main</c> carries one of these classes (AO3 sets it to
    /// the Rails <c>controller-action</c>, e.g. <c>works-search</c>).</summary>
    public static bool MainHasClass(IDocument doc, params string[] classes) =>
        doc.SelectFirst("div#main") is { } main && classes.Any(main.ClassList.Contains);
}
