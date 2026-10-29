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
    public void ChipsAreSearchsChipsWithoutTheFandom()
    {
        var filters = new AO3SearchFilters
        {
            SortColumn = SortColumn.KudosCount,
            SortDirection = SortDirection.Desc,
            FandomNames = ["Naruto"],
            OtherTagNames = ["Teen Wolf (TV)"],
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
        Assert.Equal("Kudos ↓", BrowseModels.SortLabel(filters));
        var chips = BrowseModels.FilterChips(filters).Select(c => c.Label).ToList();
        Assert.DoesNotContain("Naruto", chips); // the screen's title, not a filter
        Assert.Contains("Teen Wolf (TV)", chips);
        var general = chips.IndexOf($"Rated {Rating.General.DisplayName()}");
        Assert.True(general >= 0 && general < chips.IndexOf($"Rated {Rating.Teen.DisplayName()}")); // AO3's order
        Assert.Contains("A/B", chips);
        Assert.Contains("Not Angst", chips);
        Assert.Contains("Works in progress", chips);
        Assert.Contains("No crossovers", chips);
        Assert.Contains("One-shots", chips);
        Assert.Contains("In English", chips);
        Assert.Equal(11, BrowseModels.ActiveFilterCount(filters));

        var plain = new AO3SearchFilters { SortDirection = SortDirection.Asc, SortColumn = SortColumn.Title, FandomNames = ["Naruto"] };
        Assert.Equal("Title ↑", BrowseModels.SortLabel(plain));
        Assert.Empty(BrowseModels.FilterChips(plain));
        Assert.Equal(0, BrowseModels.ActiveFilterCount(plain));
    }

    /// <summary>#157 round trip: saved in Search with a fandom picked as a
    /// suggestion, applied in a Browse fandom and in Search with another fandom
    /// chip; each keeps its own fandom and shows every saved field.</summary>
    [Fact]
    public void SavedFilterAppliedInBrowseAndSearchKeepsTheCurrentFandom()
    {
        var searched = new AO3SearchFilters
        {
            OtherTagNames = ["Teen Wolf (TV)"],
            FreeformNames = ["Slow Burn"],
            Complete = TriState.Yes,
            KudosCount = ">100",
        };
        Assert.Equal(["Teen Wolf (TV)"], searched.UnsavedTagNames);
        var saved = AO3SearchFilters.FromSavedJson(searched.SavedJson())!;
        Assert.Empty(saved.OtherTagNames);

        var browse = BrowseModels.FiltersForFandom(new BrowseFandom("Harry Potter - J. K. Rowling"));
        browse.Ratings = [Rating.Explicit]; // replaced by the saved filter
        var inBrowse = browse.ApplyingSaved(saved);
        Assert.Equal(["Harry Potter - J. K. Rowling"], inBrowse.FandomNames);
        Assert.Empty(inBrowse.OtherTagNames);
        Assert.Empty(inBrowse.Ratings);
        Assert.Equal(["freeform|Slow Burn", "complete", "kudos"], BrowseModels.FilterChips(inBrowse).Select(c => c.Id));

        var search = new AO3SearchFilters { Query = "coffee shop", OtherTagNames = ["Sherlock (TV)"] };
        var inSearch = search.ApplyingSaved(saved);
        Assert.Equal("coffee shop", inSearch.Query);
        Assert.Equal(["tag|Sherlock (TV)", "freeform|Slow Burn", "complete", "kudos"], FilterChips.For(inSearch).Select(c => c.Id));
    }

    /// <summary>A filter saved before #157 may still carry search tags; the
    /// Browse landing page drops them.</summary>
    [Fact]
    public void OlderSavedFilterDropsItsSearchTags()
    {
        var old = new AO3SearchFilters { OtherTagNames = ["Teen Wolf (TV)"], Ratings = [Rating.Teen] };
        var json = old.ToJson();
        var loaded = BrowseModels.FiltersForSavedFilter(new SavedFilter("Old", json));
        Assert.Empty(loaded.OtherTagNames);
        Assert.Equal([Rating.Teen], loaded.Ratings);
    }

    [Fact]
    public void FilterChipsCoverEveryFieldAndRemoveOnlyTheirOwn()
    {
        var f = new AO3SearchFilters
        {
            Title = "Tea", Creators = "someone", OtherTagNames = ["Teen Wolf (TV)"], FandomNames = ["Naruto"],
            RelationshipNames = ["A/B"], CharacterNames = ["C"], FreeformNames = ["Fluff"],
            ExcludedTagNames = ["Major Character Death"], ExcludedFreeforms = ["Angst"],
            Ratings = [Rating.Teen], Warnings = [SearchEnums.AllWarnings[0]], Categories = [WorkCategory.MM],
            Complete = TriState.Yes, Crossover = TriState.No, SingleChapter = true, WordCount = ">10000",
            LanguageId = "en", KudosCount = ">100", Hits = ">1000", CommentsCount = ">10", BookmarksCount = ">5",
            RevisedAt = "< 1 week",
        };
        var chips = FilterChips.For(f);
        Assert.Equal(22, chips.Count);
        Assert.Contains(chips, c => c.Label == "Updated < 1 week");
        foreach (var chip in chips)
        {
            var removed = f.Clone();
            chip.Remove(removed);
            Assert.Equal(chips.Select(c => c.Id).Where(id => id != chip.Id), FilterChips.For(removed).Select(c => c.Id));
        }
        Assert.Empty(FilterChips.For(new AO3SearchFilters()));
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
