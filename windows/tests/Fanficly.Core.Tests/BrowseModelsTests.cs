using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class BrowseModelsTests
{
    [Fact]
    public void FandomFiltersSortByLatestUpdate()
    {
        var filters = BrowseModels.FiltersForFandom(new BrowseFandom("Naruto"));
        Assert.Equal(["Naruto"], filters.FandomNames);
        Assert.Equal(SortColumn.RevisedAt, filters.SortColumn);
        Assert.Equal(SortDirection.Desc, filters.SortDirection);
    }

    [Fact]
    public void SavedFilterRoundTripsAndToleratesGarbage()
    {
        var original = new AO3SearchFilters { FreeformNames = ["Slow Burn"], Complete = TriState.Yes, FandomNames = ["Ignored"] };
        var saved = new SavedFilter("Slow Burn", original.SavedJson());
        var loaded = BrowseModels.FiltersForSavedFilter(saved);
        Assert.Equal(["Slow Burn"], loaded.FreeformNames);
        Assert.Equal(TriState.Yes, loaded.Complete);
        Assert.Empty(loaded.FandomNames);

        Assert.True(BrowseModels.FiltersForSavedFilter(new SavedFilter("Bad", "nope")).IsEmpty);
    }

    [Fact]
    public void ChipsStartWithSortAndListEveryFilter()
    {
        var filters = new AO3SearchFilters
        {
            SortColumn = SortColumn.KudosCount,
            SortDirection = SortDirection.Desc,
            Ratings = [Rating.Teen, Rating.General],
            Categories = [WorkCategory.MM],
            RelationshipNames = ["A/B"],
            ExcludedFreeforms = ["Angst"],
            Complete = TriState.No,
            Crossover = TriState.No,
            SingleChapter = true,
            WordCount = "1000-5000",
            LanguageId = "en",
        };
        var chips = BrowseModels.FilterChips(filters);
        Assert.Equal("Kudos ↓", chips[0]);
        Assert.Equal(Rating.General.DisplayName(), chips[1]); // rating order is AO3's, not insertion order
        Assert.Equal(Rating.Teen.DisplayName(), chips[2]);
        Assert.Contains("A/B", chips);
        Assert.Contains("−Angst", chips);
        Assert.Contains("WIP", chips);
        Assert.Contains("No crossovers", chips);
        Assert.Contains("Oneshot", chips);
        Assert.Contains("words 1000-5000", chips);
        Assert.Contains("lang en", chips);
        Assert.Equal(10, BrowseModels.ActiveFilterCount(filters));

        var plain = new AO3SearchFilters { SortDirection = SortDirection.Asc, SortColumn = SortColumn.Title };
        Assert.Equal(["Title ↑"], BrowseModels.FilterChips(plain));
        Assert.Equal(0, BrowseModels.ActiveFilterCount(plain));
    }

    [Fact]
    public void TagFieldsSplitOnCommas()
    {
        Assert.Equal(["Slow Burn", "Fluff"], BrowseModels.SplitTags(" Slow Burn, ,Fluff ,"));
        Assert.Empty(BrowseModels.SplitTags("  "));
    }

    [Theory]
    [InlineData("1000", "5000", "1000-5000")]
    [InlineData("1000", "", ">1000")]
    [InlineData("", "5000", "<5000")]
    [InlineData(" ", "", "")]
    public void WordCountBuildsAndParsesBack(string from, string to, string expected)
    {
        var built = BrowseModels.BuildWordCount(from, to);
        Assert.Equal(expected, built);
        Assert.Equal((from.Trim(), to.Trim()), BrowseModels.ParseWordCount(built));
    }

    [Fact]
    public void FandomSourceOnlyFallsBackAfterAFailure()
    {
        var category = FandomCatalog.All[0];
        IReadOnlyList<BrowseFandom> none = [];
        Assert.Empty(BrowseModels.FandomSource(none, failed: false, category));
        Assert.Equal(category.Fandoms, BrowseModels.FandomSource(none, failed: true, category));
        IReadOnlyList<BrowseFandom> live = [new BrowseFandom("Live", workCount: 3)];
        Assert.Equal(live, BrowseModels.FandomSource(live, failed: true, category));
    }

    [Fact]
    public void FandomSearchIsCaseInsensitive()
    {
        IReadOnlyList<BrowseFandom> source = [new BrowseFandom("Haikyuu!!"), new BrowseFandom("Naruto"), new BrowseFandom("One Piece")];
        Assert.Equal(["Haikyuu!!"], BrowseModels.FilterFandoms(source, " haik ").Select(f => f.DisplayName));
        Assert.Equal(3, BrowseModels.FilterFandoms(source, "").Count);
        Assert.Empty(BrowseModels.FilterFandoms(source, "zzz"));
    }

    [Fact]
    public void FandomHeaderAndErrors()
    {
        Assert.Equal("2 of 10 fandoms", BrowseModels.FandomHeader(2, 10));
        Assert.Equal("14 popular fandoms", BrowseModels.FandomHeader(14, 0));
        Assert.Equal("AO3 didn't recognise that category. Showing popular fandoms only.",
            BrowseModels.FandomLoadError(AO3Exception.Http(404)));
        Assert.StartsWith("Couldn't load full list (", BrowseModels.FandomLoadError(AO3Exception.Http(500)));
        Assert.EndsWith("Showing popular fandoms only.", BrowseModels.FandomLoadError(AO3Exception.Network("offline")));
    }
}
