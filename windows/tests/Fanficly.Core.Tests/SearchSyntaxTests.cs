using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>The search box: words stay keywords (AO3 does the matching), explicit
/// <c>key:value</c> tokens and a short list of filter-only phrases become filters,
/// and rendering round-trips.</summary>
public class SearchSyntaxTests
{
    private static AO3SearchFilters Parse(string s) => SearchSyntax.Parse(s);

    private static void AssertSet<T>(IEnumerable<T> expected, ISet<T> actual) =>
        Assert.True(actual.SetEquals(expected), $"expected {{{string.Join(", ", expected)}}}, got {{{string.Join(", ", actual)}}}");

    // MARK: - Words stay words (the old parser's failures)

    [Fact]
    public void TeenWolf_IsAFandomSearch_NotATeenRating()
    {
        var f = Parse("teen wolf derek stiles slow burn");
        Assert.Equal("teen wolf derek stiles slow burn", f.Query);
        Assert.Empty(f.Ratings);
    }

    [Fact]
    public void EverydayWords_NeverBecomeFilters()
    {
        foreach (var prompt in new[] { "supernatural creatures", "wednesday addams", "french kiss", "korean idol au",
                     "the other side", "soft family drama", "mature themes", "general hospital",
                     "harry potter", "popular kid", "recent graduate", "finished line", "multi chapter" })
        {
            var f = Parse(prompt);
            Assert.Equal(prompt, f.Query);
            var bare = f.Clone();
            bare.Query = "";
            Assert.True(bare.IsEmpty, $"{prompt} added filters");
        }
    }

    [Fact]
    public void Ships_StayKeywords()
    {
        // AO3 matches "edward/bella" exactly like "edward bella" (verified).
        Assert.Equal("edward/bella", Parse("edward/bella").Query);
        Assert.Empty(Parse("edward/bella").RelationshipNames);
    }

    [Fact]
    public void ExclusionsAndPhrases_PassThroughToAO3()
    {
        Assert.Equal("drarry -angst \"enemies to lovers\"", Parse("drarry -angst \"enemies to lovers\"").Query);
    }

    // MARK: - Filter-only phrases

    [Fact]
    public void Completion()
    {
        Assert.Equal(TriState.Yes, Parse("drarry complete").Complete);
        Assert.Equal(TriState.Yes, Parse("drarry completed").Complete);
        Assert.Equal(TriState.No, Parse("drarry wip").Complete);
        Assert.Equal(TriState.No, Parse("drarry incomplete").Complete);
        Assert.Equal("drarry", Parse("drarry complete").Query);
    }

    [Fact]
    public void QuotedFilterWord_IsTheLiteralWord()
    {
        var f = Parse("\"complete\" idiot");
        Assert.Equal(TriState.Any, f.Complete);
        Assert.Equal("\"complete\" idiot", f.Query);
    }

    [Fact]
    public void OneShots()
    {
        foreach (var s in new[] { "oneshot", "one shot", "one-shot", "oneshots" })
            Assert.True(Parse($"fluff {s}").SingleChapter, s);
    }

    [Fact]
    public void Ratings_OnlyUnambiguousForms()
    {
        AssertSet([Rating.Explicit], Parse("smut explicit").Ratings);
        AssertSet([Rating.Mature, Rating.Explicit], Parse("nsfw").Ratings);
        AssertSet([Rating.General, Rating.Teen], Parse("sfw").Ratings);
        AssertSet([Rating.Mature], Parse("rated mature").Ratings);
        AssertSet([Rating.Mature], Parse("m-rated").Ratings);
        AssertSet([Rating.Teen], Parse("teen and up audiences").Ratings);
        Assert.Empty(Parse("teen").Ratings);
        Assert.Empty(Parse("mature").Ratings);
    }

    [Fact]
    public void Categories()
    {
        AssertSet([WorkCategory.MM], Parse("coffee shop au m/m").Categories);
        AssertSet([WorkCategory.FF], Parse("f/f femslash").Categories);
        Assert.Empty(Parse("gen").Categories);
    }

    [Fact]
    public void WordCount_NeedsAUnit()
    {
        Assert.Equal("<10000", Parse("under 10k").WordCount);
        Assert.Equal(">50000", Parse("over 50,000 words").WordCount);
        Assert.Equal("<5000", Parse("less than 5000 words").WordCount);
        Assert.Equal("10000-50000", Parse("between 10k and 50k").WordCount);
        Assert.Equal("10000-50000", Parse("between 10 and 50k").WordCount);
        Assert.Equal("", Parse("over 9000").WordCount);
        Assert.Equal("over 9000", Parse("over 9000").Query);
    }

    [Fact]
    public void Language_NeedsIn()
    {
        Assert.Equal("es", Parse("drarry in spanish").LanguageId);
        Assert.Equal("es", Parse("en español").LanguageId);
        Assert.Equal("", Parse("spanish inquisition").LanguageId);
    }

    [Fact]
    public void CrossoversAndWarnings()
    {
        Assert.Equal(TriState.No, Parse("no crossovers").Crossover);
        Assert.Equal(TriState.Yes, Parse("marvel crossover").Crossover);
        Assert.Equal(["Major Character Death"], Parse("angst no mcd").ExcludedTagNames);
        AssertSet([ArchiveWarning.NoWarningsApply], Parse("no archive warnings apply").Warnings);
    }

    // MARK: - Explicit tokens

    [Fact]
    public void KeyValueTokens()
    {
        var f = Parse("title:\"The Long Way Home\" by:wanderlight tag:\"Slow Burn\" -tag:\"Major Character Death\" rating:explicit warning:mcd category:m/m complete:yes crossover:no oneshot:yes words:<10k lang:es kudos:>1000");
        Assert.Equal("The Long Way Home", f.Title);
        Assert.Equal("wanderlight", f.Creators);
        Assert.Equal(["Slow Burn"], f.OtherTagNames);
        Assert.Equal(["Major Character Death"], f.ExcludedTagNames);
        AssertSet([Rating.Explicit], f.Ratings);
        AssertSet([ArchiveWarning.MajorCharacterDeath], f.Warnings);
        AssertSet([WorkCategory.MM], f.Categories);
        Assert.Equal(TriState.Yes, f.Complete);
        Assert.Equal(TriState.No, f.Crossover);
        Assert.True(f.SingleChapter);
        Assert.Equal("<10000", f.WordCount);
        Assert.Equal("es", f.LanguageId);
        Assert.Equal(">1000", f.KudosCount);
        Assert.Equal("", f.Query);
    }

    [Fact]
    public void UnknownKeys_StayInTheQuery()
    {
        Assert.Equal("Re:Zero rating_ids:12", Parse("Re:Zero rating_ids:12").Query);
        Assert.Equal("rating:bogus", Parse("rating:bogus").Query);
    }

    [Fact]
    public void SmartQuotes()
    {
        Assert.Equal("The Great Gatsby", Parse("title:“The Great Gatsby”").Title);
    }

    [Fact]
    public void LengthChangingCharacters_DoNotCrashOrShift()
    {
        var f = Parse("İstanbul by:melis complete");
        Assert.Equal("melis", f.Creators);
        Assert.Equal(TriState.Yes, f.Complete);
        Assert.Equal("İstanbul", f.Query);
    }

    // MARK: - Round trip

    [Fact]
    public void Render_RoundTrips()
    {
        var f = new AO3SearchFilters
        {
            Query = "drarry -angst",
            Title = "Long Way",
            Creators = "someone",
            OtherTagNames = ["Teen Wolf (TV)", "Slow Burn"],
            ExcludedTagNames = ["Major Character Death"],
            FandomNames = ["Harry Potter - J. K. Rowling"],
            RelationshipNames = ["Draco Malfoy/Harry Potter"],
            CharacterNames = ["Hermione Granger"],
            FreeformNames = ["Fluff"],
            ExcludedFreeforms = ["sad ending"],
            Ratings = [Rating.Mature, Rating.Explicit, Rating.NotRated],
            Warnings = [ArchiveWarning.NoWarningsApply, ArchiveWarning.MajorCharacterDeath],
            Categories = [WorkCategory.MM, WorkCategory.FF],
            Complete = TriState.No,
            Crossover = TriState.Yes,
            SingleChapter = true,
            WordCount = "1000-5000",
            LanguageId = "es",
            KudosCount = ">100",
            Hits = "<5000",
            CommentsCount = ">10",
            BookmarksCount = ">5",
            RevisedAt = "<1week",
        };
        Assert.Equal(f, Parse(SearchSyntax.Render(f)));
    }

    [Fact]
    public void EmptyRendersEmpty()
    {
        Assert.Equal("", SearchSyntax.Render(new AO3SearchFilters()));
        Assert.True(Parse("   ").IsEmpty);
    }

    [Fact]
    public void AutomaticSort_KudosWithoutKeywords()
    {
        Assert.Equal(SortColumn.KudosCount, SearchSyntax.AutomaticSort(hasKeywords: false));
        Assert.Equal(SortColumn.BestMatch, SearchSyntax.AutomaticSort(hasKeywords: true));
    }

    // MARK: - AO3 fields

    [Fact]
    public void TagFieldsReachAO3()
    {
        var f = new AO3SearchFilters
        {
            OtherTagNames = ["Teen Wolf (TV)", "Slow Burn"],
            ExcludedTagNames = ["Major Character Death"],
        };
        var items = f.QueryItems().ToDictionary(kv => kv.Key, kv => kv.Value);
        Assert.Equal("Teen Wolf (TV), Slow Burn", items["work_search[other_tag_names]"]);
        Assert.Equal("Major Character Death", items["work_search[excluded_tag_names]"]);
        Assert.False(f.IsEmpty);
    }

    [Fact]
    public void FiltersSavedBeforeTagFields_StillDecode()
    {
        const string old = """{"query":"","title":"","creators":"","revisedAt":"","complete":"yes","crossover":"any","singleChapter":false,"wordCount":"","languageId":"","fandomNames":[],"characterNames":[],"relationshipNames":["A/B"],"freeformNames":[],"excludedFreeforms":[],"ratings":["13"],"warnings":[],"categories":[],"hits":"","kudosCount":"","commentsCount":"","bookmarksCount":"","sortColumn":"kudos_count","sortDirection":"desc"}""";
        var decoded = AO3SearchFilters.FromSavedJson(old);
        Assert.NotNull(decoded);
        Assert.Equal(["A/B"], decoded.RelationshipNames);
        Assert.Equal(TriState.Yes, decoded.Complete);
        Assert.Equal(SortColumn.KudosCount, decoded.SortColumn);
        Assert.Empty(decoded.OtherTagNames);
    }

    [Fact]
    public void Merging_UnionsListsAndKeepsSort()
    {
        var @base = new AO3SearchFilters
        {
            OtherTagNames = ["Slow Burn"],
            SortColumn = SortColumn.KudosCount,
            Query = "kept out",
        };
        var merged = @base.Merging(Parse("tag:\"slow burn\" tag:Fluff complete"));
        Assert.Equal(["Slow Burn", "Fluff"], merged.OtherTagNames);
        Assert.Equal(TriState.Yes, merged.Complete);
        Assert.Equal(SortColumn.KudosCount, merged.SortColumn);
        Assert.Equal("kept out", merged.Query);
    }
}
