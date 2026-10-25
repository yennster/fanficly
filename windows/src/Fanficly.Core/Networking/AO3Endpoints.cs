using System.Text;

namespace Fanficly.Core;

/// <summary>AO3 URL builders. Every builder takes the site base (normally
/// <c>https://archiveofourown.org</c>) so tests can point the client elsewhere.</summary>
public static class AO3Endpoints
{
    public static Uri Search(AO3SearchFilters filters, int page, Uri baseUri)
    {
        var items = filters.QueryItems().ToList();
        if (page > 1) items.Add(new("page", page.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        return Build(baseUri, "/works/search", items);
    }

    public static Uri Work(int id, Uri baseUri) =>
        Build(baseUri, $"/works/{id}", [new("view_full_work", "true"), new("view_adult", "true")]);

    /// <summary>The work's own page without <c>view_full_work</c>: enough for the
    /// bookmark form, without downloading every chapter of a long work.</summary>
    public static Uri WorkPage(int id, Uri baseUri) => Build(baseUri, $"/works/{id}", [new("view_adult", "true")]);

    /// <summary>A work one chapter to a page: its first chapter, or the chapter with
    /// that AO3 id. AO3 redirects <c>/works/&lt;id&gt;</c> of a chaptered work to its
    /// first chapter, keeping the adult-content consent in a cookie.</summary>
    public static Uri WorkChapter(int id, int? chapterId, Uri baseUri) =>
        Build(baseUri, chapterId is { } chapter ? $"/works/{id}/chapters/{chapter}" : $"/works/{id}", [new("view_adult", "true")]);

    public static Uri Epub(int workId, Uri baseUri) => Build(baseUri, $"/downloads/{workId}/work.epub");

    public static Uri Download(int workId, WorkExportFormat format, Uri baseUri) =>
        Build(baseUri, $"/downloads/{workId}/work.{format.Ext()}");

    public static Uri AuthorWorks(string name, int page, Uri baseUri) =>
        Build(baseUri, $"/users/{EscapePathSegment(name)}/works", PageItems(page));

    /// <summary>A series page; page 1 sends no <c>page=</c>.</summary>
    public static Uri Series(int id, int page, Uri baseUri) =>
        Build(baseUri, $"/series/{id}", PageItems(page));

    public static Uri UserBookmarks(string name, int page, Uri baseUri) =>
        Build(baseUri, $"/users/{EscapePathSegment(name)}/bookmarks", PageItems(page));

    /// <summary>The user's Marked for Later list: AO3's readings page filtered to
    /// works marked "to read".</summary>
    public static Uri UserMarkedForLater(string name, int page, Uri baseUri) =>
        Build(baseUri, $"/users/{EscapePathSegment(name)}/readings", [new("show", "to-read"), .. PageItems(page)]);

    /// <summary>The user's AO3 reading history: the unfiltered readings page.</summary>
    public static Uri UserReadingHistory(string name, int page, Uri baseUri) =>
        Build(baseUri, $"/users/{EscapePathSegment(name)}/readings", PageItems(page));

    public static Uri UserSubscriptions(string name, int page, Uri baseUri) =>
        Build(baseUri, $"/users/{EscapePathSegment(name)}/subscriptions", PageItems(page));

    public static Uri Login(Uri baseUri) => Build(baseUri, "/users/login");

    /// <summary>A one-shot's (or first chapter's) comment thread. <paramref name="page"/>
    /// is the comment page; page 1 sends no <c>page=</c>.</summary>
    public static Uri WorkComments(int id, Uri baseUri, int page = 1) =>
        Build(baseUri, $"/works/{id}", CommentsQuery(page), "comments");

    /// <summary>A single chapter's page with its comment thread shown — AO3 threads
    /// comments per chapter, so this is what we read/post against when the reader
    /// knows which chapter id it's on.</summary>
    public static Uri ChapterComments(int workId, int chapterId, Uri baseUri, int page = 1) =>
        Build(baseUri, $"/works/{workId}/chapters/{chapterId}", CommentsQuery(page), "comments");

    private static IReadOnlyList<KeyValuePair<string, string>> CommentsQuery(int page) =>
        [new("view_adult", "true"), new("show_comments", "true"), .. PageItems(page)];

    public static Uri WorkSubscriptions(int id, Uri baseUri) => Build(baseUri, $"/works/{id}/subscriptions");

    /// <summary>The kudos POST, at the <c>.js</c> format AO3's own kudos button uses.</summary>
    public static Uri Kudos(Uri baseUri) => Build(baseUri, "/kudos.js");

    public static Uri WorkCommentsPost(int id, Uri baseUri) => Build(baseUri, $"/works/{id}/comments");

    /// <summary>Tag autocomplete. The term is percent-encoded here, including "/":
    /// AO3's autocomplete 404s on a raw slash, so ships like "Hermione/Draco" must
    /// send "%2F".</summary>
    public static Uri Autocomplete(string field, string term, Uri baseUri) =>
        new(Root(baseUri) + $"/autocomplete/{field}?term={PercentEncode(term, AutocompleteAllowed)}");

    public static Uri MediaFandoms(string categoryName, Uri baseUri) =>
        new(Root(baseUri) + $"/media/{AO3PathEncode(categoryName)}/fandoms");

    /// <summary>A tag's works listing (<c>/tags/&lt;tag&gt;/works</c>) — its left filter sidebar
    /// carries the most-used relationships/characters/freeforms with counts.</summary>
    public static Uri TagWorks(string tagName, Uri baseUri) =>
        new(Root(baseUri) + $"/tags/{AO3PathEncode(tagName)}/works");

    /// <summary>AO3's own path encoding for tag and category names: <c>&amp;</c>→<c>*a*</c>,
    /// <c>/</c>→<c>*s*</c>, <c>.</c>→<c>*d*</c>, <c>?</c>→<c>*q*</c>, <c>'</c>→<c>*at*</c>, space →
    /// <c>%20</c>, and anything else not allowed in a URL path percent-encoded.</summary>
    public static string AO3PathEncode(string s)
    {
        var result = new StringBuilder();
        foreach (var rune in s.EnumerateRunes())
        {
            switch (rune.Value)
            {
                case '&': result.Append("*a*"); break;
                case '/': result.Append("*s*"); break;
                case '.': result.Append("*d*"); break;
                case '?': result.Append("*q*"); break;
                case '\'': result.Append("*at*"); break;
                case ' ': result.Append("%20"); break;
                default: AppendEncoded(result, rune, PathAllowed); break;
            }
        }
        return result.ToString();
    }

    // Foundation's CharacterSet.urlPathAllowed (ASCII only).
    private const string PathAllowed = "-._~!$&'()*+,;=:@/";

    // urlQueryAllowed minus "/+&=?" — what the autocomplete term may keep raw.
    private const string AutocompleteAllowed = "-._~!$'()*,;:@";

    private static string PercentEncode(string s, string allowedPunctuation)
    {
        var sb = new StringBuilder();
        foreach (var rune in s.EnumerateRunes()) AppendEncoded(sb, rune, allowedPunctuation);
        return sb.ToString();
    }

    private static void AppendEncoded(StringBuilder sb, Rune rune, string allowedPunctuation)
    {
        if (rune.IsAscii && (char.IsAsciiLetterOrDigit((char)rune.Value) || allowedPunctuation.Contains((char)rune.Value)))
        {
            sb.Append((char)rune.Value);
            return;
        }
        Span<byte> bytes = stackalloc byte[4];
        var n = rune.EncodeToUtf8(bytes);
        for (var i = 0; i < n; i++) sb.Append('%').Append(bytes[i].ToString("X2", System.Globalization.CultureInfo.InvariantCulture));
    }

    private static string EscapePathSegment(string segment) => PercentEncode(segment, "-._~!$&'()*+,;=:@");

    private static IReadOnlyList<KeyValuePair<string, string>> PageItems(int page) =>
        page > 1 ? [new("page", page.ToString(System.Globalization.CultureInfo.InvariantCulture))] : [];

    /// <summary>The base without a trailing slash, so paths append cleanly.</summary>
    private static string Root(Uri baseUri) => baseUri.AbsoluteUri.TrimEnd('/');

    private static Uri Build(Uri baseUri, string path,
        IReadOnlyList<KeyValuePair<string, string>>? query = null, string? fragment = null)
    {
        var sb = new StringBuilder(Root(baseUri)).Append(path);
        if (query is { Count: > 0 })
        {
            sb.Append('?');
            sb.AppendJoin('&', query.Select(kv => $"{Uri.EscapeDataString(kv.Key)}={Uri.EscapeDataString(kv.Value)}"));
        }
        if (fragment is not null) sb.Append('#').Append(fragment);
        return new Uri(sb.ToString());
    }
}
