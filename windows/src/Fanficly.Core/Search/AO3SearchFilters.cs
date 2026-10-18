using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Fanficly.Core;

public enum TriState { Any, Yes, No }

/// <summary>AO3 rating; the raw value is AO3's tag id.</summary>
public enum Rating { General, Teen, Mature, Explicit, NotRated }

public enum ArchiveWarning { ChooseNotToUse, NoWarningsApply, GraphicViolence, MajorCharacterDeath, RapeNonCon, Underage }

public enum WorkCategory { FF, FM, Gen, MM, Multi, Other }

public enum SortColumn { BestMatch, Author, Title, CreatedAt, RevisedAt, WordCount, Hits, KudosCount, CommentsCount, BookmarksCount }

public enum SortDirection { Asc, Desc }

/// <summary>Raw values and display names, matching the Swift enums' raw values
/// exactly (they're AO3's ids and go into saved JSON).</summary>
public static class SearchEnums
{
    public static IReadOnlyList<Rating> AllRatings { get; } = [Rating.General, Rating.Teen, Rating.Mature, Rating.Explicit, Rating.NotRated];
    public static IReadOnlyList<ArchiveWarning> AllWarnings { get; } =
        [ArchiveWarning.ChooseNotToUse, ArchiveWarning.NoWarningsApply, ArchiveWarning.GraphicViolence,
         ArchiveWarning.MajorCharacterDeath, ArchiveWarning.RapeNonCon, ArchiveWarning.Underage];
    public static IReadOnlyList<WorkCategory> AllCategories { get; } =
        [WorkCategory.FF, WorkCategory.FM, WorkCategory.Gen, WorkCategory.MM, WorkCategory.Multi, WorkCategory.Other];
    public static IReadOnlyList<SortColumn> AllSortColumns { get; } =
        [SortColumn.BestMatch, SortColumn.Author, SortColumn.Title, SortColumn.CreatedAt, SortColumn.RevisedAt,
         SortColumn.WordCount, SortColumn.Hits, SortColumn.KudosCount, SortColumn.CommentsCount, SortColumn.BookmarksCount];

    public static string RawValue(this TriState t) => t switch { TriState.Yes => "yes", TriState.No => "no", _ => "any" };
    public static TriState? ParseTriState(string raw) => raw switch { "any" => TriState.Any, "yes" => TriState.Yes, "no" => TriState.No, _ => null };

    public static string RawValue(this Rating r) => r switch
    {
        Rating.General => "10", Rating.Teen => "11", Rating.Mature => "12", Rating.Explicit => "13", _ => "9",
    };
    public static Rating? ParseRating(string raw) => AllRatings.Cast<Rating?>().FirstOrDefault(r => r!.Value.RawValue() == raw);
    public static string DisplayName(this Rating r) => r switch
    {
        Rating.General => "General Audiences",
        Rating.Teen => "Teen And Up Audiences",
        Rating.Mature => "Mature",
        Rating.Explicit => "Explicit",
        _ => "Not Rated",
    };

    public static string RawValue(this ArchiveWarning w) => w switch
    {
        ArchiveWarning.ChooseNotToUse => "14",
        ArchiveWarning.NoWarningsApply => "16",
        ArchiveWarning.GraphicViolence => "17",
        ArchiveWarning.MajorCharacterDeath => "18",
        ArchiveWarning.RapeNonCon => "19",
        _ => "20",
    };
    public static ArchiveWarning? ParseWarning(string raw) => AllWarnings.Cast<ArchiveWarning?>().FirstOrDefault(w => w!.Value.RawValue() == raw);
    public static string DisplayName(this ArchiveWarning w) => w switch
    {
        ArchiveWarning.ChooseNotToUse => "Creator Chose Not To Use Archive Warnings",
        ArchiveWarning.NoWarningsApply => "No Archive Warnings Apply",
        ArchiveWarning.GraphicViolence => "Graphic Depictions Of Violence",
        ArchiveWarning.MajorCharacterDeath => "Major Character Death",
        ArchiveWarning.RapeNonCon => "Rape/Non-Con",
        _ => "Underage",
    };

    public static string RawValue(this WorkCategory c) => c switch
    {
        WorkCategory.FF => "116", WorkCategory.FM => "22", WorkCategory.Gen => "21",
        WorkCategory.MM => "23", WorkCategory.Multi => "2246", _ => "24",
    };
    public static WorkCategory? ParseCategory(string raw) => AllCategories.Cast<WorkCategory?>().FirstOrDefault(c => c!.Value.RawValue() == raw);
    public static string DisplayName(this WorkCategory c) => c switch
    {
        WorkCategory.FF => "F/F", WorkCategory.FM => "F/M", WorkCategory.Gen => "Gen",
        WorkCategory.MM => "M/M", WorkCategory.Multi => "Multi", _ => "Other",
    };

    public static string RawValue(this SortColumn s) => s switch
    {
        SortColumn.BestMatch => "_score",
        SortColumn.Author => "authors_to_sort_on",
        SortColumn.Title => "title_to_sort_on",
        SortColumn.CreatedAt => "created_at",
        SortColumn.RevisedAt => "revised_at",
        SortColumn.WordCount => "word_count",
        SortColumn.Hits => "hits",
        SortColumn.KudosCount => "kudos_count",
        SortColumn.CommentsCount => "comments_count",
        _ => "bookmarks_count",
    };
    public static SortColumn? ParseSortColumn(string raw) => AllSortColumns.Cast<SortColumn?>().FirstOrDefault(s => s!.Value.RawValue() == raw);
    public static string DisplayName(this SortColumn s) => s switch
    {
        SortColumn.BestMatch => "Best Match",
        SortColumn.Author => "Author",
        SortColumn.Title => "Title",
        SortColumn.CreatedAt => "Date Posted",
        SortColumn.RevisedAt => "Date Updated",
        SortColumn.WordCount => "Word Count",
        SortColumn.Hits => "Hits",
        SortColumn.KudosCount => "Kudos",
        SortColumn.CommentsCount => "Comments",
        _ => "Bookmarks",
    };

    public static string RawValue(this SortDirection d) => d == SortDirection.Asc ? "asc" : "desc";
    public static SortDirection? ParseSortDirection(string raw) => raw switch { "asc" => SortDirection.Asc, "desc" => SortDirection.Desc, _ => null };
    public static string DisplayName(this SortDirection d) => d == SortDirection.Asc ? "Ascending" : "Descending";
    /// <summary>Icon id (SF Symbol name; the app maps it to a Fluent glyph).</summary>
    public static string Symbol(this SortDirection d) => d == SortDirection.Asc ? "arrow.up" : "arrow.down";
}

/// <summary>1:1 mapping of AO3's <c>/works/search</c> form. A mutable value-like
/// class: use <see cref="Clone"/> before mutating a copy (Swift's struct copy).</summary>
public sealed class AO3SearchFilters : IEquatable<AO3SearchFilters>
{
    public string Query { get; set; } = "";
    public string Title { get; set; } = "";
    public string Creators { get; set; } = "";
    public string RevisedAt { get; set; } = "";
    public TriState Complete { get; set; } = TriState.Any;
    public TriState Crossover { get; set; } = TriState.Any;
    public bool SingleChapter { get; set; }
    public string WordCount { get; set; } = "";
    public string LanguageId { get; set; } = "";
    public List<string> FandomNames { get; set; } = [];
    public List<string> CharacterNames { get; set; } = [];
    public List<string> RelationshipNames { get; set; } = [];
    public List<string> FreeformNames { get; set; } = [];
    /// <summary>Canonical tags of any kind (fandom, character, ship or trope), as
    /// picked from search suggestions → <c>work_search[other_tag_names]</c>, which
    /// AO3 matches against every tag type.</summary>
    public List<string> OtherTagNames { get; set; } = [];
    /// <summary>Canonical tags to exclude → <c>work_search[excluded_tag_names]</c>.</summary>
    public List<string> ExcludedTagNames { get; set; } = [];
    public List<string> ExcludedFreeforms { get; set; } = [];
    public HashSet<Rating> Ratings { get; set; } = [];
    public HashSet<ArchiveWarning> Warnings { get; set; } = [];
    public HashSet<WorkCategory> Categories { get; set; } = [];
    public string Hits { get; set; } = "";
    public string KudosCount { get; set; } = "";
    public string CommentsCount { get; set; } = "";
    public string BookmarksCount { get; set; } = "";
    public SortColumn SortColumn { get; set; } = SortColumn.BestMatch;
    public SortDirection SortDirection { get; set; } = SortDirection.Desc;

    public AO3SearchFilters Clone() => new()
    {
        Query = Query, Title = Title, Creators = Creators, RevisedAt = RevisedAt,
        Complete = Complete, Crossover = Crossover, SingleChapter = SingleChapter,
        WordCount = WordCount, LanguageId = LanguageId,
        FandomNames = [.. FandomNames], CharacterNames = [.. CharacterNames],
        RelationshipNames = [.. RelationshipNames], FreeformNames = [.. FreeformNames],
        OtherTagNames = [.. OtherTagNames], ExcludedTagNames = [.. ExcludedTagNames],
        ExcludedFreeforms = [.. ExcludedFreeforms],
        Ratings = [.. Ratings], Warnings = [.. Warnings], Categories = [.. Categories],
        Hits = Hits, KudosCount = KudosCount, CommentsCount = CommentsCount, BookmarksCount = BookmarksCount,
        SortColumn = SortColumn, SortDirection = SortDirection,
    };

    public bool IsEmpty =>
        Query.Length == 0 && Title.Length == 0 && Creators.Length == 0 && RevisedAt.Length == 0 &&
        Complete == TriState.Any && Crossover == TriState.Any && !SingleChapter &&
        WordCount.Length == 0 && LanguageId.Length == 0 &&
        FandomNames.Count == 0 && CharacterNames.Count == 0 && RelationshipNames.Count == 0 &&
        FreeformNames.Count == 0 && OtherTagNames.Count == 0 && ExcludedTagNames.Count == 0 &&
        ExcludedFreeforms.Count == 0 && Ratings.Count == 0 && Warnings.Count == 0 && Categories.Count == 0 &&
        Hits.Length == 0 && KudosCount.Length == 0 && CommentsCount.Length == 0 && BookmarksCount.Length == 0;

    /// <summary>The filters as search-box text (explicit <c>key:value</c> tokens after
    /// the keywords) — what saved searches, recents and deep links store.
    /// <c>SearchSyntax.Parse</c> reads it back exactly.</summary>
    public string PromptText() => SearchSyntax.Render(this);

    internal static string WordCountPhrase(string wc)
    {
        if (wc.StartsWith('>')) return $"over {wc[1..]}";
        if (wc.StartsWith('<')) return $"under {wc[1..]}";
        if (wc.Contains('-'))
        {
            var p = wc.Split('-', StringSplitOptions.RemoveEmptyEntries);
            if (p.Length == 2) return $"between {p[0]} and {p[1]}";
        }
        return $"{wc} words";
    }

    /// <summary>A human-readable default name for a saved filter, built from the
    /// selected tags and options. Fandom names are intentionally excluded — saved
    /// filters are fandom-agnostic (see <see cref="SavedJson"/>) — and the result is
    /// capped to the few most identifying parts so it stays a short title.</summary>
    public string SuggestedName()
    {
        var parts = new List<string>();
        parts.AddRange(RelationshipNames);
        parts.AddRange(CharacterNames);
        parts.AddRange(FreeformNames);
        parts.AddRange(Ratings.OrderBy(r => r.RawValue(), StringComparer.Ordinal).Select(r => r.DisplayName()));
        parts.AddRange(Categories.OrderBy(c => c.RawValue(), StringComparer.Ordinal).Select(c => c.DisplayName()));
        if (Complete == TriState.Yes) parts.Add("Complete");
        else if (Complete == TriState.No) parts.Add("WIP");
        if (SingleChapter) parts.Add("Oneshot");
        if (Crossover == TriState.Yes) parts.Add("Crossover");
        if (WordCount.Length > 0) parts.Add(WordCountPhrase(WordCount));
        return string.Join(" · ", parts.Take(4));
    }

    /// <summary>JSON for persisting a saved filter (fandom names excluded so the
    /// config can be applied to any fandom). Same shape as the Swift app's
    /// <c>JSONEncoder</c> output, so saved filters sync between platforms.</summary>
    public string SavedJson()
    {
        var copy = Clone();
        copy.FandomNames = [];
        return copy.ToJson();
    }

    public static AO3SearchFilters? FromSavedJson(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.ValueKind == JsonValueKind.Object ? FromJson(doc.RootElement) : null;
        }
        catch (JsonException) { return null; }
    }

    public string ToJson()
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream))
        {
            WriteJson(w);
        }
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    public void WriteJson(Utf8JsonWriter w)
    {
        w.WriteStartObject();
        w.WriteString("query", Query);
        w.WriteString("title", Title);
        w.WriteString("creators", Creators);
        w.WriteString("revisedAt", RevisedAt);
        w.WriteString("complete", Complete.RawValue());
        w.WriteString("crossover", Crossover.RawValue());
        w.WriteBoolean("singleChapter", SingleChapter);
        w.WriteString("wordCount", WordCount);
        w.WriteString("languageId", LanguageId);
        WriteList(w, "fandomNames", FandomNames);
        WriteList(w, "characterNames", CharacterNames);
        WriteList(w, "relationshipNames", RelationshipNames);
        WriteList(w, "freeformNames", FreeformNames);
        WriteList(w, "otherTagNames", OtherTagNames);
        WriteList(w, "excludedTagNames", ExcludedTagNames);
        WriteList(w, "excludedFreeforms", ExcludedFreeforms);
        WriteList(w, "ratings", Ratings.Select(r => r.RawValue()).OrderBy(s => s, StringComparer.Ordinal));
        WriteList(w, "warnings", Warnings.Select(r => r.RawValue()).OrderBy(s => s, StringComparer.Ordinal));
        WriteList(w, "categories", Categories.Select(r => r.RawValue()).OrderBy(s => s, StringComparer.Ordinal));
        w.WriteString("hits", Hits);
        w.WriteString("kudosCount", KudosCount);
        w.WriteString("commentsCount", CommentsCount);
        w.WriteString("bookmarksCount", BookmarksCount);
        w.WriteString("sortColumn", SortColumn.RawValue());
        w.WriteString("sortDirection", SortDirection.RawValue());
        w.WriteEndObject();
    }

    private static void WriteList(Utf8JsonWriter w, string name, IEnumerable<string> values)
    {
        w.WriteStartArray(name);
        foreach (var v in values) w.WriteStringValue(v);
        w.WriteEndArray();
    }

    /// <summary>Tolerant decoding: any missing or unreadable field keeps its
    /// default, so filters saved before a field existed still load instead of
    /// failing the whole decode and losing the saved filter.</summary>
    public static AO3SearchFilters FromJson(JsonElement o)
    {
        var f = new AO3SearchFilters();
        string Str(string key, string fallback) =>
            o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? fallback : fallback;
        List<string> List(string key, List<string> fallback)
        {
            if (!o.TryGetProperty(key, out var v) || v.ValueKind != JsonValueKind.Array) return fallback;
            var result = new List<string>();
            foreach (var item in v.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String) return fallback;
                result.Add(item.GetString() ?? "");
            }
            return result;
        }
        HashSet<T> Set<T>(string key, HashSet<T> fallback, Func<string, T?> parse) where T : struct
        {
            if (!o.TryGetProperty(key, out var v) || v.ValueKind != JsonValueKind.Array) return fallback;
            var result = new HashSet<T>();
            foreach (var item in v.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String) return fallback;
                var parsed = parse(item.GetString() ?? "");
                if (parsed is null) return fallback;
                result.Add(parsed.Value);
            }
            return result;
        }

        f.Query = Str("query", f.Query);
        f.Title = Str("title", f.Title);
        f.Creators = Str("creators", f.Creators);
        f.RevisedAt = Str("revisedAt", f.RevisedAt);
        f.Complete = SearchEnums.ParseTriState(Str("complete", "")) ?? f.Complete;
        f.Crossover = SearchEnums.ParseTriState(Str("crossover", "")) ?? f.Crossover;
        if (o.TryGetProperty("singleChapter", out var sc) && sc.ValueKind is JsonValueKind.True or JsonValueKind.False)
            f.SingleChapter = sc.GetBoolean();
        f.WordCount = Str("wordCount", f.WordCount);
        f.LanguageId = Str("languageId", f.LanguageId);
        f.FandomNames = List("fandomNames", f.FandomNames);
        f.CharacterNames = List("characterNames", f.CharacterNames);
        f.RelationshipNames = List("relationshipNames", f.RelationshipNames);
        f.FreeformNames = List("freeformNames", f.FreeformNames);
        f.OtherTagNames = List("otherTagNames", f.OtherTagNames);
        f.ExcludedTagNames = List("excludedTagNames", f.ExcludedTagNames);
        f.ExcludedFreeforms = List("excludedFreeforms", f.ExcludedFreeforms);
        f.Ratings = Set("ratings", f.Ratings, SearchEnums.ParseRating);
        f.Warnings = Set("warnings", f.Warnings, SearchEnums.ParseWarning);
        f.Categories = Set("categories", f.Categories, SearchEnums.ParseCategory);
        f.Hits = Str("hits", f.Hits);
        f.KudosCount = Str("kudosCount", f.KudosCount);
        f.CommentsCount = Str("commentsCount", f.CommentsCount);
        f.BookmarksCount = Str("bookmarksCount", f.BookmarksCount);
        f.SortColumn = SearchEnums.ParseSortColumn(Str("sortColumn", "")) ?? f.SortColumn;
        f.SortDirection = SearchEnums.ParseSortDirection(Str("sortDirection", "")) ?? f.SortDirection;
        return f;
    }

    /// <summary>The <c>/works/search</c> query items, in AO3's form order.</summary>
    public IReadOnlyList<KeyValuePair<string, string>> QueryItems()
    {
        var items = new List<KeyValuePair<string, string>>();
        void Add(string k, string v) => items.Add(new(k, v));
        var composed = ComposedQueryString();
        if (composed.Length > 0) Add("work_search[query]", composed);
        if (Title.Length > 0) Add("work_search[title]", Title);
        if (Creators.Length > 0) Add("work_search[creators]", Creators);
        if (RevisedAt.Length > 0) Add("work_search[revised_at]", RevisedAt);
        if (Complete == TriState.Yes) Add("work_search[complete]", "true");
        else if (Complete == TriState.No) Add("work_search[complete]", "false");
        if (Crossover == TriState.Yes) Add("work_search[crossover]", "T");
        else if (Crossover == TriState.No) Add("work_search[crossover]", "F");
        if (SingleChapter) Add("work_search[single_chapter]", "1");
        if (WordCount.Length > 0) Add("work_search[word_count]", WordCount);
        if (LanguageId.Length > 0) Add("work_search[language_id]", LanguageId);
        if (FandomNames.Count > 0) Add("work_search[fandom_names]", string.Join(", ", FandomNames));
        if (CharacterNames.Count > 0) Add("work_search[character_names]", string.Join(", ", CharacterNames));
        if (RelationshipNames.Count > 0) Add("work_search[relationship_names]", string.Join(", ", RelationshipNames));
        if (FreeformNames.Count > 0) Add("work_search[freeform_names]", string.Join(", ", FreeformNames));
        if (OtherTagNames.Count > 0) Add("work_search[other_tag_names]", string.Join(", ", OtherTagNames));
        if (ExcludedTagNames.Count > 0) Add("work_search[excluded_tag_names]", string.Join(", ", ExcludedTagNames));
        // A single rating uses AO3's dedicated form field; 2+ ratings are OR-ed
        // via the query field in ComposedQueryString(), because the array form
        // AND-matches and returns nothing.
        if (Ratings.Count == 1) Add("work_search[rating_ids]", Ratings.First().RawValue());
        foreach (var w in Warnings.Select(w => w.RawValue()).OrderBy(s => s, StringComparer.Ordinal))
            Add("work_search[archive_warning_ids][]", w);
        foreach (var c in Categories.Select(c => c.RawValue()).OrderBy(s => s, StringComparer.Ordinal))
            Add("work_search[category_ids][]", c);
        if (Hits.Length > 0) Add("work_search[hits]", Hits);
        if (KudosCount.Length > 0) Add("work_search[kudos_count]", KudosCount);
        if (CommentsCount.Length > 0) Add("work_search[comments_count]", CommentsCount);
        if (BookmarksCount.Length > 0) Add("work_search[bookmarks_count]", BookmarksCount);
        Add("work_search[sort_column]", SortColumn.RawValue());
        Add("work_search[sort_direction]", SortDirection.RawValue());
        return items;
    }

    internal string ComposedQueryString()
    {
        var parts = new List<string>();
        if (Query.Length > 0) parts.Add(Query);
        foreach (var excluded in ExcludedFreeforms)
        {
            var quoted = excluded.Contains(' ') ? $"\"{excluded}\"" : excluded;
            parts.Add($"NOT {quoted}");
        }
        // AO3's Rating field is a single-select, so a rating_ids[] array is
        // AND-ed and matches nothing (every work has exactly one rating). To OR
        // multiple ratings we fold them into the query field instead —
        // `(rating_ids:12 OR rating_ids:13)` — which AO3's search honors.
        if (Ratings.Count > 1)
        {
            var clause = string.Join(" OR ", Ratings.Select(r => r.RawValue()).OrderBy(s => s, StringComparer.Ordinal)
                .Select(id => $"rating_ids:{id}"));
            parts.Add($"({clause})");
        }
        return string.Join(" ", parts);
    }

    /// <summary>Folds <paramref name="other"/>'s filters into a copy of these (lists
    /// and sets union, set scalars win). The search box uses this to move tokens
    /// typed as text into the active filter chips; <c>other.Query</c> is ignored.</summary>
    public AO3SearchFilters Merging(AO3SearchFilters other)
    {
        var m = Clone();
        static List<string> Union(List<string> a, List<string> b)
        {
            var list = new List<string>(a);
            foreach (var item in b)
                if (!list.Any(x => string.Equals(x, item, StringComparison.OrdinalIgnoreCase))) list.Add(item);
            return list;
        }
        if (other.Title.Length > 0) m.Title = other.Title;
        if (other.Creators.Length > 0) m.Creators = other.Creators;
        if (other.RevisedAt.Length > 0) m.RevisedAt = other.RevisedAt;
        if (other.Complete != TriState.Any) m.Complete = other.Complete;
        if (other.Crossover != TriState.Any) m.Crossover = other.Crossover;
        if (other.SingleChapter) m.SingleChapter = true;
        if (other.WordCount.Length > 0) m.WordCount = other.WordCount;
        if (other.LanguageId.Length > 0) m.LanguageId = other.LanguageId;
        m.FandomNames = Union(m.FandomNames, other.FandomNames);
        m.CharacterNames = Union(m.CharacterNames, other.CharacterNames);
        m.RelationshipNames = Union(m.RelationshipNames, other.RelationshipNames);
        m.FreeformNames = Union(m.FreeformNames, other.FreeformNames);
        m.OtherTagNames = Union(m.OtherTagNames, other.OtherTagNames);
        m.ExcludedTagNames = Union(m.ExcludedTagNames, other.ExcludedTagNames);
        m.ExcludedFreeforms = Union(m.ExcludedFreeforms, other.ExcludedFreeforms);
        m.Ratings.UnionWith(other.Ratings);
        m.Warnings.UnionWith(other.Warnings);
        m.Categories.UnionWith(other.Categories);
        if (other.Hits.Length > 0) m.Hits = other.Hits;
        if (other.KudosCount.Length > 0) m.KudosCount = other.KudosCount;
        if (other.CommentsCount.Length > 0) m.CommentsCount = other.CommentsCount;
        if (other.BookmarksCount.Length > 0) m.BookmarksCount = other.BookmarksCount;
        return m;
    }

    /// <summary>"Under 10,000 words" for <c>&lt;10000</c>, "1,000–5,000 words" for a range.</summary>
    public static string WordCountLabel(string range)
    {
        static string N(string s) => int.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out var n)
            ? n.ToString("N0", CultureInfo.CurrentCulture) : s;
        if (range.StartsWith('<')) return $"Under {N(range[1..])} words";
        if (range.StartsWith('>')) return $"Over {N(range[1..])} words";
        var parts = range.Split('-', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 2) return $"{N(parts[0])}–{N(parts[1])} words";
        return $"{N(range)} words";
    }

    public bool Equals(AO3SearchFilters? o) =>
        o is not null &&
        Query == o.Query && Title == o.Title && Creators == o.Creators && RevisedAt == o.RevisedAt &&
        Complete == o.Complete && Crossover == o.Crossover && SingleChapter == o.SingleChapter &&
        WordCount == o.WordCount && LanguageId == o.LanguageId &&
        FandomNames.SequenceEqual(o.FandomNames) && CharacterNames.SequenceEqual(o.CharacterNames) &&
        RelationshipNames.SequenceEqual(o.RelationshipNames) && FreeformNames.SequenceEqual(o.FreeformNames) &&
        OtherTagNames.SequenceEqual(o.OtherTagNames) && ExcludedTagNames.SequenceEqual(o.ExcludedTagNames) &&
        ExcludedFreeforms.SequenceEqual(o.ExcludedFreeforms) &&
        Ratings.SetEquals(o.Ratings) && Warnings.SetEquals(o.Warnings) && Categories.SetEquals(o.Categories) &&
        Hits == o.Hits && KudosCount == o.KudosCount && CommentsCount == o.CommentsCount &&
        BookmarksCount == o.BookmarksCount && SortColumn == o.SortColumn && SortDirection == o.SortDirection;

    public override bool Equals(object? obj) => Equals(obj as AO3SearchFilters);
    public override int GetHashCode() => HashCode.Combine(Query, Title, Creators, FandomNames.Count, OtherTagNames.Count, SortColumn);
    public static bool operator ==(AO3SearchFilters? a, AO3SearchFilters? b) => a?.Equals(b) ?? b is null;
    public static bool operator !=(AO3SearchFilters? a, AO3SearchFilters? b) => !(a == b);
}
