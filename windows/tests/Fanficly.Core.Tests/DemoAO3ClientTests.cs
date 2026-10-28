using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class DemoAO3ClientTests
{
    private readonly DemoAO3Client _client = new();

    [Fact]
    public async Task UnfilteredSearchReturnsTheWholeCatalogInOrder()
    {
        var results = await _client.SearchAsync(new AO3SearchFilters(), 1);
        Assert.Equal(Enumerable.Range(90001, 8), results.Works.Select(w => w.Id));
        Assert.Equal(8, results.TotalFound);
    }

    [Fact]
    public async Task FiltersNarrowTheCatalog()
    {
        var f = new AO3SearchFilters { Ratings = [Rating.Teen], Complete = TriState.Yes };
        var results = await _client.SearchAsync(f, 1);
        Assert.Equal([90002, 90004, 90006], results.Works.Select(w => w.Id));

        var tagged = await _client.SearchAsync(new AO3SearchFilters { OtherTagNames = ["slow burn", "Soft"] }, 1);
        Assert.Equal([90002, 90006], tagged.Works.Select(w => w.Id));
    }

    [Fact]
    public async Task NoMatchFallsBackToEverything()
    {
        var results = await _client.SearchAsync(new AO3SearchFilters { FandomNames = ["Nothing Like This"] }, 1);
        Assert.Equal(8, results.Works.Count);
    }

    [Fact]
    public async Task WorkPayloadHasUpToThreeChapters()
    {
        var payload = await _client.FetchWorkAsync(90004);
        Assert.Equal(["Landfall", "What the Tide Brought", "The Long Way Home"], payload.Chapters.Select(c => c.Title));
        Assert.StartsWith("<p>The morning the engines finally went quiet", payload.Chapters[0].BodyHtml);
        Assert.EndsWith("“I tell them,” she said, “that the long way home is still the way home.”</p>", payload.Chapters[0].BodyHtml);
        // An unknown id shows the first work.
        Assert.Equal(90001, (await _client.FetchWorkAsync(1)).Summary.Id);
    }

    [Fact]
    public async Task IncompleteWorksReportTheirChapterSoFar()
    {
        var meta = await _client.FetchWorkMetadataAsync(90003);
        Assert.Equal(15, meta.ChapterCount);
        Assert.Equal(20, meta.TotalChapters);
    }

    [Fact]
    public async Task SeriesListsTheFirstThreeWorksInOrder()
    {
        var series = await _client.FetchSeriesAsync(5, 1);
        Assert.Equal(5, series.Id);
        Assert.Equal("The Lighthouse Letters", series.Title);
        Assert.Equal([90001, 90002, 90003], series.Works.Select(w => w.Id));
        Assert.Equal(3, series.WorkCount);
        Assert.True(series.IsComplete);
        // Its third work's page links back to it; listings carry no series.
        var part = Assert.Single((await _client.FetchWorkAsync(90003)).Summary.Series);
        Assert.Equal(DemoCatalog.DemoSeriesId, part.SeriesId);
        Assert.Equal(3, part.Position);
        Assert.Equal(90002, part.PreviousWorkId);
        Assert.Null(part.NextWorkId);
        Assert.Empty((await _client.FetchWorkAsync(90001)).Summary.Series);
        Assert.All((await _client.SearchAsync(new AO3SearchFilters(), 1)).Works, w => Assert.Empty(w.Series));
    }

    [Fact]
    public async Task TagAutocompleteDrawsFromTheCatalog()
    {
        var tags = await _client.AutocompleteAsync(AO3AutocompleteField.Tag, "slow");
        Assert.Equal(["Slow Burn"], tags);
        Assert.Equal(["anything"], await _client.AutocompleteAsync(AO3AutocompleteField.Fandom, "anything"));
    }
}
