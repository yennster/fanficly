using System.Globalization;
using System.Text;

namespace Fanficly.Core;

/// <summary>An AO3 author to open ("more by this author"): <see cref="Username"/>
/// is the login used to fetch the works page; <see cref="DisplayName"/> is the
/// byline text.</summary>
public sealed record AuthorRef(string Username, string DisplayName);

/// <summary>
/// What a tapped poller notification opens. Encoded into the toast's launch
/// arguments when the poller posts it and decoded when it's tapped, so the
/// payload format lives in one place. Windows toasts carry string key/value
/// arguments (the Swift app used a plist <c>userInfo</c>; same keys).
/// </summary>
public abstract record NotificationRoute
{
    private NotificationRoute() { }

    /// <summary>New chapters on a followed or AO3-subscribed work.</summary>
    public sealed record NewChapters(int WorkId) : NotificationRoute;

    /// <summary>A followed author posted one new work.</summary>
    public sealed record NewWork(int WorkId) : NotificationRoute;

    /// <summary>A followed author posted several new works at once.</summary>
    public sealed record NewWorks(AuthorRef Author) : NotificationRoute;

    /// <summary>One new fic matches a saved search with alerts on (#309).</summary>
    public sealed record SearchMatch(int WorkId) : NotificationRoute;

    /// <summary>Several new fics match a saved search: opens its results, newest
    /// posted first. Carries the prompt so the tap needs no lookup.</summary>
    public sealed record SavedSearchMatches(string Name, string Prompt) : NotificationRoute;

    internal static class Key
    {
        public const string Kind = "kind";
        public const string WorkId = "workId";
        public const string AuthorUsername = "authorUsername";
        public const string AuthorName = "authorName";
        public const string SearchName = "searchName";
        public const string SearchPrompt = "searchPrompt";
    }

    private const string KindNewChapters = "newChapters";
    private const string KindNewWork = "newWork";
    private const string KindNewWorks = "newWorks";
    private const string KindSearchMatch = "searchMatch";
    private const string KindSavedSearch = "savedSearch";

    /// <summary>The toast arguments (Swift's <c>userInfo</c>, as strings).</summary>
    public IReadOnlyDictionary<string, string> ToArguments() => this switch
    {
        NewChapters r => new Dictionary<string, string> { [Key.Kind] = KindNewChapters, [Key.WorkId] = Format(r.WorkId) },
        NewWork r => new Dictionary<string, string> { [Key.Kind] = KindNewWork, [Key.WorkId] = Format(r.WorkId) },
        NewWorks r => new Dictionary<string, string>
        {
            [Key.Kind] = KindNewWorks,
            [Key.AuthorUsername] = r.Author.Username,
            [Key.AuthorName] = r.Author.DisplayName,
        },
        SearchMatch r => new Dictionary<string, string> { [Key.Kind] = KindSearchMatch, [Key.WorkId] = Format(r.WorkId) },
        SavedSearchMatches r => new Dictionary<string, string>
        {
            [Key.Kind] = KindSavedSearch,
            [Key.SearchName] = r.Name,
            [Key.SearchPrompt] = r.Prompt,
        },
        _ => throw new InvalidOperationException(),
    };

    /// <summary>Decodes a tapped toast's arguments; null when there's nothing to
    /// open. Unrelated keys are ignored.</summary>
    public static NotificationRoute? FromArguments(IReadOnlyDictionary<string, string> arguments)
    {
        int? workId = arguments.TryGetValue(Key.WorkId, out var raw) ? ParseInt(raw) : null;
        var kind = arguments.TryGetValue(Key.Kind, out var k) ? k : null;
        switch (kind)
        {
            case KindNewWorks:
                if (!arguments.TryGetValue(Key.AuthorUsername, out var username) || username.Length == 0) return null;
                var name = arguments.TryGetValue(Key.AuthorName, out var n) && n.Length > 0 ? n : null;
                return new NewWorks(new AuthorRef(username, name ?? username));
            case KindNewWork:
                return workId is { } id ? new NewWork(id) : null;
            case KindSearchMatch:
                return workId is { } matchId ? new SearchMatch(matchId) : null;
            case KindSavedSearch:
                if (!arguments.TryGetValue(Key.SearchName, out var searchName)
                    || !arguments.TryGetValue(Key.SearchPrompt, out var prompt) || prompt.Length == 0) return null;
                return new SavedSearchMatches(searchName, prompt);
            default:
                // newChapters — or no (or an unknown) kind: posted before taps were
                // routed, when chapter alerts and single new works both carried
                // just the work id.
                return workId is { } wid ? new NewChapters(wid) : null;
        }
    }

    /// <summary>The arguments as one launch string (<c>key=value;key=value</c>,
    /// with <c>%</c>, <c>;</c> and <c>=</c> percent-escaped — the Windows App SDK
    /// toast-argument format), for a toast's <c>launch</c> attribute.</summary>
    public string ToLaunchArguments() =>
        string.Join(";", ToArguments().Select(kv => $"{EscapeArgument(kv.Key)}={EscapeArgument(kv.Value)}"));

    /// <summary>Decodes <see cref="ToLaunchArguments"/> output (or any toast
    /// launch string in that format).</summary>
    public static NotificationRoute? FromLaunchArguments(string launch) => FromArguments(ParseLaunchArguments(launch));

    public static IReadOnlyDictionary<string, string> ParseLaunchArguments(string launch)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in launch.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = pair.IndexOf('=');
            var key = UnescapeArgument(eq < 0 ? pair : pair[..eq]);
            result[key] = eq < 0 ? "" : UnescapeArgument(pair[(eq + 1)..]);
        }
        return result;
    }

    /// <summary>The work this route opens (Swift's <c>workId</c>); null for an author.</summary>
    public int? TargetWorkId => this switch
    {
        NewChapters r => r.WorkId,
        NewWork r => r.WorkId,
        SearchMatch r => r.WorkId,
        _ => null,
    };

    /// <summary>The tab to open beneath the screen when no tab is showing yet
    /// (e.g. a cold launch), so Back lands somewhere related: chapter alerts for a
    /// saved work in the Library, for a work only subscribed to on AO3 in
    /// Subscriptions; author news in Followed Authors; saved search news in Search.</summary>
    public SidebarItem LandingTab(bool workIsSaved) => this switch
    {
        NewChapters => workIsSaved ? SidebarItem.Library : SidebarItem.Subscriptions,
        SearchMatch or SavedSearchMatches => SidebarItem.Search,
        _ => SidebarItem.Authors,
    };

    private static string Format(int value) => value.ToString(CultureInfo.InvariantCulture);

    /// <summary>A whole-number argument (optional sign, ASCII digits only).</summary>
    private static int? ParseInt(string s) =>
        s.Length > 0 && s.Skip(s[0] is '+' or '-' ? 1 : 0).All(char.IsAsciiDigit) &&
        int.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var v) ? v : null;

    private static string EscapeArgument(string s) =>
        s.Replace("%", "%25").Replace(";", "%3B").Replace("=", "%3D");

    private static string UnescapeArgument(string s)
    {
        if (!s.Contains('%')) return s;
        var sb = new StringBuilder(s.Length);
        for (var i = 0; i < s.Length; i++)
        {
            if (s[i] == '%' && i + 2 < s.Length && char.IsAsciiHexDigit(s[i + 1]) && char.IsAsciiHexDigit(s[i + 2])
                && Convert.ToInt32(s.Substring(i + 1, 2), 16) is var b and < 0x80)
            {
                sb.Append((char)b);
                i += 2;
            }
            else sb.Append(s[i]);
        }
        return sb.ToString();
    }
}

/// <summary>Hands a tapped notification's route from the activation handler to
/// the root view. A tap that cold-launches the app can arrive before the window
/// exists, so the route waits here until the root view takes it.</summary>
public sealed class NotificationRouter
{
    public static NotificationRouter Shared { get; } = new();

    private readonly Lock _gate = new();
    private NotificationRoute? _pendingRoute;

    /// <summary>Raised (on the setting thread) when a new route arrives.</summary>
    public event Action<NotificationRoute>? RouteArrived;

    public NotificationRoute? PendingRoute
    {
        get { lock (_gate) return _pendingRoute; }
        set
        {
            lock (_gate) _pendingRoute = value;
            if (value is not null) RouteArrived?.Invoke(value);
        }
    }

    /// <summary>Takes the pending route (clearing it), if any.</summary>
    public NotificationRoute? TakePendingRoute()
    {
        lock (_gate)
        {
            var route = _pendingRoute;
            _pendingRoute = null;
            return route;
        }
    }
}
