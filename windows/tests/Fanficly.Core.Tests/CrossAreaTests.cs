namespace Fanficly.Core.Tests;

/// <summary>Swift test cases that span two ported areas (poller + routes,
/// parser + suggestions, demo client + content filter), ported once both
/// halves were merged.</summary>
public class CrossAreaTests
{
    private static readonly AuthorRef Author = new("some_login", "Some Pseud");

    private static NotificationRoute? Delivered(IReadOnlyDictionary<string, string> payload) =>
        // Delivery is a round trip through the toast's launch string.
        NotificationRoute.FromLaunchArguments(NotificationRoute.FromArguments(payload)!.ToLaunchArguments());

    private static AO3WorkSummary Stub(int id, string title) => new() { Id = id, Title = title };

    [Fact]
    public void NewChapterNotification_OpensTheWork()
    {
        var content = SubscriptionPoller.NewChapterContent("A Fic", 3, 5, 12345);
        Assert.Equal("2 new chapters posted (5 total)", content.Body);
        Assert.Equal(new NotificationRoute.NewChapters(12345), Delivered(content.Payload));
    }

    [Fact]
    public void SingleNewWorkNotification_OpensTheWork()
    {
        var content = SubscriptionPoller.NewWorkContent(Author.Username, Author.DisplayName, [Stub(67890, "Brand New")]);
        Assert.Equal("New work: Brand New", content.Body);
        Assert.Equal(new NotificationRoute.NewWork(67890), Delivered(content.Payload));
    }

    [Fact]
    public void SeveralNewWorksNotification_OpensTheAuthor()
    {
        var content = SubscriptionPoller.NewWorkContent(Author.Username, Author.DisplayName, [Stub(1, "One"), Stub(2, "Two")]);
        Assert.Equal("Some Pseud", content.Title);
        Assert.Equal("2 new works posted", content.Body);
        Assert.Equal(new NotificationRoute.NewWorks(Author), Delivered(content.Payload));
    }

    [Fact]
    public void SearchPage_TotalFound()
    {
        const string html = """
            <html><body><h3 class="heading">126,555 Found  <a class="help symbol question modal" href="/help">?</a></h3>
            <ol class="work index group"></ol></body></html>
            """;
        Assert.Equal(126_555, SearchResultsParser.Parse(html).TotalFound);
        Assert.Null(SearchResultsParser.Parse("<html><body><ol class=\"work index group\"></ol></body></html>").TotalFound);
    }

    [Fact]
    public async Task DemoCatalogIsAllAges()
    {
        var results = await new DemoAO3Client().SearchAsync(new AO3SearchFilters(), 1);
        Assert.NotEmpty(results.Works);
        // No Mature/Explicit works in the screenshot catalog.
        Assert.All(results.Works, w => Assert.DoesNotContain(w.Rating, ContentFilter.MatureRatings));
    }

    [Fact]
    public async Task DemoFetchWorkHasChapters()
    {
        var payload = await new DemoAO3Client().FetchWorkAsync(90001);
        Assert.Equal("The Long Way Home", payload.Summary.Title);
        Assert.NotEmpty(payload.Chapters);
        Assert.Contains("<p>", payload.Chapters[0].BodyHtml);
    }

    [Fact]
    public async Task DemoSearchFiltersByRating()
    {
        var filters = new AO3SearchFilters { Ratings = [Rating.General] };
        var results = await new DemoAO3Client().SearchAsync(filters, 1);
        Assert.All(results.Works, w => Assert.Equal("General Audiences", w.Rating));
    }
}
