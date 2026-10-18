using System.Text;
using System.Text.RegularExpressions;

namespace Fanficly.Core;

/// <summary>
/// Turns the search box text into <see cref="AO3SearchFilters"/>, and filters back
/// into text (<see cref="Render"/>) for saved searches, recents and deep links.
///
/// The rule that matters: <b>ordinary words stay keywords.</b> Whatever isn't
/// recognized goes to AO3's own full-text search (<c>work_search[query]</c>). Only
/// two things become filters:
/// 1. Explicit <c>key:value</c> tokens (<c>tag:"Slow Burn"</c>, <c>rating:explicit</c>,
///    <c>title:…</c>, <c>by:…</c>, …). Nobody types those by accident, and Render
///    emits them, so saved searches round-trip exactly.
/// 2. A short list of phrases that only ever mean a filter: "complete", "wip",
///    "one shot", "explicit", "nsfw", "m/m", "under 10k", "in spanish", "no
///    crossovers", "no mcd". These have to be filters because AO3 requires every
///    keyword to match.
///
/// Fandoms, characters, ships and tropes are never guessed from words; the
/// suggestion row offers their exact AO3 tags instead.
/// </summary>
public static class SearchSyntax
{
    // MARK: - Parse

    public static AO3SearchFilters Parse(string text)
    {
        var filters = new AO3SearchFilters();
        var working = NormalizeQuotes(text);
        working = ExtractKeyValues(working, filters);
        working = ExtractPhrases(working, filters);
        filters.Query = CollapseWhitespace(working);
        return filters;
    }

    /// <summary>Straight quotes only, so <c>title:“Foo Bar”</c> from a smart-quote keyboard works.</summary>
    public static string NormalizeQuotes(string s) =>
        s.Replace('“', '"').Replace('”', '"').Replace('‘', '\'').Replace('’', '\'');

    private static readonly Regex KeyValuePattern = new(
        """(?<![\w-])(-?[a-z]+):(?:"([^"]*)"|([^\s"]+))""",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static string ExtractKeyValues(string working, AO3SearchFilters filters)
    {
        var consumed = new List<(int Start, int Length)>();
        foreach (Match match in KeyValuePattern.Matches(working))
        {
            var key = match.Groups[1].Value.ToLowerInvariant();
            var value = match.Groups[2].Success ? match.Groups[2].Value : match.Groups[3].Value;
            if (Apply(key, value.Trim(' '), filters)) consumed.Add((match.Index, match.Length));
        }
        return Removing(consumed, working);
    }

    /// <summary>Applies one <c>key:value</c>; false leaves the token in the text
    /// (unknown keys like AO3's own <c>rating_ids:12</c> pass straight through).</summary>
    private static bool Apply(string key, string value, AO3SearchFilters f)
    {
        if (value.Length == 0) return false;
        switch (key)
        {
            case "title": f.Title = value; break;
            case "by" or "author" or "creator" or "creators": f.Creators = value; break;
            case "tag": AppendUnique(value, f.OtherTagNames); break;
            case "-tag": AppendUnique(value, f.ExcludedTagNames); break;
            case "fandom": AppendUnique(value, f.FandomNames); break;
            case "ship" or "relationship": AppendUnique(value, f.RelationshipNames); break;
            case "character": AppendUnique(value, f.CharacterNames); break;
            case "freeform": AppendUnique(value, f.FreeformNames); break;
            case "exclude": AppendUnique(value, f.ExcludedFreeforms); break;
            case "rating":
                if (RatingNamed(value) is not { } rating) return false;
                f.Ratings.Add(rating); break;
            case "warning":
                if (WarningNamed(value) is not { } warning) return false;
                f.Warnings.Add(warning); break;
            case "category":
                if (CategoryNamed(value) is not { } category) return false;
                f.Categories.Add(category); break;
            case "complete" or "status":
                if (Completion(value) is not { } state) return false;
                f.Complete = state; break;
            case "crossover":
                if (YesNo(value) is not { } cross) return false;
                f.Crossover = cross; break;
            case "oneshot":
                if (YesNo(value) is not { } one) return false;
                f.SingleChapter = one == TriState.Yes; break;
            case "words":
                if (NumericRange(value) is not { } words) return false;
                f.WordCount = words; break;
            case "lang" or "language":
                if (LanguageCode(value) is not { } code) return false;
                f.LanguageId = code; break;
            case "kudos":
                if (NumericRange(value) is not { } kudos) return false;
                f.KudosCount = kudos; break;
            case "hits":
                if (NumericRange(value) is not { } hits) return false;
                f.Hits = hits; break;
            case "comments":
                if (NumericRange(value) is not { } comments) return false;
                f.CommentsCount = comments; break;
            case "bookmarks":
                if (NumericRange(value) is not { } bookmarks) return false;
                f.BookmarksCount = bookmarks; break;
            case "updated": f.RevisedAt = value; break;
            default: return false;
        }
        return true;
    }

    // MARK: Phrases that only ever mean a filter

    private sealed record Phrase(Regex Regex, Func<Match, AO3SearchFilters, bool> Apply);

    private static Phrase P(string pattern, Func<Match, AO3SearchFilters, bool> apply) =>
        new(new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), apply);

    /// <summary>Order matters: longer / negated forms run before the shorter ones
    /// they contain ("no crossovers" before "crossover").</summary>
    private static readonly Phrase[] Phrases =
    [
        P(@"\bno\s+crossovers?\b", (_, f) => { f.Crossover = TriState.No; return true; }),
        P(@"\bcrossovers?\b", (_, f) => { f.Crossover = TriState.Yes; return true; }),
        P(@"\b(?:wips?|incomplete|works?\s+in\s+progress)\b", (_, f) => { f.Complete = TriState.No; return true; }),
        P(@"\bcomplete(?:d)?\b", (_, f) => { f.Complete = TriState.Yes; return true; }),
        P(@"\bone[\s-]?shots?\b", (_, f) => { f.SingleChapter = true; return true; }),
        P(@"\bnsfw\b", (_, f) => { f.Ratings.UnionWith([Rating.Mature, Rating.Explicit]); return true; }),
        P(@"\bsfw\b", (_, f) => { f.Ratings.UnionWith([Rating.General, Rating.Teen]); return true; }),
        P(@"\brated\s+(general|teen|mature|explicit|g|t|m|e)\b", (m, f) =>
        {
            if (RatingNamed(m.Groups[1].Value) is not { } r) return false;
            f.Ratings.Add(r); return true;
        }),
        P(@"\b([gtme])-rated\b", (m, f) =>
        {
            if (RatingNamed(m.Groups[1].Value) is not { } r) return false;
            f.Ratings.Add(r); return true;
        }),
        P(@"\bteen\s+and\s+up(?:\s+audiences)?\b", (_, f) => { f.Ratings.Add(Rating.Teen); return true; }),
        P(@"\bgeneral\s+audiences\b", (_, f) => { f.Ratings.Add(Rating.General); return true; }),
        P(@"\b(?:not\s+rated|unrated)\b", (_, f) => { f.Ratings.Add(Rating.NotRated); return true; }),
        P(@"\bexplicit\b", (_, f) => { f.Ratings.Add(Rating.Explicit); return true; }),
        P(@"(?<![\w/])(m/m|f/f|f/m)(?![\w/])", (m, f) =>
        {
            if (CategoryNamed(m.Groups[1].Value) is not { } c) return false;
            f.Categories.Add(c); return true;
        }),
        P(@"\bfemslash\b", (_, f) => { f.Categories.Add(WorkCategory.FF); return true; }),
        P(@"\bno\s+(?:archive\s+)?warnings(?:\s+apply)?\b", (_, f) => { f.Warnings.Add(ArchiveWarning.NoWarningsApply); return true; }),
        P(@"\bno\s+(?:mcd|major\s+character\s+death)\b", (_, f) => { AppendUnique("Major Character Death", f.ExcludedTagNames); return true; }),
        P(@"\bbetween\s+(\d+)\s*(k|,000)?\s*(?:words?\s+)?and\s+(\d+)\s*(k|,000)?\s*(words?)?\b", (m, f) =>
        {
            var hasUnit = m.Groups[2].Success || m.Groups[4].Success || m.Groups[5].Success;
            if (!hasUnit || Number(m, 1, 2) is not { } lo || Number(m, 3, 4) is not { } hi) return false;
            // "between 10 and 50k" means 10k–50k.
            var low = !m.Groups[2].Success && m.Groups[4].Success ? lo * 1_000 : lo;
            f.WordCount = $"{Math.Min(low, hi)}-{Math.Max(low, hi)}"; return true;
        }),
        P(@"\b(under|less\s+than|fewer\s+than|below|over|more\s+than|above)\s+(\d+)\s*(k|,000)?\s*(words?)?(?!\w)", (m, f) =>
        {
            var hasUnit = m.Groups[3].Success || m.Groups[4].Success;
            if (!hasUnit || Number(m, 2, 3) is not { } n) return false;
            var word = m.Groups[1].Value.ToLowerInvariant();
            var isMax = word.StartsWith("under") || word.StartsWith("less") || word.StartsWith("fewer") || word.StartsWith("below");
            f.WordCount = isMax ? $"<{n}" : $">{n}"; return true;
        }),
        P(@"\b(?:in\s+(english|spanish|french|german|russian|chinese|japanese|korean|portuguese|italian)|en\s+español|en\s+français|auf\s+deutsch)\b", (m, f) =>
        {
            var whole = m.Value.ToLowerInvariant();
            var name = m.Groups[1].Success ? m.Groups[1].Value.ToLowerInvariant() : whole;
            if ((LanguageCode(name) ?? LanguageCode(whole)) is not { } code) return false;
            f.LanguageId = code; return true;
        }),
    ];

    private static int? Number(Match m, int digits, int unit)
    {
        if (!int.TryParse(m.Groups[digits].Value, out var n)) return null;
        return m.Groups[unit].Success ? n * 1_000 : n;
    }

    /// <summary>Runs the phrase list over the text outside quotes — a quoted
    /// <c>"complete"</c> is the user asking for the literal word.</summary>
    private static string ExtractPhrases(string working, AO3SearchFilters filters)
    {
        foreach (var phrase in Phrases)
        {
            var quoted = QuotedRanges(working);
            var consumed = new List<(int Start, int Length)>();
            foreach (Match match in phrase.Regex.Matches(working))
            {
                if (quoted.Any(q => q.Start < match.Index + match.Length && match.Index < q.Start + q.Length)) continue;
                if (phrase.Apply(match, filters)) consumed.Add((match.Index, match.Length));
            }
            working = Removing(consumed, working);
        }
        return working;
    }

    private static readonly Regex QuotedPattern = new("\"[^\"]*\"");

    private static List<(int Start, int Length)> QuotedRanges(string s) =>
        QuotedPattern.Matches(s).Select(m => (m.Index, m.Length)).ToList();

    /// <summary>The sort to use when none was chosen: AO3's "best match" needs
    /// keywords to rank by — with only filters its order is arbitrary — so
    /// filter-only searches show the most-kudosed works first.</summary>
    public static SortColumn AutomaticSort(bool hasKeywords) => hasKeywords ? SortColumn.BestMatch : SortColumn.KudosCount;

    // MARK: - Render

    /// <summary>The search as text: keywords first, then explicit tokens. Parsing
    /// the result gives back the same filters.</summary>
    public static string Render(AO3SearchFilters f)
    {
        var parts = new List<string>();
        if (f.Query.Length > 0) parts.Add(f.Query);
        void Token(string key, string value) => parts.Add($"{key}:{QuoteIfNeeded(value)}");
        if (f.Title.Length > 0) Token("title", f.Title);
        if (f.Creators.Length > 0) Token("by", f.Creators);
        f.FandomNames.ForEach(v => Token("fandom", v));
        f.RelationshipNames.ForEach(v => Token("ship", v));
        f.CharacterNames.ForEach(v => Token("character", v));
        f.FreeformNames.ForEach(v => Token("freeform", v));
        f.OtherTagNames.ForEach(v => Token("tag", v));
        f.ExcludedTagNames.ForEach(v => Token("-tag", v));
        f.ExcludedFreeforms.ForEach(v => Token("exclude", v));
        foreach (var r in f.Ratings.OrderBy(r => r.RawValue(), StringComparer.Ordinal)) Token("rating", RatingKey(r));
        foreach (var w in f.Warnings.OrderBy(w => w.RawValue(), StringComparer.Ordinal)) Token("warning", WarningKey(w));
        foreach (var c in f.Categories.OrderBy(c => c.RawValue(), StringComparer.Ordinal)) Token("category", CategoryKey(c));
        if (f.Complete == TriState.Yes) Token("complete", "yes");
        else if (f.Complete == TriState.No) Token("complete", "no");
        if (f.Crossover == TriState.Yes) Token("crossover", "yes");
        else if (f.Crossover == TriState.No) Token("crossover", "no");
        if (f.SingleChapter) Token("oneshot", "yes");
        if (f.WordCount.Length > 0) Token("words", f.WordCount);
        if (f.LanguageId.Length > 0) Token("lang", f.LanguageId);
        if (f.KudosCount.Length > 0) Token("kudos", f.KudosCount);
        if (f.Hits.Length > 0) Token("hits", f.Hits);
        if (f.CommentsCount.Length > 0) Token("comments", f.CommentsCount);
        if (f.BookmarksCount.Length > 0) Token("bookmarks", f.BookmarksCount);
        if (f.RevisedAt.Length > 0) Token("updated", f.RevisedAt);
        return string.Join(" ", parts);
    }

    private static string QuoteIfNeeded(string value)
    {
        var clean = value.Replace("\"", "");
        return clean.Any(char.IsWhiteSpace) ? $"\"{clean}\"" : clean;
    }

    // MARK: - Vocabulary

    public static Rating? RatingNamed(string raw) => raw.ToLowerInvariant() switch
    {
        "g" or "general" or "general audiences" => Rating.General,
        "t" or "teen" or "teen and up" or "teen and up audiences" => Rating.Teen,
        "m" or "mature" => Rating.Mature,
        "e" or "explicit" => Rating.Explicit,
        "nr" or "not rated" or "notrated" or "unrated" => Rating.NotRated,
        _ => null,
    };

    public static string RatingKey(Rating r) => r switch
    {
        Rating.General => "general",
        Rating.Teen => "teen",
        Rating.Mature => "mature",
        Rating.Explicit => "explicit",
        _ => "not rated",
    };

    public static ArchiveWarning? WarningNamed(string raw)
    {
        var v = raw.ToLowerInvariant();
        foreach (var w in SearchEnums.AllWarnings)
            if (w.DisplayName().ToLowerInvariant() == v) return w;
        return v switch
        {
            "none" or "no warnings" or "no archive warnings" => ArchiveWarning.NoWarningsApply,
            "cnow" or "choose not to use" or "chose not to use" => ArchiveWarning.ChooseNotToUse,
            "violence" or "graphic violence" => ArchiveWarning.GraphicViolence,
            "mcd" or "death" or "character death" => ArchiveWarning.MajorCharacterDeath,
            "noncon" or "non-con" or "rape" => ArchiveWarning.RapeNonCon,
            "underage" => ArchiveWarning.Underage,
            _ => null,
        };
    }

    public static string WarningKey(ArchiveWarning w) => w switch
    {
        ArchiveWarning.NoWarningsApply => "none",
        ArchiveWarning.ChooseNotToUse => "cnow",
        ArchiveWarning.GraphicViolence => "violence",
        ArchiveWarning.MajorCharacterDeath => "mcd",
        ArchiveWarning.RapeNonCon => "noncon",
        _ => "underage",
    };

    public static WorkCategory? CategoryNamed(string raw)
    {
        var v = raw.ToLowerInvariant();
        return v switch
        {
            "f/f" or "femslash" => WorkCategory.FF,
            "f/m" or "het" => WorkCategory.FM,
            "gen" => WorkCategory.Gen,
            "m/m" or "slash" => WorkCategory.MM,
            "multi" => WorkCategory.Multi,
            "other" => WorkCategory.Other,
            _ => SearchEnums.AllCategories.Cast<WorkCategory?>().FirstOrDefault(c => c!.Value.DisplayName().ToLowerInvariant() == v),
        };
    }

    public static string CategoryKey(WorkCategory c) => c switch
    {
        WorkCategory.FF => "f/f",
        WorkCategory.FM => "f/m",
        WorkCategory.Gen => "gen",
        WorkCategory.MM => "m/m",
        WorkCategory.Multi => "multi",
        _ => "other",
    };

    private static TriState? Completion(string raw) => raw.ToLowerInvariant() switch
    {
        "complete" or "completed" => TriState.Yes,
        "wip" or "incomplete" or "in progress" => TriState.No,
        _ => YesNo(raw),
    };

    private static TriState? YesNo(string raw) => raw.ToLowerInvariant() switch
    {
        "yes" or "y" or "true" or "1" or "only" => TriState.Yes,
        "no" or "n" or "false" or "0" or "none" => TriState.No,
        _ => null,
    };

    /// <summary>AO3's numeric range syntax (<c>&lt;5000</c>, <c>&gt;100</c>,
    /// <c>1000-5000</c>, <c>5000</c>), with a <c>k</c> shorthand (<c>&lt;10k</c>).</summary>
    public static string? NumericRange(string raw)
    {
        var compact = raw.ToLowerInvariant().Replace(",", "").Replace(" ", "");
        var expanded = Regex.Replace(compact, @"(\d+)k", "${1}000");
        return Regex.IsMatch(expanded, @"^(?:[<>]\d+|\d+(?:-\d+)?)$") ? expanded : null;
    }

    public static readonly IReadOnlyDictionary<string, string> LanguageNames = new Dictionary<string, string>
    {
        ["en"] = "English", ["es"] = "Spanish", ["fr"] = "French", ["de"] = "German", ["ru"] = "Russian",
        ["zh"] = "Chinese", ["ja"] = "Japanese", ["ko"] = "Korean", ["pt"] = "Portuguese", ["it"] = "Italian",
    };

    public static string? LanguageCode(string raw)
    {
        var v = raw.ToLowerInvariant().Trim(' ');
        if (KnownTags.LanguageAliases.TryGetValue(v, out var alias)) return alias;
        if (LanguageNames.ContainsKey(v)) return v;
        if (Regex.IsMatch(v, "^[a-z]{2,3}(?:-[a-z]+)?$")) return v;
        return null;
    }

    // MARK: - Helpers

    private static void AppendUnique(string value, List<string> list)
    {
        if (!list.Any(x => string.Equals(x, value, StringComparison.OrdinalIgnoreCase))) list.Add(value);
    }

    private static string Removing(List<(int Start, int Length)> ranges, string s)
    {
        if (ranges.Count == 0) return s;
        var sb = new StringBuilder(s);
        foreach (var (start, length) in ranges.OrderByDescending(r => r.Start))
        {
            sb.Remove(start, length);
            sb.Insert(start, ' ');
        }
        return sb.ToString();
    }

    public static string CollapseWhitespace(string s) => Regex.Replace(s, @"\s+", " ").Trim(' ');
}
