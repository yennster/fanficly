using System.Globalization;
using System.Text.RegularExpressions;

namespace Fanficly.Core;

/// <summary>
/// The <c>fanficly://</c> links the app opens (RootView's <c>handleIncomingURL</c>),
/// parsed into what to do. The Windows app's protocol activation, the widget
/// provider and drag-and-drop/paste share this one pure parser:
/// <list type="bullet">
/// <item><c>fanficly://resume/&lt;id&gt;?chapter=&lt;n&gt;&amp;paragraph=&lt;m&gt;</c> — the last-read widget → <see cref="Resume"/></item>
/// <item><c>fanficly://import?url=&lt;AO3 url&gt;</c> (the share target), <c>fanficly://works/&lt;id&gt;</c>, or any URL containing <c>works/&lt;id&gt;</c> → <see cref="Import"/></item>
/// <item><c>fanficly://library?folder=&lt;name&gt;</c> — a folder widget → <see cref="LibraryFolder"/></item>
/// <item><c>fanficly://search?query=&lt;prompt&gt;</c> — a saved-search widget → <see cref="Search"/></item>
/// </list>
/// </summary>
public abstract record DeepLink
{
    private DeepLink() { }

    public const string Scheme = "fanficly";

    /// <summary>Where the search tab picks up a query handed over by a link
    /// (Swift's <c>@AppStorage("search.pendingQuery")</c>).</summary>
    public const string PendingSearchQueryKey = "search.pendingQuery";

    /// <summary>Open the reader at the widget's position (see <see cref="ResumeProgressPolicy"/>).</summary>
    public sealed record Resume(ResumeWorkRoute Route) : DeepLink;

    /// <summary>Import the work (fetch, save to the library, open it).</summary>
    public sealed record Import(int WorkId) : DeepLink;

    /// <summary>Open the Library on this custom folder.</summary>
    public sealed record LibraryFolder(string FolderName) : DeepLink;

    /// <summary>Open Search with this search-box text (a saved search's prompt).</summary>
    public sealed record Search(string Query) : DeepLink;

    public static DeepLink? Parse(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) ? Parse(uri) : null;

    /// <summary>What the link opens, in RootView's order: resume, then a work to
    /// import, then a folder, then a search. Null when it's none of these.</summary>
    public static DeepLink? Parse(Uri url)
    {
        if (ParseResumeRoute(url) is { } route) return new Resume(route);
        if (ParseWorkId(url) is { } workId) return new Import(workId);
        if (url.IsAbsoluteUri && url.Host == "library" && QueryValue(url, "folder") is { } folder) return new LibraryFolder(folder);
        if (url.IsAbsoluteUri && url.Host == "search" && QueryValue(url, "query") is { } query) return new Search(query);
        return null;
    }

    /// <summary>Parses <c>fanficly://resume/&lt;id&gt;?chapter=&amp;paragraph=</c>. The
    /// anchor needs a chapter; it's clamped to chapter ≥ 1, paragraph ≥ 0
    /// (a missing paragraph is 0).</summary>
    public static ResumeWorkRoute? ParseResumeRoute(Uri url)
    {
        if (!IsFanficly(url) || !url.Host.Equals("resume", StringComparison.OrdinalIgnoreCase)) return null;
        if (FirstPathComponent(url) is not { } idString || ParseInt(idString) is not { } id) return null;
        var chapter = QueryValue(url, "chapter") is { } c ? ParseInt(c) : null;
        var paragraph = QueryValue(url, "paragraph") is { } p ? ParseInt(p) : null;
        ReadingAnchor? anchor = chapter is { } ch ? new ReadingAnchor(Math.Max(ch, 1), Math.Max(paragraph ?? 0, 0)) : null;
        return new ResumeWorkRoute(id, anchor);
    }

    /// <summary>The AO3 work a link points at: <c>fanficly://import?url=…</c> (the
    /// embedded URL), <c>fanficly://works/&lt;id&gt;</c> or <c>fanficly://work/&lt;id&gt;</c>,
    /// any other <c>fanficly://&lt;host&gt;/&lt;id&gt;</c>, and otherwise the first
    /// <c>works/&lt;id&gt;</c> anywhere in the URL (an AO3 link dropped or pasted on
    /// the window). Note the last rule, as in the Swift app, also matches inside
    /// a query: <c>fanficly://search?query=works/5</c> imports work 5.</summary>
    public static int? ParseWorkId(Uri url)
    {
        var target = url.OriginalString;
        if (IsFanficly(url))
        {
            if (url.Host == "import")
            {
                if (QueryValue(url, "url") is { Length: > 0 } embedded) target = embedded;
            }
            else if (FirstPathComponent(url) is { } first && ParseInt(first) is { } id)
            {
                // fanficly://works/<id>, fanficly://work/<id>, or any host.
                return id;
            }
        }
        var match = WorksPath.Match(target);
        return match.Success ? ParseInt(match.Groups[1].Value) : null;
    }

    /// <summary>A work id from dropped or pasted text (trimmed, read as a URL).</summary>
    public static int? WorkIdFromText(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return null;
        if (Uri.TryCreate(trimmed, UriKind.Absolute, out var uri)) return ParseWorkId(uri);
        // A relative reference ("archiveofourown.org/works/1"): no scheme, so only
        // the works/<id> rule can apply.
        var match = WorksPath.Match(trimmed);
        return match.Success ? ParseInt(match.Groups[1].Value) : null;
    }

    // MARK: - Building links (the widget provider and share target)

    public static Uri ResumeUri(int workId, int? chapter = null, int? paragraph = null)
    {
        var query = new List<string>();
        if (chapter is { } c) query.Add($"chapter={c.ToString(CultureInfo.InvariantCulture)}");
        if (paragraph is { } p) query.Add($"paragraph={p.ToString(CultureInfo.InvariantCulture)}");
        var tail = query.Count == 0 ? "" : "?" + string.Join("&", query);
        return new Uri($"{Scheme}://resume/{workId.ToString(CultureInfo.InvariantCulture)}{tail}");
    }

    public static Uri ImportUri(string ao3Url) => new($"{Scheme}://import?url={Uri.EscapeDataString(ao3Url)}");

    public static Uri LibraryFolderUri(string folderName) => new($"{Scheme}://library?folder={Uri.EscapeDataString(folderName)}");

    public static Uri SearchUri(string query) => new($"{Scheme}://search?query={Uri.EscapeDataString(query)}");

    /// <summary>The search text for a fanficly://search query. The Saved
    /// Searches widget sends a saved filter as its filters JSON (as the Swift
    /// widget does); that becomes the filters' key:value prompt, which
    /// SearchSyntax reads back exactly. Anything else is already prompt text.</summary>
    public static string SearchPrompt(string query)
    {
        var trimmed = query.Trim();
        if (trimmed.StartsWith('{') && AO3SearchFilters.FromSavedJson(trimmed) is { } filters)
            return filters.PromptText();
        return query;
    }

    // MARK: - Helpers

    private static readonly Regex WorksPath = new(@"works/(\d+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static bool IsFanficly(Uri url) =>
        url.IsAbsoluteUri && url.Scheme.Equals(Scheme, StringComparison.OrdinalIgnoreCase);

    private static string? FirstPathComponent(Uri url)
    {
        var parts = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length == 0 ? null : Uri.UnescapeDataString(parts[0]);
    }

    /// <summary>The first query item named <paramref name="name"/>, percent-decoded
    /// ("+" stays "+", as with <c>URLComponents</c>). An item with no "=" has no value.</summary>
    internal static string? QueryValue(Uri url, string name)
    {
        var query = url.Query;
        if (query.Length <= 1) return null;
        foreach (var item in query[1..].Split('&'))
        {
            var eq = item.IndexOf('=');
            var key = Uri.UnescapeDataString(eq < 0 ? item : item[..eq]);
            if (key != name) continue;
            return eq < 0 ? null : Uri.UnescapeDataString(item[(eq + 1)..]);
        }
        return null;
    }

    /// <summary>Swift's <c>Int(String)</c>: optional sign, ASCII digits, nothing else.</summary>
    private static int? ParseInt(string s) =>
        s.Length > 0 && s.Skip(s[0] is '+' or '-' ? 1 : 0).All(char.IsAsciiDigit) &&
        int.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var v) ? v : null;
}
