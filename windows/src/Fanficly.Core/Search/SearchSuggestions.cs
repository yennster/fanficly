using System.Globalization;

namespace Fanficly.Core;

/// <summary>Which kind of thing a <see cref="SearchSuggestion"/> applies.</summary>
public enum SearchSuggestionKind { Tag, Rating, Completion, SingleChapter, Crossover, Category, Language, WordCount }

/// <summary>Something the search box can offer while you type. Nothing here is
/// applied unless tapped — that opt-in is what keeps search predictable.
/// (Swift's <c>SearchSuggestion</c> enum; build one with the factory members,
/// which are named after its cases.)</summary>
public sealed record SearchSuggestion
{
    public SearchSuggestionKind Kind { get; }
    /// <summary>The tag name (<see cref="SearchSuggestionKind.Tag"/>), language code
    /// (<see cref="SearchSuggestionKind.Language"/>) or AO3 word-count range
    /// (<see cref="SearchSuggestionKind.WordCount"/>); "" otherwise.</summary>
    public string Value { get; }
    public Rating? RatingValue { get; }
    /// <summary>The state for Completion / Crossover.</summary>
    public TriState? State { get; }
    public WorkCategory? CategoryValue { get; }

    private SearchSuggestion(SearchSuggestionKind kind, string value = "", Rating? rating = null,
                             TriState? state = null, WorkCategory? category = null)
    {
        Kind = kind;
        Value = value;
        RatingValue = rating;
        State = state;
        CategoryValue = category;
    }

    /// <summary>An exact AO3 tag (fandom, character, ship or trope).</summary>
    public static SearchSuggestion Tag(string name) => new(SearchSuggestionKind.Tag, name);
    public static SearchSuggestion Rating(Rating rating) => new(SearchSuggestionKind.Rating, rating: rating);
    public static SearchSuggestion Completion(TriState state) => new(SearchSuggestionKind.Completion, state: state);
    public static SearchSuggestion SingleChapter { get; } = new(SearchSuggestionKind.SingleChapter);
    public static SearchSuggestion Crossover(TriState state) => new(SearchSuggestionKind.Crossover, state: state);
    public static SearchSuggestion Category(WorkCategory category) => new(SearchSuggestionKind.Category, category: category);
    public static SearchSuggestion Language(string code) => new(SearchSuggestionKind.Language, code);
    public static SearchSuggestion WordCount(string range) => new(SearchSuggestionKind.WordCount, range);

    public string Label => Kind switch
    {
        SearchSuggestionKind.Tag => Value,
        SearchSuggestionKind.Rating => $"Rated {RatingValue!.Value.DisplayName()}",
        SearchSuggestionKind.Completion => State == TriState.No ? "Works in progress" : "Complete works",
        SearchSuggestionKind.SingleChapter => "One-shots",
        SearchSuggestionKind.Crossover => State == TriState.No ? "No crossovers" : "Crossovers",
        SearchSuggestionKind.Category => CategoryValue!.Value.DisplayName(),
        SearchSuggestionKind.Language => $"In {(SearchSyntax.LanguageNames.TryGetValue(Value, out var name) ? name : Value)}",
        _ => AO3SearchFilters.WordCountLabel(Value),
    };

    /// <summary>Icon id (SF Symbol name; the app maps it to a Fluent glyph).</summary>
    public string SystemImage => Kind switch
    {
        SearchSuggestionKind.Tag => Value.Contains('/') ? "heart" : "tag",
        SearchSuggestionKind.Rating => "exclamationmark.shield",
        SearchSuggestionKind.Completion => "checkmark.circle",
        SearchSuggestionKind.SingleChapter => "1.circle",
        SearchSuggestionKind.Crossover => "arrow.triangle.merge",
        SearchSuggestionKind.Category => "person.2",
        SearchSuggestionKind.Language => "globe",
        _ => "text.alignleft",
    };

    public void Apply(AO3SearchFilters filters)
    {
        switch (Kind)
        {
            case SearchSuggestionKind.Tag:
                if (!filters.OtherTagNames.Any(t => string.Equals(t, Value, StringComparison.OrdinalIgnoreCase)))
                    filters.OtherTagNames.Add(Value);
                break;
            case SearchSuggestionKind.Rating: filters.Ratings.Add(RatingValue!.Value); break;
            case SearchSuggestionKind.Completion: filters.Complete = State!.Value; break;
            case SearchSuggestionKind.SingleChapter: filters.SingleChapter = true; break;
            case SearchSuggestionKind.Crossover: filters.Crossover = State!.Value; break;
            case SearchSuggestionKind.Category: filters.Categories.Add(CategoryValue!.Value); break;
            case SearchSuggestionKind.Language: filters.LanguageId = Value; break;
            case SearchSuggestionKind.WordCount: filters.WordCount = Value; break;
        }
    }
}

/// <summary>A suggestion plus how many trailing words of the search text it replaces.</summary>
public sealed record SuggestionCandidate(SearchSuggestion Suggestion, int ConsumedWords)
{
    public string Id => $"{Suggestion.Label}|{ConsumedWords}";
}

public static class SearchSuggestions
{
    /// <summary>The words being typed at the end of the search text — what
    /// suggestions are for. Up to three plain words; stops at <c>key:value</c>
    /// tokens, quoted phrases and <c>-exclusions</c>, and is empty inside an
    /// unclosed quote.</summary>
    public static IReadOnlyList<string> ActiveWords(string text, int limit = 3)
    {
        var normalized = SearchSyntax.NormalizeQuotes(text);
        if (normalized.Count(c => c == '"') % 2 == 1) return [];
        var words = new List<string>();
        foreach (var w in SplitWhitespace(normalized).Reverse())
        {
            if (w.Contains(':') || w.StartsWith('-') || w.Contains('"')) break;
            words.Insert(0, w);
            if (words.Count == limit) break;
        }
        return words;
    }

    /// <summary>Instant, offline suggestions: fandom abbreviations AO3's
    /// autocomplete wouldn't match ("hp", "mcu"), and filters people otherwise
    /// type as words ("teen" → Rated Teen And Up, "comp" → Complete works).
    /// Longer phrases win.</summary>
    public static IReadOnlyList<SuggestionCandidate> Local(IReadOnlyList<string> words)
    {
        var output = new List<SuggestionCandidate>();
        var seen = new HashSet<SearchSuggestion>();
        void Add(SearchSuggestion s, int n)
        {
            if (seen.Add(s)) output.Add(new SuggestionCandidate(s, n));
        }
        if (words.Count == 0) return [];
        for (var n = words.Count; n >= 1; n--)
        {
            var phrase = string.Join(" ", words.Skip(words.Count - n)).ToLowerInvariant();
            if (KnownTags.FandomAliases.TryGetValue(phrase, out var fandom)) Add(SearchSuggestion.Tag(fandom), n);
            if (WordCountIn(phrase) is { } wc) Add(SearchSuggestion.WordCount(wc), n);
            var length = Characters(phrase);
            if (length < 3) continue;
            foreach (var (name, rating) in RatingWords)
                if (name.StartsWith(phrase, StringComparison.Ordinal)) Add(SearchSuggestion.Rating(rating), n);
            if ("complete".StartsWith(phrase, StringComparison.Ordinal) || phrase == "completed")
                Add(SearchSuggestion.Completion(TriState.Yes), n);
            if (phrase == "wip" || ("work in progress".StartsWith(phrase, StringComparison.Ordinal) && length >= 6))
                Add(SearchSuggestion.Completion(TriState.No), n);
            if (OneShotWords.Any(w => w.StartsWith(phrase, StringComparison.Ordinal))) Add(SearchSuggestion.SingleChapter, n);
            if (length >= 5 && "crossover".StartsWith(phrase, StringComparison.Ordinal)) Add(SearchSuggestion.Crossover(TriState.Yes), n);
            if (phrase.StartsWith("no cross", StringComparison.Ordinal)) Add(SearchSuggestion.Crossover(TriState.No), n);
            if (CategoryWords.TryGetValue(phrase, out var category)) Add(SearchSuggestion.Category(category), n);
            var language = phrase.StartsWith("in ", StringComparison.Ordinal) ? phrase[3..] : phrase;
            if (Characters(language) >= 3)
            {
                foreach (var (code, name) in SearchSyntax.LanguageNames.OrderBy(kv => kv.Value, StringComparer.Ordinal))
                    if (name.ToLowerInvariant().StartsWith(language, StringComparison.Ordinal))
                        Add(SearchSuggestion.Language(code), n);
            }
        }
        // Short category forms ("m/m", "f/f") are only 3 characters.
        if (CategoryWords.TryGetValue(words[^1].ToLowerInvariant(), out var last))
            Add(SearchSuggestion.Category(last), 1);
        return output;
    }

    private static readonly (string Name, Rating Rating)[] RatingWords =
    [
        ("general", Rating.General), ("teen", Rating.Teen), ("mature", Rating.Mature),
        ("explicit", Rating.Explicit), ("not rated", Rating.NotRated),
    ];

    private static readonly string[] OneShotWords = ["oneshot", "one shot", "one-shot"];

    private static readonly Dictionary<string, WorkCategory> CategoryWords = new()
    {
        ["m/m"] = WorkCategory.MM, ["f/f"] = WorkCategory.FF, ["f/m"] = WorkCategory.FM, ["femslash"] = WorkCategory.FF,
        ["slash"] = WorkCategory.MM, ["gen"] = WorkCategory.Gen, ["multi"] = WorkCategory.Multi,
    };

    /// <summary>Only when the whole phrase is a word count, so tapping it can't
    /// also swallow the keywords before it ("drarry under 10k").</summary>
    private static string? WordCountIn(string phrase)
    {
        var filters = SearchSyntax.Parse(phrase);
        return filters.WordCount.Length > 0 && filters.Query.Length == 0 ? filters.WordCount : null;
    }

    /// <summary>Orders AO3's autocomplete results (which aren't ranked for this —
    /// "teen wolf" returns an episode tag before "Teen Wolf (TV)") so the tag
    /// you're most likely typing comes first.</summary>
    public static IReadOnlyList<string> RankTags(IEnumerable<string> names, string phrase, int limit = 6)
    {
        var p = phrase.ToLowerInvariant();
        var pWords = p.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        int Score(string name)
        {
            var n = name.ToLowerInvariant();
            int s;
            if (n == p) s = 100;
            else if (n.StartsWith(p, StringComparison.Ordinal)) s = 80;
            else if (pWords.All(w => AlphanumericTokens(n).Any(t => t.StartsWith(w, StringComparison.Ordinal)))) s = 60;
            else if (n.Contains(p, StringComparison.Ordinal)) s = 40;
            else s = 10;
            if (n.StartsWith("episode:", StringComparison.Ordinal)) s -= 30;
            if (Characters(name) > 60) s -= 10;
            return s;
        }
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return names
            .Where(n => seen.Add(n.ToLowerInvariant()))
            .Select((name, offset) => (Name: name, Offset: offset, Score: Score(name), Length: Characters(name)))
            .OrderByDescending(x => x.Score)
            .ThenBy(x => x.Length)
            .ThenBy(x => x.Offset)
            .Take(limit)
            .Select(x => x.Name)
            .ToList();
    }

    /// <summary>Applies a tapped suggestion: the filter goes into
    /// <paramref name="filters"/>, and the words it came from leave the search text.</summary>
    public static void Apply(SuggestionCandidate candidate, ref string text, AO3SearchFilters filters)
    {
        candidate.Suggestion.Apply(filters);
        text = RemovingTrailingWords(candidate.ConsumedWords, text);
    }

    public static string RemovingTrailingWords(int count, string text)
    {
        var words = SplitWhitespace(text).ToList();
        var removed = Math.Min(count, words.Count);
        words.RemoveRange(words.Count - removed, removed);
        return words.Count == 0 ? "" : string.Join(" ", words) + " ";
    }

    private static IEnumerable<string> SplitWhitespace(string s) =>
        s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    /// <summary>Runs of letters and numbers — Swift's split on "not a letter or number".</summary>
    internal static IEnumerable<string> AlphanumericTokens(string s)
    {
        var token = new System.Text.StringBuilder();
        foreach (var rune in s.EnumerateRunes())
        {
            if (System.Text.Rune.IsLetter(rune) || System.Text.Rune.IsNumber(rune)) { token.Append(rune.ToString()); continue; }
            if (token.Length > 0) { yield return token.ToString(); token.Clear(); }
        }
        if (token.Length > 0) yield return token.ToString();
    }

    /// <summary>User-perceived characters (Swift's <c>String.count</c>).</summary>
    internal static int Characters(string s) => new StringInfo(s).LengthInTextElements;
}

/// <summary>Remembers autocomplete answers for the session so retyping a phrase
/// (or backspacing) never costs another throttled AO3 request.</summary>
public sealed class TagSuggestionCache
{
    public static TagSuggestionCache Shared { get; } = new();

    private readonly Lock _gate = new();
    private readonly Dictionary<string, IReadOnlyList<string>> _store = new(StringComparer.Ordinal);
    private readonly Queue<string> _order = new();

    public IReadOnlyList<string>? Value(string phrase)
    {
        lock (_gate) return _store.TryGetValue(phrase.ToLowerInvariant(), out var v) ? v : null;
    }

    public void Set(IReadOnlyList<string> names, string phrase)
    {
        var key = phrase.ToLowerInvariant();
        lock (_gate)
        {
            if (!_store.ContainsKey(key)) _order.Enqueue(key);
            _store[key] = names;
            if (_order.Count > 200) _store.Remove(_order.Dequeue());
        }
    }
}

/// <summary>Recent searches, newest first, stored as search-box text one per line
/// (the box is single-line, so a prompt never contains a newline). On-device only.</summary>
public static class RecentSearches
{
    public const string StorageKey = "search.recent";
    public const int Limit = 10;

    public static IReadOnlyList<string> List(string raw) =>
        raw.Split('\n', StringSplitOptions.RemoveEmptyEntries);

    public static string Adding(string prompt, string raw)
    {
        var p = prompt.Trim();
        if (p.Length == 0) return raw;
        var items = List(raw).Where(i => !string.Equals(i, p, StringComparison.OrdinalIgnoreCase)).ToList();
        items.Insert(0, p);
        return string.Join("\n", items.Take(Limit));
    }

    public static string Removing(string prompt, string raw) =>
        string.Join("\n", List(raw).Where(i => i != prompt));

    // Persistence (the Swift view's @AppStorage(RecentSearches.storageKey)).

    /// <summary>The stored recents, newest first.</summary>
    public static IReadOnlyList<string> Load(IKeyValueStore? store = null) =>
        List((store ?? KeyValueStores.Default).GetString(StorageKey) ?? "");

    /// <summary>Records a submitted search (its <c>PromptText()</c>).</summary>
    public static void Record(string prompt, IKeyValueStore? store = null)
    {
        var s = store ?? KeyValueStores.Default;
        s.SetString(StorageKey, Adding(prompt, s.GetString(StorageKey) ?? ""));
    }

    public static void Remove(string prompt, IKeyValueStore? store = null)
    {
        var s = store ?? KeyValueStores.Default;
        s.SetString(StorageKey, Removing(prompt, s.GetString(StorageKey) ?? ""));
    }

    public static void Clear(IKeyValueStore? store = null) => (store ?? KeyValueStores.Default).Remove(StorageKey);
}
