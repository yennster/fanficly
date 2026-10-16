using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Typeahead: which words suggestions are for, the instant local ones,
/// how AO3's tags are ranked, and what tapping one does.</summary>
public class SearchSuggestionsTests
{
    [Fact]
    public void ActiveWords_AreTheTrailingPlainWords()
    {
        Assert.Equal(["burn", "teen", "wol"], SearchSuggestions.ActiveWords("slow burn teen wol"));
        Assert.Equal(["teen", "wolf"], SearchSuggestions.ActiveWords("teen wolf "));
        Assert.Equal(["fluff"], SearchSuggestions.ActiveWords("by:someone fluff"));
        Assert.Equal(["fluff"], SearchSuggestions.ActiveWords("-angst fluff"));
        Assert.Equal(["coffee"], SearchSuggestions.ActiveWords("\"enemies to lovers\" coffee"));
        Assert.Empty(SearchSuggestions.ActiveWords("\"enemies to")); // inside an open quote
        Assert.Empty(SearchSuggestions.ActiveWords(""));
    }

    private static IEnumerable<SearchSuggestion> Suggestions(params string[] words) =>
        SearchSuggestions.Local(words).Select(c => c.Suggestion);

    [Fact]
    public void Local_FandomAbbreviations()
    {
        var candidates = SearchSuggestions.Local(["hp"]);
        Assert.Equal(SearchSuggestion.Tag("Harry Potter - J. K. Rowling"), candidates[0].Suggestion);
        Assert.Equal(1, candidates[0].ConsumedWords);
    }

    [Fact]
    public void Local_FilterWords_AreOffered_NotApplied()
    {
        Assert.Contains(SearchSuggestion.Rating(Rating.Teen), Suggestions("teen"));
        Assert.Contains(SearchSuggestion.Completion(TriState.Yes), Suggestions("comp"));
        Assert.Contains(SearchSuggestion.Completion(TriState.No), Suggestions("wip"));
        Assert.NotEmpty(SearchSuggestions.Local(["one", "sh"]));
        Assert.Contains(SearchSuggestion.Category(WorkCategory.MM), Suggestions("m/m"));
        Assert.Contains(SearchSuggestion.Language("es"), Suggestions("spa"));
        Assert.Contains(SearchSuggestion.WordCount("<10000"), Suggestions("under", "10k"));
    }

    [Fact]
    public void Local_MultiWordMatch_ConsumesItsWords()
    {
        var candidate = SearchSuggestions.Local(["drarry", "under", "10k"])
            .FirstOrDefault(c => c.Suggestion == SearchSuggestion.WordCount("<10000"));
        Assert.Equal(2, candidate?.ConsumedWords);
    }

    [Fact]
    public void Local_ShortFragmentsStayQuiet()
    {
        Assert.Empty(SearchSuggestions.Local(["te"]));
        Assert.Empty(SearchSuggestions.Local(["derek"]));
    }

    [Fact]
    public void RankTags_PutsTheTagYoureTypingFirst()
    {
        // AO3's raw order for "teen wolf" (abridged from a live response).
        string[] raw =
        [
            "Episode: s01e09 Wolf's Bane (Teen Wolf TV)",
            "Jana (Wolfblood)/Scott McCall (Teen Wolf)",
            "Teen Wolf (TV)",
            "Scott McCall (Teen Wolf)",
            "teen wolf (tv)",
        ];
        var ranked = SearchSuggestions.RankTags(raw, "teen wolf");
        Assert.Equal("Teen Wolf (TV)", ranked[0]);
        Assert.Equal("Episode: s01e09 Wolf's Bane (Teen Wolf TV)", ranked[^1]);
        Assert.Equal(4, ranked.Count); // case-insensitive duplicates collapse
    }

    [Fact]
    public void RankTags_ExactMatchWins()
    {
        Assert.Equal("Slow Burn", SearchSuggestions.RankTags(["Slow Burn Draco Malfoy/Harry Potter", "Slow Burn"], "slow burn")[0]);
    }

    [Fact]
    public void Apply_ReplacesTheWordsWithAFilter()
    {
        var text = "explicit teen wolf";
        var filters = new AO3SearchFilters();
        SearchSuggestions.Apply(new SuggestionCandidate(SearchSuggestion.Tag("Teen Wolf (TV)"), 2), ref text, filters);
        Assert.Equal("explicit ", text);
        Assert.Equal(["Teen Wolf (TV)"], filters.OtherTagNames);

        SearchSuggestions.Apply(new SuggestionCandidate(SearchSuggestion.Rating(Rating.Explicit), 1), ref text, filters);
        Assert.Equal("", text);
        Assert.True(filters.Ratings.SetEquals([Rating.Explicit]));
    }

    [Fact]
    public void Apply_SameTagTwice_IsOneFilter()
    {
        var text = "slow burn";
        var filters = new AO3SearchFilters { OtherTagNames = ["Slow Burn"] };
        SearchSuggestions.Apply(new SuggestionCandidate(SearchSuggestion.Tag("slow burn"), 2), ref text, filters);
        Assert.Equal(["Slow Burn"], filters.OtherTagNames);
    }

    [Fact]
    public void SuggestionLabels()
    {
        Assert.Equal("Rated Explicit", SearchSuggestion.Rating(Rating.Explicit).Label);
        Assert.Equal("Works in progress", SearchSuggestion.Completion(TriState.No).Label);
        Assert.Equal("In Spanish", SearchSuggestion.Language("es").Label);
        Assert.StartsWith("Under ", SearchSuggestion.WordCount("<10000").Label);
        Assert.Equal("heart", SearchSuggestion.Tag("Draco Malfoy/Harry Potter").SystemImage);
    }

    // MARK: - Recents

    [Fact]
    public void Recents_NewestFirst_Deduped_Capped()
    {
        var raw = "";
        for (var n = 1; n <= 12; n++) raw = RecentSearches.Adding($"search {n}", raw);
        raw = RecentSearches.Adding("SEARCH 5", raw);
        var list = RecentSearches.List(raw);
        Assert.Equal(RecentSearches.Limit, list.Count);
        Assert.Equal("SEARCH 5", list[0]);
        Assert.DoesNotContain("search 5", list);
        Assert.Equal(RecentSearches.Limit - 1, RecentSearches.List(RecentSearches.Removing("SEARCH 5", raw)).Count);
        Assert.Equal(raw, RecentSearches.Adding("   ", raw));
    }

    [Fact]
    public void Recents_PersistUnderTheSwiftKey()
    {
        // Windows-only: the store helpers behind the Swift view's @AppStorage.
        var store = new InMemoryKeyValueStore();
        RecentSearches.Record("drarry", store);
        RecentSearches.Record("tag:\"Slow Burn\"", store);
        Assert.Equal("tag:\"Slow Burn\"\ndrarry", store.GetString(RecentSearches.StorageKey));
        RecentSearches.Remove("drarry", store);
        Assert.Equal(["tag:\"Slow Burn\""], RecentSearches.Load(store));
    }

    [Fact]
    public void TagSuggestionCache_IsCaseInsensitiveAndBounded()
    {
        // Windows-only: the session memo behind the typeahead.
        var cache = new TagSuggestionCache();
        cache.Set(["Teen Wolf (TV)"], "Teen Wolf");
        Assert.Equal(["Teen Wolf (TV)"], cache.Value("teen wolf"));
        for (var i = 0; i < 200; i++) cache.Set([], $"phrase {i}");
        Assert.Null(cache.Value("teen wolf"));
        Assert.NotNull(cache.Value("phrase 199"));
    }

    // MARK: - Results count
    // test_searchPage_totalFound exercises SearchResultsParser (the parser
    // worker's area) and is ported with the parser tests.
}
