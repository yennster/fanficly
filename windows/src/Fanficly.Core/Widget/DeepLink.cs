using System.Globalization;

namespace Fanficly.Core;

/// <summary>
/// The <c>fanficly://</c> links the app opens (RootView's <c>handleIncomingURL</c>),
/// parsed into what to do. The Windows app's protocol activation, the widget
/// provider and drag-and-drop/paste share this one pure parser:
/// <list type="bullet">
/// <item><c>fanficly://resume/&lt;id&gt;?chapter=&lt;n&gt;&amp;paragraph=&lt;m&gt;</c> — the last-read widget → <see cref="Resume"/></item>
/// <item><c>fanficly://import?url=&lt;AO3 url&gt;</c> (the share target), <c>fanficly://works/&lt;id&gt;</c>, or an AO3 work link → <see cref="Import"/></item>
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

    /// <summary>The AO3 work a link points at (RootView's <c>ImportLink</c>, #176):
    /// <c>fanficly://import?url=…</c> (the embedded URL), <c>fanficly://works/&lt;id&gt;</c>
    /// or <c>fanficly://work/&lt;id&gt;</c>, or an AO3 work link itself. Only
    /// <c>works/&lt;id&gt;</c> on an AO3 host counts: a series, author or tag page,
    /// another site's <c>/works/&lt;n&gt;</c>, and the app's own widget links
    /// (<c>fanficly://search?query=works/5</c>) are not works.</summary>
    public static int? ParseWorkId(Uri url)
    {
        if (IsFanficly(url))
        {
            switch (url.Host.ToLowerInvariant())
            {
                case "import":
                    return QueryValue(url, "url") is { Length: > 0 } embedded ? WorkIdFromWebLink(embedded) : null;
                case "works" or "work":
                    return FirstPathComponent(url) is { } first ? PositiveInt(first) : null;
                default:
                    return null;
            }
        }
        return WorkIdFromWebLink(url.OriginalString);
    }

    /// <summary>A work id from dropped or pasted text (trimmed, read as a URL;
    /// <c>archiveofourown.org/works/1</c> with no scheme reads as https).</summary>
    public static int? WorkIdFromText(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return null;
        if (Uri.TryCreate(trimmed, UriKind.Absolute, out var uri) && IsFanficly(uri)) return ParseWorkId(uri);
        return WorkIdFromWebLink(trimmed);
    }

    /// <summary>Whether a link was meant as something to import: a web link, or
    /// the share target's <c>fanficly://import</c>. Those say "That isn't an AO3
    /// work link" when they aren't a work; widget links don't.</summary>
    public static bool IsLinkToImport(Uri url) =>
        url.IsAbsoluteUri && (url.Scheme.ToLowerInvariant() switch
        {
            "http" or "https" => true,
            Scheme => url.Host.Equals("import", StringComparison.OrdinalIgnoreCase),
            _ => false,
        });

    /// <summary>AO3's own hosts (and their subdomains, such as <c>www.</c>).</summary>
    public static readonly IReadOnlyList<string> AO3Hosts = ["archiveofourown.org", "archiveofourown.com", "archiveofourown.net", "ao3.org"];

    public static bool IsAO3Host(string host)
    {
        var h = host.ToLowerInvariant();
        return AO3Hosts.Any(a => h == a || h.EndsWith("." + a, StringComparison.Ordinal));
    }

    /// <summary>An http(s) link on an AO3 host whose path has <c>works/&lt;id&gt;</c>:
    /// <c>/works/1</c>, <c>/works/1/chapters/2</c>, <c>/collections/x/works/1</c>.</summary>
    private static int? WorkIdFromWebLink(string text)
    {
        var trimmed = text.Trim();
        var absolute = trimmed.Contains("://", StringComparison.Ordinal) ? trimmed : "https://" + trimmed;
        if (!Uri.TryCreate(absolute, UriKind.Absolute, out var uri)) return null;
        if (uri.Scheme is not ("http" or "https") || !IsAO3Host(uri.Host)) return null;
        var parts = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length - 1; i++)
        {
            if (parts[i].Equals("works", StringComparison.OrdinalIgnoreCase) && PositiveInt(parts[i + 1]) is { } id)
                return id;
        }
        return null;
    }

    private static int? PositiveInt(string s) => ParseInt(s) is int v && v > 0 ? v : null;

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

    /// <summary>The saved filter a fanficly://search query carries, if any. The
    /// Saved Searches widget sends a saved search as its prompt and a saved
    /// filter as its filters JSON (as the Swift widget does): a query that starts
    /// with "{" and decodes is a saved filter, and anything else, malformed JSON
    /// included, is prompt text. The Swift app's
    /// <c>AO3SearchFilters.savedFilter(fromRouteQuery:)</c> makes the same call.</summary>
    public static AO3SearchFilters? SavedFilter(string query)
    {
        var trimmed = query.Trim();
        // Applied like the Browse landing page applies one (#157).
        return trimmed.StartsWith('{') && AO3SearchFilters.FromSavedJson(trimmed) is { } saved
            ? new AO3SearchFilters().ApplyingSaved(saved)
            : null;
    }

    // MARK: - Helpers

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
