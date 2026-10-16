using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class AO3SearchFiltersTests
{
    private static Dictionary<string, string> Items(AO3SearchFilters f) =>
        f.QueryItems().ToDictionary(kv => kv.Key, kv => kv.Value);

    [Fact]
    public void EmptyFilters_OnlyHaveSort()
    {
        var names = new AO3SearchFilters().QueryItems().Select(kv => kv.Key).ToList();
        Assert.Contains("work_search[sort_column]", names);
        Assert.Contains("work_search[sort_direction]", names);
        Assert.DoesNotContain("work_search[query]", names);
    }

    [Fact]
    public void AllStructuredFieldsMap()
    {
        var f = new AO3SearchFilters
        {
            Title = "A Title",
            Creators = "someauthor",
            WordCount = "1000-5000",
            LanguageId = "en",
            Hits = ">1000",
            KudosCount = ">500",
            CommentsCount = ">10",
            BookmarksCount = ">5",
            RevisedAt = ">2024-01-01",
            Complete = TriState.Yes,
            Crossover = TriState.No,
            SingleChapter = true,
        };
        var d = Items(f);
        Assert.Equal("A Title", d["work_search[title]"]);
        Assert.Equal("someauthor", d["work_search[creators]"]);
        Assert.Equal("1000-5000", d["work_search[word_count]"]);
        Assert.Equal("en", d["work_search[language_id]"]);
        Assert.Equal(">1000", d["work_search[hits]"]);
        Assert.Equal(">500", d["work_search[kudos_count]"]);
        Assert.Equal(">10", d["work_search[comments_count]"]);
        Assert.Equal(">5", d["work_search[bookmarks_count]"]);
        Assert.Equal(">2024-01-01", d["work_search[revised_at]"]);
        Assert.Equal("true", d["work_search[complete]"]);
        Assert.Equal("F", d["work_search[crossover]"]);
        Assert.Equal("1", d["work_search[single_chapter]"]);
    }

    [Fact]
    public void MultiValueTagsJoinedWithCommas()
    {
        var f = new AO3SearchFilters { CharacterNames = ["Harry Potter", "Hermione Granger"] };
        var value = f.QueryItems().FirstOrDefault(kv => kv.Key == "work_search[character_names]").Value;
        Assert.Equal("Harry Potter, Hermione Granger", value);
    }

    [Fact]
    public void WarningsCategoriesEmitArrayKeys()
    {
        var f = new AO3SearchFilters
        {
            Warnings = [ArchiveWarning.MajorCharacterDeath],
            Categories = [WorkCategory.MM, WorkCategory.FF],
        };
        var items = f.QueryItems();
        Assert.Single(items, kv => kv.Key == "work_search[archive_warning_ids][]");
        Assert.Equal(2, items.Count(kv => kv.Key == "work_search[category_ids][]"));
    }

    [Fact]
    public void SingleRatingUsesScalarField()
    {
        var f = new AO3SearchFilters { Ratings = [Rating.Explicit] };
        var items = f.QueryItems();
        // One rating goes through AO3's dedicated single-select field.
        Assert.Equal("13", items.First(kv => kv.Key == "work_search[rating_ids]").Value);
        Assert.DoesNotContain(items, kv => kv.Key == "work_search[rating_ids][]");
        Assert.DoesNotContain(items, kv => kv.Key == "work_search[query]");
    }

    [Fact]
    public void MultipleRatingsAreOredInQuery()
    {
        var f = new AO3SearchFilters { Ratings = [Rating.Explicit, Rating.Mature] }; // 13 and 12
        var items = f.QueryItems();
        // AO3's rating field is single-select, so a rating_ids[] array AND-matches
        // and returns nothing; 2+ ratings must be OR-ed via the query field.
        Assert.DoesNotContain(items, kv => kv.Key.StartsWith("work_search[rating_ids]", StringComparison.Ordinal));
        Assert.Equal("(rating_ids:12 OR rating_ids:13)", items.First(kv => kv.Key == "work_search[query]").Value);
    }

    [Fact]
    public void MultipleRatingsComposeWithExistingQuery()
    {
        var f = new AO3SearchFilters { Query = "coffee", Ratings = [Rating.Explicit, Rating.Mature] };
        Assert.Equal("coffee (rating_ids:12 OR rating_ids:13)", Items(f)["work_search[query]"]);
    }

    [Fact]
    public void ExcludedFreeformsBecomeNotInQuery()
    {
        var f = new AO3SearchFilters
        {
            Query = "harry/draco",
            ExcludedFreeforms = ["Angst", "slow burn"], // single word vs. phrase
        };
        Assert.Equal("harry/draco NOT Angst NOT \"slow burn\"", Items(f)["work_search[query]"]);
    }

    [Fact]
    public void IsEmpty()
    {
        Assert.True(new AO3SearchFilters().IsEmpty);
        Assert.False(new AO3SearchFilters { SingleChapter = true }.IsEmpty);
    }

    [Fact]
    public void SavedJSONRoundTripsAndDropsFandom()
    {
        var f = new AO3SearchFilters
        {
            FandomNames = ["Harry Potter - J. K. Rowling"],
            RelationshipNames = ["Hermione Granger/Draco Malfoy"],
            Ratings = [Rating.Explicit],
            Complete = TriState.Yes,
            ExcludedFreeforms = ["Angst"],
            WordCount = ">10000",
        };
        var restored = AO3SearchFilters.FromSavedJson(f.SavedJson());
        Assert.NotNull(restored);
        Assert.Empty(restored.FandomNames); // fandom should not be saved
        Assert.Equal(["Hermione Granger/Draco Malfoy"], restored.RelationshipNames);
        Assert.Contains(Rating.Explicit, restored.Ratings);
        Assert.Equal(TriState.Yes, restored.Complete);
        Assert.Equal(["Angst"], restored.ExcludedFreeforms);
        Assert.Equal(">10000", restored.WordCount);
    }

    [Fact]
    public void FromInvalidJSONIsNil()
    {
        Assert.Null(AO3SearchFilters.FromSavedJson("not json"));
    }

    [Fact]
    public void SuggestedName_SummarizesSelectionAndDropsFandom()
    {
        var f = new AO3SearchFilters
        {
            FandomNames = ["Harry Potter - J. K. Rowling"], // excluded from the name
            RelationshipNames = ["Hermione Granger/Draco Malfoy"],
            FreeformNames = ["Slow Burn"],
            Ratings = [Rating.Explicit],
            Complete = TriState.Yes,
        };
        var name = f.SuggestedName();
        Assert.Contains("Hermione Granger/Draco Malfoy", name);
        Assert.Contains("Slow Burn", name);
        Assert.Contains("Explicit", name);
        Assert.Contains("Complete", name);
        Assert.DoesNotContain("Harry Potter", name); // fandom should be excluded
    }

    [Fact]
    public void SuggestedName_EmptyForNoSelection()
    {
        Assert.Equal("", new AO3SearchFilters().SuggestedName());
    }

    [Fact]
    public void RatingDisplayNames()
    {
        Assert.Equal("Explicit", Rating.Explicit.DisplayName());
        Assert.Equal("M/M", WorkCategory.MM.DisplayName());
        Assert.Equal("Kudos", SortColumn.KudosCount.DisplayName());
    }
}
