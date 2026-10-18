using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Fanficly.Core;

public sealed record WidgetSavedSearch(string Name, string Query, bool IsFilter);

public sealed record WidgetFolderShortcut(string Name, int WorkCount);

public sealed record WidgetSubscriptionUpdate(
    int WorkId, string Title, string Author, int ChapterCount, bool IsFollowed, DateTimeOffset UpdatedAt);

public sealed record WidgetRecommendation(int WorkId, string Title, string Author, string Summary, IReadOnlyList<string> Tags)
{
    public bool Equals(WidgetRecommendation? other) =>
        other is not null && WorkId == other.WorkId && Title == other.Title && Author == other.Author &&
        Summary == other.Summary && Tags.SequenceEqual(other.Tags);

    public override int GetHashCode() => HashCode.Combine(WorkId, Title, Author, Summary);
}

// MARK: - Inputs (what the Swift updater fetched from SwiftData)

/// <summary>A saved search (Swift <c>SavedSearch</c>): its name and search-box prompt.</summary>
public sealed record WidgetSavedSearchSource(string Name, string Prompt, DateTimeOffset SavedAt);

/// <summary>A saved filter (Swift <c>SavedFilter</c>): its name and filters JSON.</summary>
public sealed record WidgetSavedFilterSource(string Name, string FiltersJson, DateTimeOffset SavedAt);

/// <summary>A custom library folder and how many works it holds.</summary>
public sealed record WidgetFolderSource(string Name, int WorkCount, DateTimeOffset CreatedAt);

/// <summary>The library fields the widgets use from a saved work (Swift <c>Work</c>).</summary>
public sealed record WidgetWorkSource
{
    public required int Ao3Id { get; init; }
    public string Title { get; init; } = "";
    public string AuthorName { get; init; } = "";
    /// <summary>The work's summary HTML.</summary>
    public string Summary { get; init; } = "";
    public IReadOnlyList<string> Fandoms { get; init; } = [];
    public IReadOnlyList<string> Relationships { get; init; } = [];
    public IReadOnlyList<string> Characters { get; init; } = [];
    public int ChapterCount { get; init; }
    public bool IsFollowed { get; init; }
    public bool IsStarred { get; init; }
    public bool IsPinned { get; init; }
    public DateTimeOffset SavedAt { get; init; }
    public DateTimeOffset? UpdatedAt { get; init; }
}

/// <summary>An AO3 subscription record (Swift <c>SubscriptionRecord</c>).</summary>
/// <param name="Key">"work:123", "series:9", "user:name".</param>
/// <param name="Kind">"work", "series" or "user".</param>
public sealed record WidgetSubscriptionSource(
    string Key, string Kind, string DisplayName, string AuthorName,
    int? LastSeenChapterCount, DateTimeOffset? LastCheckedAt);

/// <summary>Everything <see cref="WidgetDataStore.UpdateAll"/> needs, read from
/// the library database.</summary>
public sealed record WidgetDataSources(
    IReadOnlyList<WidgetSavedSearchSource> SavedSearches,
    IReadOnlyList<WidgetSavedFilterSource> SavedFilters,
    IReadOnlyList<WidgetFolderSource> Folders,
    IReadOnlyList<WidgetWorkSource> Works,
    IReadOnlyList<WidgetSubscriptionSource> Subscriptions);

/// <summary>
/// The data behind the saved-search, folder, subscription and recommendation
/// widgets, written to the app-group store (and the app's own store) as the Swift
/// app's JSON. The <c>Build…</c> functions are pure; <c>Update…</c> builds and
/// saves. Callers pass plain rows from the database (the Swift updater fetched
/// them from SwiftData itself).
/// </summary>
public static class WidgetDataStore
{
    public const string AppGroupIdentifier = AppGroupStore.Identifier;
    public const string SavedSearchesKey = "widget.savedSearches";
    public const string CustomFoldersKey = "widget.customFolders";
    public const string SubscriptionsKey = "widget.subscriptions";
    public const string RecommendationsKey = "widget.recommendations";

    /// <summary>Test seams; null uses <see cref="KeyValueStores.Default"/> and
    /// <see cref="AppGroupStore.Shared"/>.</summary>
    internal static IKeyValueStore? LocalOverride { get; set; }
    internal static IKeyValueStore? SharedOverride { get; set; }

    private static IKeyValueStore Local => LocalOverride ?? KeyValueStores.Default;
    private static IKeyValueStore? Shared => SharedOverride ?? AppGroupStore.Shared;

    // MARK: - Load

    public static IReadOnlyList<WidgetSavedSearch> LoadLocalSavedSearches() => LoadLocal(SavedSearchesKey, DecodeSavedSearch) ?? [];

    public static IReadOnlyList<WidgetFolderShortcut> LoadLocalFolders() => LoadLocal(CustomFoldersKey, DecodeFolder) ?? [];

    public static IReadOnlyList<WidgetSubscriptionUpdate> LoadLocalSubscriptions() => LoadLocal(SubscriptionsKey, DecodeSubscription) ?? [];

    public static IReadOnlyList<WidgetRecommendation> LoadLocalRecommendations() => LoadLocal(RecommendationsKey, DecodeRecommendation) ?? [];

    /// <summary>The app-group copy if there is one, else the app's own; a copy
    /// that doesn't decode is null (no fallback to the other).</summary>
    private static IReadOnlyList<T>? LoadLocal<T>(string key, Func<JsonElement, T> decode)
    {
        var data = Shared?.GetString(key) ?? Local.GetString(key);
        return WidgetJson.Read(data, root => WidgetJson.Array(root, decode));
    }

    // MARK: - Update

    public static void UpdateAll(WidgetDataSources sources, DateTimeOffset? now = null)
    {
        UpdateSavedSearches(sources.SavedSearches, sources.SavedFilters);
        UpdateFolders(sources.Folders);
        UpdateSubscriptions(sources.Works, sources.Subscriptions, now);
        UpdateRecommendations(sources.Works);
        WidgetCenter.ReloadAllTimelines();
    }

    public static void UpdateSavedSearches(IEnumerable<WidgetSavedSearchSource> searches, IEnumerable<WidgetSavedFilterSource> filters) =>
        SaveLocal(SavedSearchesKey, BuildSavedSearches(searches, filters), EncodeSavedSearch);

    public static void UpdateFolders(IEnumerable<WidgetFolderSource> folders) =>
        SaveLocal(CustomFoldersKey, BuildFolders(folders), EncodeFolder);

    public static void UpdateSubscriptions(IEnumerable<WidgetWorkSource> works, IEnumerable<WidgetSubscriptionSource> subscriptions, DateTimeOffset? now = null) =>
        SaveLocal(SubscriptionsKey, BuildSubscriptions(works, subscriptions, now ?? DateTimeOffset.Now), EncodeSubscription);

    public static void UpdateRecommendations(IEnumerable<WidgetWorkSource> works) =>
        SaveLocal(RecommendationsKey, BuildRecommendations(works), EncodeRecommendation);

    // MARK: - Build (pure)

    /// <summary>Saved searches then saved filters, each newest first; at most 20.</summary>
    public static IReadOnlyList<WidgetSavedSearch> BuildSavedSearches(
        IEnumerable<WidgetSavedSearchSource> searches, IEnumerable<WidgetSavedFilterSource> filters)
    {
        var list = new List<WidgetSavedSearch>();
        list.AddRange(searches.OrderByDescending(s => s.SavedAt).Select(s => new WidgetSavedSearch(s.Name, s.Prompt, false)));
        list.AddRange(filters.OrderByDescending(f => f.SavedAt).Select(f => new WidgetSavedSearch(f.Name, f.FiltersJson, true)));
        return list.Take(20).ToList();
    }

    /// <summary>Folders, newest first.</summary>
    public static IReadOnlyList<WidgetFolderShortcut> BuildFolders(IEnumerable<WidgetFolderSource> folders) =>
        folders.OrderByDescending(f => f.CreatedAt).Select(f => new WidgetFolderShortcut(f.Name, f.WorkCount)).ToList();

    /// <summary>Locally followed works, then AO3 work subscriptions not already
    /// listed, most recently updated first; at most 20.</summary>
    public static IReadOnlyList<WidgetSubscriptionUpdate> BuildSubscriptions(
        IEnumerable<WidgetWorkSource> works, IEnumerable<WidgetSubscriptionSource> subscriptions, DateTimeOffset now)
    {
        var list = new List<WidgetSubscriptionUpdate>();
        // 1. Followed local works.
        foreach (var w in works.Where(w => w.IsFollowed).OrderByDescending(w => w.SavedAt))
            list.Add(new WidgetSubscriptionUpdate(w.Ao3Id, w.Title, w.AuthorName, w.ChapterCount, true, w.UpdatedAt ?? w.SavedAt));
        // 2. Online subscriptions to works.
        foreach (var s in subscriptions.Where(s => s.Kind == "work"))
        {
            var parts = s.Key.Split(':', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 2 || !TryParseInt(parts[1], out var workId)) continue;
            // Avoid duplicating a work that's already in the followed list.
            if (list.Any(u => u.WorkId == workId)) continue;
            list.Add(new WidgetSubscriptionUpdate(workId, s.DisplayName, s.AuthorName, s.LastSeenChapterCount ?? 0, false, s.LastCheckedAt ?? now));
        }
        return list.OrderByDescending(u => u.UpdatedAt).Take(20).ToList();
    }

    /// <summary>Every saved work — starred first, then pinned, then newest saved —
    /// with its summary as plain text (≤ 180 characters) and up to three key tags.</summary>
    public static IReadOnlyList<WidgetRecommendation> BuildRecommendations(IEnumerable<WidgetWorkSource> works) =>
        works
            .OrderByDescending(w => w.IsStarred)
            .ThenByDescending(w => w.IsPinned)
            .ThenByDescending(w => w.SavedAt)
            .Select(w =>
            {
                // Strip HTML tags from the summary for the widget preview.
                var cleanSummary = HtmlTag.Replace(w.Summary, "").Trim();
                // A few key tags.
                var tags = new List<string>();
                if (w.Fandoms.Count > 0) tags.Add(w.Fandoms[0]);
                if (w.Relationships.Count > 0) tags.Add(w.Relationships[0]);
                if (w.Characters.Count > 0) tags.Add(w.Characters[0]);
                return new WidgetRecommendation(w.Ao3Id, w.Title, w.AuthorName, PrefixCharacters(cleanSummary, 180), tags);
            })
            .ToList();

    private static readonly Regex HtmlTag = new("<[^>]+>");

    /// <summary>The first <paramref name="count"/> user-perceived characters.</summary>
    private static string PrefixCharacters(string s, int count)
    {
        var info = new StringInfo(s);
        return info.LengthInTextElements <= count ? s : info.SubstringByTextElements(0, count);
    }

    private static bool TryParseInt(string s, out int value) =>
        int.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out value);

    // MARK: - Encoding (Swift JSONEncoder shape)

    private static void SaveLocal<T>(string key, IReadOnlyList<T> list, Action<Utf8JsonWriter, T> encode)
    {
        var data = WidgetJson.Write(w =>
        {
            w.WriteStartArray();
            foreach (var item in list) encode(w, item);
            w.WriteEndArray();
        });
        Shared?.SetString(key, data);
        Local.SetString(key, data);
    }

    private static void EncodeSavedSearch(Utf8JsonWriter w, WidgetSavedSearch s)
    {
        w.WriteStartObject();
        w.WriteString("name", s.Name);
        w.WriteString("query", s.Query);
        w.WriteBoolean("isFilter", s.IsFilter);
        w.WriteEndObject();
    }

    private static WidgetSavedSearch DecodeSavedSearch(JsonElement o) =>
        new(WidgetJson.String(o, "name"), WidgetJson.String(o, "query"), WidgetJson.Bool(o, "isFilter"));

    private static void EncodeFolder(Utf8JsonWriter w, WidgetFolderShortcut f)
    {
        w.WriteStartObject();
        w.WriteString("name", f.Name);
        w.WriteNumber("workCount", f.WorkCount);
        w.WriteEndObject();
    }

    private static WidgetFolderShortcut DecodeFolder(JsonElement o) =>
        new(WidgetJson.String(o, "name"), WidgetJson.Int(o, "workCount"));

    private static void EncodeSubscription(Utf8JsonWriter w, WidgetSubscriptionUpdate s)
    {
        w.WriteStartObject();
        w.WriteNumber("workId", s.WorkId);
        w.WriteString("title", s.Title);
        w.WriteString("author", s.Author);
        w.WriteNumber("chapterCount", s.ChapterCount);
        w.WriteBoolean("isFollowed", s.IsFollowed);
        w.WriteNumber("updatedAt", WidgetJson.ToReferenceSeconds(s.UpdatedAt));
        w.WriteEndObject();
    }

    private static WidgetSubscriptionUpdate DecodeSubscription(JsonElement o) =>
        new(WidgetJson.Int(o, "workId"), WidgetJson.String(o, "title"), WidgetJson.String(o, "author"),
            WidgetJson.Int(o, "chapterCount"), WidgetJson.Bool(o, "isFollowed"), WidgetJson.Date(o, "updatedAt"));

    private static void EncodeRecommendation(Utf8JsonWriter w, WidgetRecommendation r)
    {
        w.WriteStartObject();
        w.WriteNumber("workId", r.WorkId);
        w.WriteString("title", r.Title);
        w.WriteString("author", r.Author);
        w.WriteString("summary", r.Summary);
        w.WriteStartArray("tags");
        foreach (var t in r.Tags) w.WriteStringValue(t);
        w.WriteEndArray();
        w.WriteEndObject();
    }

    private static WidgetRecommendation DecodeRecommendation(JsonElement o) =>
        new(WidgetJson.Int(o, "workId"), WidgetJson.String(o, "title"), WidgetJson.String(o, "author"),
            WidgetJson.String(o, "summary"), WidgetJson.Strings(o, "tags"));
}
