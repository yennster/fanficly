using System.Globalization;
using System.Text.Json;

namespace Fanficly.Core;

/// <summary>Which list of the Popular tab a tag comes from (<c>PopularTag.Kind</c>).</summary>
public enum PopularTagKind { Fandom, Ship, Character }

public static class PopularTagKinds
{
    public static IReadOnlyList<PopularTagKind> All { get; } = [PopularTagKind.Fandom, PopularTagKind.Ship, PopularTagKind.Character];

    public static string RawValue(this PopularTagKind kind) => kind switch
    {
        PopularTagKind.Fandom => "fandom",
        PopularTagKind.Ship => "ship",
        _ => "character",
    };

    /// <summary>The segment title ("Fandoms", "Ships", "Characters").</summary>
    public static string Title(this PopularTagKind kind) => kind switch
    {
        PopularTagKind.Fandom => "Fandoms",
        PopularTagKind.Ship => "Ships",
        _ => "Characters",
    };

    /// <summary>Icon id (SF Symbol name) for ships and characters; fandoms use
    /// <see cref="FandomCatalog.Symbol"/> per fandom.</summary>
    public static string Symbol(this PopularTagKind kind) => kind switch
    {
        PopularTagKind.Fandom => "books.vertical",
        PopularTagKind.Ship => "heart",
        _ => "person",
    };
}

/// <summary>A popular tag tapped in the Popular tab (the Swift navigation value).</summary>
public sealed record PopularTag(PopularTagKind Kind, string Name)
{
    /// <summary>The tag's works sorted by kudos, so the most-loved works surface
    /// first (<c>FandomWorksView(popular:)</c>).</summary>
    public AO3SearchFilters Filters()
    {
        var filters = new AO3SearchFilters();
        switch (Kind)
        {
            case PopularTagKind.Fandom: filters.FandomNames = [Name]; break;
            case PopularTagKind.Ship: filters.RelationshipNames = [Name]; break;
            default: filters.CharacterNames = [Name]; break;
        }
        filters.SortColumn = SortColumn.KudosCount;
        filters.SortDirection = SortDirection.Desc;
        return filters;
    }

    /// <summary>The icon id the row shows: the fandom's category symbol, or the
    /// kind's symbol for ships and characters.</summary>
    public string Symbol => Kind == PopularTagKind.Fandom ? FandomCatalog.Symbol(Name) : Kind.Symbol();

    /// <summary>Trims AO3's canonical disambiguation noise for display only — the
    /// search still uses the full canonical name. "Harry Potter - J. K. Rowling" →
    /// "Harry Potter"; "Castiel (Supernatural)" keeps its qualifier.</summary>
    public string DisplayName => DisplayNameFor(Kind, Name);

    public static string DisplayNameFor(PopularTagKind kind, string name) =>
        kind == PopularTagKind.Fandom ? name.Split(" - ")[0] : name;
}

/// <summary>
/// On-device cache for the live popular snapshot. Refreshed at most once a day
/// (the data is AO3's cumulative work counts, which barely move day to day), so
/// opening the Popular tab doesn't re-scrape AO3 every time. Falls back to the
/// curated <see cref="PopularTags"/> seed whenever there's no fresh snapshot.
/// </summary>
public static class PopularStore
{
    public const string Key = "popular.snapshot.v1";
    public static readonly TimeSpan MaxAge = TimeSpan.FromHours(24);

    /// <summary>Top N per segment.</summary>
    public const int ListLimit = 30;

    public static PopularSnapshot? Cached(IKeyValueStore? store = null)
    {
        var raw = (store ?? KeyValueStores.Default).GetString(Key);
        return raw is null ? null : Decode(raw);
    }

    public static bool IsStale(PopularSnapshot? snapshot, DateTimeOffset? now = null)
    {
        if (snapshot is null) return true;
        return (now ?? DateTimeOffset.Now) - snapshot.FetchedAt > MaxAge;
    }

    /// <summary>Returns a fresh snapshot, fetching + caching only when the cache is
    /// missing or older than a day. Never throws (except on cancellation) — keeps
    /// the existing cache on failure so the UI just keeps showing what it had (or
    /// the curated seed).</summary>
    public static async Task<PopularSnapshot?> RefreshIfStaleAsync(IAO3Client client, IKeyValueStore? store = null,
                                                                  DateTimeOffset? now = null, CancellationToken ct = default)
    {
        store ??= KeyValueStores.Default;
        var current = Cached(store);
        if (!IsStale(current, now)) return current;
        PopularSnapshot fresh;
        try
        {
            fresh = await client.FetchPopularSnapshotAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return current;
        }
        store.SetString(Key, Encode(fresh));
        return fresh;
    }

    /// <summary>The names a segment lists: the live list when present and
    /// non-empty, otherwise the curated seed — capped at <see cref="ListLimit"/>.</summary>
    public static IReadOnlyList<string> Names(PopularSnapshot? snapshot, PopularTagKind kind)
    {
        var all = kind switch
        {
            PopularTagKind.Fandom => Live(snapshot?.Fandoms, PopularTags.Fandoms),
            PopularTagKind.Ship => Live(snapshot?.Ships, PopularTags.Ships),
            _ => Live(snapshot?.Characters, PopularTags.Characters),
        };
        return all.Take(ListLimit).ToList();
    }

    /// <summary>The live list when present and non-empty, otherwise the fallback.</summary>
    public static IReadOnlyList<string> Live(IReadOnlyList<string>? list, IReadOnlyList<string> fallback) =>
        list is { Count: > 0 } ? list : fallback;

    public static string Encode(PopularSnapshot snapshot)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream))
        {
            w.WriteStartObject();
            WriteList(w, "fandoms", snapshot.Fandoms);
            WriteList(w, "ships", snapshot.Ships);
            WriteList(w, "characters", snapshot.Characters);
            w.WriteString("fetchedAt", snapshot.FetchedAt.ToString("O", CultureInfo.InvariantCulture));
            w.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(stream.ToArray());
    }

    /// <summary>Null for anything that isn't a well-formed snapshot (a corrupt or
    /// foreign cache entry reads as "no cache").</summary>
    public static PopularSnapshot? Decode(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!root.TryGetProperty("fetchedAt", out var at) || at.ValueKind != JsonValueKind.String
                || !DateTimeOffset.TryParse(at.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var fetchedAt))
                return null;
            var fandoms = ReadList(root, "fandoms");
            var ships = ReadList(root, "ships");
            var characters = ReadList(root, "characters");
            if (fandoms is null || ships is null || characters is null) return null;
            return new PopularSnapshot(fandoms, ships, characters, fetchedAt);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static void WriteList(Utf8JsonWriter w, string name, IReadOnlyList<string> list)
    {
        w.WriteStartArray(name);
        foreach (var item in list) w.WriteStringValue(item);
        w.WriteEndArray();
    }

    private static List<string>? ReadList(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var array) || array.ValueKind != JsonValueKind.Array) return null;
        var list = new List<string>();
        foreach (var item in array.EnumerateArray())
            if (item.ValueKind == JsonValueKind.String) list.Add(item.GetString()!);
        return list;
    }
}
