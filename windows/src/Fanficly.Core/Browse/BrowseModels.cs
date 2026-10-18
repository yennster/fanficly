using System.Globalization;

namespace Fanficly.Core;

/// <summary>The view logic of the Browse screens (BrowseView.swift), kept pure
/// so it's testable without the UI: what a filtered-works screen starts from,
/// its active-filter chips, and the category fandom list's source, search
/// and header.</summary>
public static class BrowseModels
{
    // MARK: - FandomWorksView inits

    /// <summary>A fandom picked from a category list: newest updates first
    /// (<c>FandomWorksView(fandom:)</c>).</summary>
    public static AO3SearchFilters FiltersForFandom(BrowseFandom fandom) => new()
    {
        FandomNames = [fandom.CanonicalName],
        SortColumn = SortColumn.RevisedAt,
        SortDirection = SortDirection.Desc,
    };

    /// <summary>A fandom-agnostic saved filter from the Browse landing page
    /// (<c>FandomWorksView(savedFilter:)</c>); unreadable JSON runs as no filters.</summary>
    public static AO3SearchFilters FiltersForSavedFilter(SavedFilter saved) =>
        AO3SearchFilters.FromSavedJson(saved.FiltersJson) ?? new AO3SearchFilters();

    // MARK: - Active filters

    /// <summary>The chips over the results: sort first, then each active filter.</summary>
    public static IReadOnlyList<string> FilterChips(AO3SearchFilters filters)
    {
        var chips = new List<string>
        {
            $"{filters.SortColumn.DisplayName()} {(filters.SortDirection == SortDirection.Asc ? "↑" : "↓")}",
        };
        chips.AddRange(SearchEnums.AllRatings.Where(filters.Ratings.Contains).Select(r => r.DisplayName()));
        chips.AddRange(SearchEnums.AllWarnings.Where(filters.Warnings.Contains).Select(w => w.DisplayName()));
        chips.AddRange(SearchEnums.AllCategories.Where(filters.Categories.Contains).Select(c => c.DisplayName()));
        chips.AddRange(filters.RelationshipNames);
        chips.AddRange(filters.CharacterNames);
        chips.AddRange(filters.FreeformNames);
        chips.AddRange(filters.ExcludedFreeforms.Select(t => $"−{t}"));
        switch (filters.Complete)
        {
            case TriState.Yes: chips.Add("Complete"); break;
            case TriState.No: chips.Add("WIP"); break;
        }
        switch (filters.Crossover)
        {
            case TriState.Yes: chips.Add("Crossovers only"); break;
            case TriState.No: chips.Add("No crossovers"); break;
        }
        if (filters.SingleChapter) chips.Add("Oneshot");
        if (filters.WordCount.Length > 0) chips.Add($"words {filters.WordCount}");
        if (filters.LanguageId.Length > 0) chips.Add($"lang {filters.LanguageId}");
        return chips;
    }

    /// <summary>How many filters the sheet has set (the toolbar button's badge).</summary>
    public static int ActiveFilterCount(AO3SearchFilters f) =>
        f.Ratings.Count + f.Warnings.Count + f.Categories.Count
        + f.RelationshipNames.Count + f.CharacterNames.Count
        + f.FreeformNames.Count + f.ExcludedFreeforms.Count
        + (f.Complete != TriState.Any ? 1 : 0)
        + (f.Crossover != TriState.Any ? 1 : 0)
        + (f.SingleChapter ? 1 : 0)
        + (f.WordCount.Length == 0 ? 0 : 1)
        + (f.LanguageId.Length == 0 ? 0 : 1);

    // MARK: - Filter sheet text fields

    /// <summary>Comma-separated tags → trimmed, non-empty tags.</summary>
    public static List<string> SplitTags(string text) =>
        text.Split(',').Select(t => t.Trim()).Where(t => t.Length > 0).ToList();

    /// <summary>"from-to" / "&gt;from" / "&lt;to" / "" from the sheet's two fields.</summary>
    public static string BuildWordCount(string from, string to)
    {
        from = from.Trim();
        to = to.Trim();
        return (from.Length > 0, to.Length > 0) switch
        {
            (true, true) => $"{from}-{to}",
            (true, false) => $">{from}",
            (false, true) => $"<{to}",
            _ => "",
        };
    }

    /// <summary>An existing word count back into the sheet's From / To fields.</summary>
    public static (string From, string To) ParseWordCount(string wordCount)
    {
        if (wordCount.Contains('-'))
        {
            var parts = wordCount.Split('-', StringSplitOptions.RemoveEmptyEntries);
            return (parts.Length > 0 ? parts[0] : "", parts.Length > 1 ? parts[1] : "");
        }
        if (wordCount.StartsWith('>')) return (wordCount[1..], "");
        if (wordCount.StartsWith('<')) return ("", wordCount[1..]);
        return ("", "");
    }

    /// <summary>The sheet's Language picker: AO3 language id → name ("" = Any).</summary>
    public static IReadOnlyList<(string Id, string Name)> Languages { get; } =
    [
        ("", "Any"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("zh", "Chinese"), ("ru", "Russian"), ("pt", "Portuguese"), ("it", "Italian"),
        ("ja", "Japanese"), ("ko", "Korean"),
    ];

    // MARK: - CategoryFandomsView

    /// <summary>The source list: live data once loaded, otherwise the curated seed
    /// — but only as a fallback after the live fetch fails, never during loading
    /// (which would flash the short list then swap).</summary>
    public static IReadOnlyList<BrowseFandom> FandomSource(IReadOnlyList<BrowseFandom> live, bool failed, FandomCategory category)
    {
        if (live.Count > 0) return live;
        if (failed) return category.Fandoms;
        return [];
    }

    /// <summary>The fandoms whose display name contains the query (case-insensitive,
    /// culture-aware, like <c>localizedCaseInsensitiveContains</c>).</summary>
    public static IReadOnlyList<BrowseFandom> FilterFandoms(IReadOnlyList<BrowseFandom> source, string query)
    {
        var trimmed = query.Trim();
        if (trimmed.Length == 0) return source;
        var compare = CultureInfo.CurrentCulture.CompareInfo;
        return source.Where(f => compare.IndexOf(f.DisplayName, trimmed, CompareOptions.IgnoreCase) >= 0).ToList();
    }

    /// <summary>"12 of 3,402 fandoms" over a live list, "12 popular fandoms" over the seed.</summary>
    public static string FandomHeader(int displayed, int liveCount) =>
        liveCount > 0 ? $"{displayed} of {liveCount} fandoms" : $"{displayed} popular fandoms";

    /// <summary>The note shown over the curated seed when the live list failed.</summary>
    public static string FandomLoadError(Exception error) =>
        error is AO3Exception { Kind: AO3ErrorKind.Http, Status: 404 }
            ? "AO3 didn't recognise that category. Showing popular fandoms only."
            : $"Couldn't load full list ({error.Message}). Showing popular fandoms only.";
}
