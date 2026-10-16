using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Windows-only: the fanficly:// links RootView handles, parsed by the
/// shared pure parser the app's protocol activation and widget provider use.</summary>
public class DeepLinkTests
{
    private static DeepLink? Parse(string url) => DeepLink.Parse(url);

    [Fact]
    public void Resume_ParsesWorkAndAnchor()
    {
        Assert.Equal(new DeepLink.Resume(new ResumeWorkRoute(123, new ReadingAnchor(4, 17))),
                     Parse("fanficly://resume/123?chapter=4&paragraph=17"));
        // A missing paragraph is 0; no chapter means no anchor.
        Assert.Equal(new DeepLink.Resume(new ResumeWorkRoute(123, new ReadingAnchor(4, 0))), Parse("fanficly://resume/123?chapter=4"));
        Assert.Equal(new DeepLink.Resume(new ResumeWorkRoute(123, null)), Parse("fanficly://resume/123"));
        Assert.Equal(new DeepLink.Resume(new ResumeWorkRoute(123, null)), Parse("fanficly://resume/123?paragraph=9"));
    }

    [Fact]
    public void Resume_ClampsTheAnchor()
    {
        var route = DeepLink.ParseResumeRoute(new Uri("fanficly://resume/5?chapter=0&paragraph=-3"));
        Assert.Equal(new ResumeWorkRoute(5, new ReadingAnchor(1, 0)), route);
    }

    [Fact]
    public void Resume_NeedsANumericId()
    {
        Assert.Null(DeepLink.ParseResumeRoute(new Uri("fanficly://resume/abc")));
        Assert.Null(DeepLink.ParseResumeRoute(new Uri("fanficly://resume")));
        Assert.Null(DeepLink.ParseResumeRoute(new Uri("https://resume/123")));
        // A non-numeric chapter is ignored rather than failing the route.
        Assert.Equal(new ResumeWorkRoute(9, null), DeepLink.ParseResumeRoute(new Uri("fanficly://resume/9?chapter=x")));
    }

    [Fact]
    public void Import_FromTheShareTargetsEmbeddedURL()
    {
        var encoded = "fanficly://import?url=" + Uri.EscapeDataString("https://archiveofourown.org/works/48213/chapters/99");
        Assert.Equal(new DeepLink.Import(48213), Parse(encoded));
        Assert.Equal(new DeepLink.Import(48213), Parse("fanficly://import?url=https://archiveofourown.org/works/48213"));
        Assert.Null(Parse("fanficly://import?url=https://example.com/nothing"));
    }

    [Fact]
    public void Import_FromWorkPathsAndAO3Links()
    {
        Assert.Equal(new DeepLink.Import(77), Parse("fanficly://works/77"));
        Assert.Equal(new DeepLink.Import(77), Parse("fanficly://work/77"));
        Assert.Equal(new DeepLink.Import(77), Parse("fanficly://anything/77"));
        Assert.Equal(new DeepLink.Import(31), Parse("https://archiveofourown.org/Works/31?view_adult=true"));
    }

    [Fact]
    public void LibraryFolderAndSearch()
    {
        Assert.Equal(new DeepLink.LibraryFolder("Comfort Reads"), Parse("fanficly://library?folder=Comfort%20Reads"));
        Assert.Equal(new DeepLink.Search("tag:\"Slow Burn\" complete"), Parse(DeepLink.SearchUri("tag:\"Slow Burn\" complete").AbsoluteUri));
        Assert.Equal(new DeepLink.Search("a+b & c"), Parse(DeepLink.SearchUri("a+b & c").AbsoluteUri));
        Assert.Null(Parse("fanficly://search"));
        Assert.Null(Parse("fanficly://library?other=1"));
        Assert.Null(Parse("fanficly://settings"));
        Assert.Null(Parse("not a url"));
    }

    [Fact]
    public void BuiltLinksRoundTrip()
    {
        Assert.Equal("fanficly://resume/42?chapter=3&paragraph=8", DeepLink.ResumeUri(42, 3, 8).OriginalString);
        Assert.Equal("fanficly://resume/42", DeepLink.ResumeUri(42).OriginalString);
        Assert.Equal(new DeepLink.Resume(new ResumeWorkRoute(42, new ReadingAnchor(3, 8))), DeepLink.Parse(DeepLink.ResumeUri(42, 3, 8)));
        Assert.Equal(new DeepLink.LibraryFolder("Fluff & Stuff"), DeepLink.Parse(DeepLink.LibraryFolderUri("Fluff & Stuff")));
        Assert.Equal(new DeepLink.Import(5), DeepLink.Parse(DeepLink.ImportUri("https://archiveofourown.org/works/5")));
    }

    [Fact]
    public void WorkIdFromDroppedOrPastedText()
    {
        Assert.Equal(12, DeepLink.WorkIdFromText("  https://archiveofourown.org/works/12/chapters/3 \n"));
        Assert.Equal(12, DeepLink.WorkIdFromText("archiveofourown.org/works/12"));
        Assert.Null(DeepLink.WorkIdFromText("hello"));
        Assert.Null(DeepLink.WorkIdFromText("   "));
    }

    [Fact]
    public void SavedFilterJsonFromTheWidgetBecomesItsPrompt()
    {
        var filters = new AO3SearchFilters { FreeformNames = ["Fluff"] };
        var prompt = DeepLink.SearchPrompt(filters.ToJson());
        Assert.Equal(filters.PromptText(), prompt);
        Assert.Contains("Fluff", prompt);
        Assert.Equal("tag:\"Slow Burn\" complete", DeepLink.SearchPrompt("tag:\"Slow Burn\" complete"));
        Assert.Equal("{not json", DeepLink.SearchPrompt("{not json"));
    }
}
