using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class AO3EndpointsTests
{
    private readonly Uri _base = new("https://archiveofourown.org");

    [Fact]
    public void WorkURL_IncludesFullAndAdult()
    {
        var s = AO3Endpoints.Work(12345, _base).AbsoluteUri;
        Assert.Contains("/works/12345", s);
        Assert.Contains("view_full_work=true", s);
        Assert.Contains("view_adult=true", s);
    }

    [Fact]
    public void WorkPageURL_IsAdultWithoutFullWork() =>
        Assert.Equal("https://archiveofourown.org/works/12345?view_adult=true", AO3Endpoints.WorkPage(12345, _base).AbsoluteUri);

    [Fact]
    public void AuthorWorksURL_Paginates()
    {
        var p1 = AO3Endpoints.AuthorWorks("HoweverSheWrites", 1, _base);
        Assert.Equal("https://archiveofourown.org/users/HoweverSheWrites/works", p1.AbsoluteUri);
        var p3 = AO3Endpoints.AuthorWorks("HoweverSheWrites", 3, _base);
        Assert.Contains("/users/HoweverSheWrites/works", p3.AbsoluteUri);
        Assert.Contains("page=3", p3.AbsoluteUri);
    }

    [Fact]
    public void AuthorLogin_FromByline()
    {
        Assert.Equal("HoweverSheWrites", SearchResultsParser.AuthorLogin("/users/HoweverSheWrites/pseuds/HoweverSheWrites"));
        Assert.Equal("some_user", SearchResultsParser.AuthorLogin("/users/some_user"));
        Assert.Equal("", SearchResultsParser.AuthorLogin(""));
        Assert.Equal("", SearchResultsParser.AuthorLogin("/works/123"));
    }

    [Fact]
    public void DownloadURL_PerFormat()
    {
        foreach (var format in WorkExportFormatExtensions.All)
        {
            var uri = AO3Endpoints.Download(99, format, _base);
            Assert.Equal($"https://archiveofourown.org/downloads/99/work.{format.Ext()}", uri.AbsoluteUri);
        }
    }

    [Fact]
    public void AutocompleteURL_PercentEncodesSlash()
    {
        // AO3's autocomplete 404s on a raw slash in the query, so the term's "/"
        // must be percent-encoded as %2F (a ship like "Hermione/Draco").
        var s = AO3Endpoints.Autocomplete("relationship", "harry/draco", _base).AbsoluteUri;
        Assert.Contains("/autocomplete/relationship", s);
        Assert.Contains("term=harry%2Fdraco", s);
        Assert.DoesNotContain("term=harry/draco", s);
    }

    [Fact]
    public void AutocompleteURL_EncodesSpaces()
    {
        var s = AO3Endpoints.Autocomplete("character", "Hermione Granger", _base).AbsoluteUri;
        Assert.Contains("term=Hermione%20Granger", s);
    }

    [Fact]
    public void MediaFandomsURL_EncodesAO3Path()
    {
        // AO3 encodes special characters: & -> *a*, / -> *s*, . -> *d*
        var s = AO3Endpoints.MediaFandoms("Cartoons & Comics & Graphic Novels", _base).AbsoluteUri;
        Assert.Contains("/media/", s);
        Assert.Contains("*a*", s); // the & became *a*
        Assert.EndsWith("/fandoms", s);
        Assert.DoesNotContain(" ", s); // spaces encoded
    }

    [Fact]
    public void WorkCommentsURL_HasFragmentAndShowComments()
    {
        var uri = AO3Endpoints.WorkComments(5, _base);
        Assert.Contains("show_comments=true", uri.AbsoluteUri);
        Assert.Equal("#comments", uri.Fragment);
    }

    [Fact]
    public void SearchURL_Paginates()
    {
        var filters = new AO3SearchFilters { FreeformNames = ["Fluff"] };
        Assert.DoesNotContain("page=", AO3Endpoints.Search(filters, 1, _base).AbsoluteUri);
        Assert.Contains("page=3", AO3Endpoints.Search(filters, 3, _base).AbsoluteUri);
    }

    [Fact]
    public void UserSubscriptionsURL_Paginates()
    {
        var p1 = AO3Endpoints.UserSubscriptions("reader", 1, _base);
        Assert.Equal("https://archiveofourown.org/users/reader/subscriptions", p1.AbsoluteUri);
        var p2 = AO3Endpoints.UserSubscriptions("reader", 2, _base);
        Assert.Contains("/users/reader/subscriptions", p2.AbsoluteUri);
        Assert.Contains("page=2", p2.AbsoluteUri);
    }

    [Fact]
    public void UserMarkedForLaterURL_Paginates()
    {
        Assert.Equal("https://archiveofourown.org/users/reader/readings?show=to-read",
            AO3Endpoints.UserMarkedForLater("reader", 1, _base).AbsoluteUri);
        Assert.Equal("https://archiveofourown.org/users/reader/readings?show=to-read&page=2",
            AO3Endpoints.UserMarkedForLater("reader", 2, _base).AbsoluteUri);
    }

    [Fact]
    public void UserReadingHistoryURL_Paginates()
    {
        Assert.Equal("https://archiveofourown.org/users/reader/readings",
            AO3Endpoints.UserReadingHistory("reader", 1, _base).AbsoluteUri);
        Assert.Equal("https://archiveofourown.org/users/reader/readings?page=4",
            AO3Endpoints.UserReadingHistory("reader", 4, _base).AbsoluteUri);
    }

    [Fact]
    public void WorkSubscriptionsURL()
    {
        Assert.Equal("https://archiveofourown.org/works/42/subscriptions", AO3Endpoints.WorkSubscriptions(42, _base).AbsoluteUri);
    }

    // Windows-only checks on the hand-written encoders.

    [Fact]
    public void AO3PathEncode_MapsEverySpecialCharacter()
    {
        Assert.Equal("A*a*B*s*C*d*D*q*E*at*s%20F", AO3Endpoints.AO3PathEncode("A&B/C.D?E's F"));
        Assert.Equal("Pok%C3%A9mon%20%23", AO3Endpoints.AO3PathEncode("Pokémon #"));
    }

    [Fact]
    public void TagWorksURL_EncodesTag()
    {
        Assert.Equal("https://archiveofourown.org/tags/Sherlock%20(TV)/works",
            AO3Endpoints.TagWorks("Sherlock (TV)", _base).AbsoluteUri);
    }

    [Fact]
    public void SearchURL_EncodesQueryValues()
    {
        var filters = new AO3SearchFilters { OtherTagNames = ["Hurt/Comfort", "A & B"] };
        var s = AO3Endpoints.Search(filters, 1, _base).AbsoluteUri;
        Assert.StartsWith("https://archiveofourown.org/works/search?", s);
        Assert.Contains("work_search%5Bother_tag_names%5D=Hurt%2FComfort%2C%20A%20%26%20B", s);
    }

    [Fact]
    public void ChapterCommentsURL()
    {
        var uri = AO3Endpoints.ChapterComments(9, 42, _base);
        Assert.Equal("https://archiveofourown.org/works/9/chapters/42?view_adult=true&show_comments=true#comments", uri.AbsoluteUri);
    }

    [Fact]
    public void CommentsURLs_Paginate()
    {
        Assert.Equal("https://archiveofourown.org/works/9/chapters/42?view_adult=true&show_comments=true&page=3#comments",
            AO3Endpoints.ChapterComments(9, 42, _base, page: 3).AbsoluteUri);
        // A one-shot has no chapter id; its work-level thread paginates the same way.
        Assert.Equal("https://archiveofourown.org/works/9?view_adult=true&show_comments=true&page=2#comments",
            AO3Endpoints.WorkComments(9, _base, page: 2).AbsoluteUri);
        Assert.DoesNotContain("page=", AO3Endpoints.WorkComments(9, _base, page: 1).AbsoluteUri);
    }
}
