using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class MediaCategoryParserTests
{
    [Fact]
    public void ParsesFandomLinks()
    {
        const string html = """
        <html><body>
        <ol class="index group">
          <li><a class="tag" href="/tags/Marvel/works">Marvel</a> (12345)</li>
          <li><a class="tag" href="/tags/Star%20Wars%20-%20All%20Media%20Types/works">Star Wars - All Media Types</a> (9876)</li>
          <li><a class="tag" href="/tags/Twilight%20Series%20-%20Stephenie%20Meyer/works">Twilight Series - Stephenie Meyer</a> (1234)</li>
        </ol>
        </body></html>
        """;
        var fandoms = MediaCategoryParser.Parse(html);
        Assert.Equal(3, fandoms.Count);
        var names = fandoms.Select(f => f.CanonicalName).ToList();
        Assert.Contains("Marvel", names);
        Assert.Contains("Star Wars - All Media Types", names);
        Assert.Contains("Twilight Series - Stephenie Meyer", names);
    }

    [Fact]
    public void IgnoresNonWorksLinks()
    {
        const string html = """
        <html><body>
        <a href="/tags/Marvel">Filter</a>
        <a href="/tags/Marvel/works">Marvel</a>
        <a href="/tags/Marvel/bookmarks">Bookmarks</a>
        </body></html>
        """;
        var fandoms = MediaCategoryParser.Parse(html);
        Assert.Single(fandoms);
        Assert.Equal("Marvel", fandoms[0].CanonicalName);
    }

    [Fact]
    public void Dedupes()
    {
        const string html = """
        <html><body>
        <a href="/tags/Marvel/works">Marvel</a>
        <a href="/tags/Marvel/works">Marvel</a>
        </body></html>
        """;
        Assert.Single(MediaCategoryParser.Parse(html));
    }

    [Fact]
    public void SortsAlphabetically()
    {
        const string html = """
        <html><body>
        <a href="/tags/Zelda/works">Zelda</a>
        <a href="/tags/Avengers/works">Avengers</a>
        <a href="/tags/Marvel/works">Marvel</a>
        </body></html>
        """;
        var names = MediaCategoryParser.Parse(html).Select(f => f.CanonicalName).ToList();
        Assert.Equal(["Avengers", "Marvel", "Zelda"], names);
    }

    [Fact]
    public void ParsesWorkCounts()
    {
        const string html = """
        <html><body>
        <ol class="index group">
          <li><a class="tag" href="/tags/Marvel/works">Marvel</a> (12,345)</li>
          <li><a class="tag" href="/tags/Twilight/works">Twilight</a></li>
        </ol>
        </body></html>
        """;
        var fandoms = MediaCategoryParser.Parse(html);
        var marvel = fandoms.FirstOrDefault(f => f.CanonicalName == "Marvel");
        var twilight = fandoms.FirstOrDefault(f => f.CanonicalName == "Twilight");
        Assert.Equal(12345, marvel?.WorkCount); // comma-separated count is parsed
        Assert.NotNull(twilight);
        Assert.Null(twilight.WorkCount); // no parens → nil count
    }

    [Fact]
    public void TrailingCount()
    {
        Assert.Equal(123456, MediaCategoryParser.TrailingCount("Harry Potter (123,456)"));
        Assert.Equal(42, MediaCategoryParser.TrailingCount("Foo (Bar) (42)"));
        Assert.Null(MediaCategoryParser.TrailingCount("No count here"));
    }

    // Failing closed (RM-001)

    [Fact]
    public void NoFandomsFoundReturnsEmpty()
    {
        var html = AO3PageFixtures.GuestPage("fandoms-index", """
            <h2 class="heading"><a href="/media">Fandoms</a> &gt; Music &amp; Bands</h2>
            <h3 class="heading">No fandoms found</h3>
            """);
        Assert.Empty(MediaCategoryParser.Parse(html));
    }

    [Fact]
    public void GuestFandomsPageStillParses()
    {
        var html = AO3PageFixtures.GuestPage("fandoms-index", """
            <ol class="alphabet fandom index group">
              <li id="letter-M" class="letter listbox group"><ul class="tags index group">
                <li><a class="tag" href="/tags/Marvel/works">Marvel</a> (12345)</li>
              </ul></li>
            </ol>
            """);
        Assert.Equal(["Marvel"], MediaCategoryParser.Parse(html).Select(f => f.CanonicalName));
    }

    [Fact]
    public void LoginPageThrowsUnauthorized()
    {
        var e = Assert.Throws<AO3Exception>(() => MediaCategoryParser.Parse(AO3PageFixtures.LoginPage));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
    }

    public static TheoryData<string> GarbagePages =>
        [AO3PageFixtures.ErrorPage, "<html><body><p>Nothing here</p></body></html>"];

    [Theory]
    [MemberData(nameof(GarbagePages))]
    public void GarbagePageThrowsParseFailed(string html)
    {
        var e = Assert.Throws<AO3Exception>(() => MediaCategoryParser.Parse(html));
        Assert.Equal(AO3ErrorKind.ParseFailed, e.Kind);
    }
}

public class WorkFiltersParserTests
{
    private const string Html = """
    <html><body>
    <form id="work-filters">
      <fieldset>
        <legend>Relationships</legend>
        <ul class="tags index group">
          <li><label for="include_relationship_ids_1"><input id="include_relationship_ids_1" name="include_relationship_ids[]" type="checkbox" value="1"> Hermione Granger/Draco Malfoy <span class="count">(8,500)</span></label></li>
          <li><label for="include_relationship_ids_2"><input id="include_relationship_ids_2" name="include_relationship_ids[]" type="checkbox" value="2"> Harry Potter/Draco Malfoy <span class="count">(12,000)</span></label></li>
        </ul>
      </fieldset>
      <fieldset>
        <legend>Characters</legend>
        <ul class="tags index group">
          <li><label for="include_character_ids_9"><input id="include_character_ids_9" name="include_character_ids[]" type="checkbox" value="9"> Draco Malfoy <span class="count">(20,000)</span></label></li>
        </ul>
      </fieldset>
    </form>
    </body></html>
    """;

    [Fact]
    public void ParsesRelationshipFacetsWithCounts()
    {
        var filters = WorkFiltersParser.Parse(Html);
        Assert.Equal(2, filters.Relationships.Count);
        Assert.Equal(12000, filters.Relationships.FirstOrDefault(f => f.Name == "Harry Potter/Draco Malfoy")?.Count);
        Assert.Equal(8500, filters.Relationships.FirstOrDefault(f => f.Name == "Hermione Granger/Draco Malfoy")?.Count);
    }

    [Fact]
    public void ParsesCharacterFacets()
    {
        var filters = WorkFiltersParser.Parse(Html);
        Assert.Equal(["Draco Malfoy"], filters.Characters.Select(f => f.Name));
        Assert.Equal(20000, filters.Characters[0].Count);
        Assert.Empty(filters.Fandoms);
    }

    // Copied from the live filter sidebar on
    // https://archiveofourown.org/tags/Sherlock%20(TV)/works (July 2026): ids are
    // `include_work_search_<kind>_ids_<tag id>` and the name + count share one
    // plain span (no `span.count`). The exclude half repeats every tag under
    // `exclude_work_search_…` ids and must not be double-counted.
    private const string LiveHtml = """
    <html><body>
    <form id="work-filters">
      <dt id="toggle_include_fandom_tags" class="filter-toggle fandom tags">
        <span class="landmark">Include </span>Fandoms
      </dt>
      <dd id="include_fandom_tags" class="expandable fandom tags">
        <ul>
            <li>
              <label for="include_work_search_fandom_ids_150320251">
                  <input type="checkbox" name="include_work_search[fandom_ids][]" id="include_work_search_fandom_ids_150320251" value="150320251" />
                <span class="indicator" aria-hidden="true"></span><span>Sherlock (BBC TV 2010) (119208)</span>
    </label>                    </li>
        </ul>
      </dd>
      <dt id="toggle_include_relationship_tags" class="filter-toggle relationship tags">
        <span class="landmark">Include </span>Relationships
      </dt>
      <dd id="include_relationship_tags" class="expandable relationship tags">
        <ul>
            <li>
              <label for="include_work_search_relationship_ids_11006">
                  <input type="checkbox" name="include_work_search[relationship_ids][]" id="include_work_search_relationship_ids_11006" value="11006" />
                <span class="indicator" aria-hidden="true"></span><span>Sherlock Holmes/John Watson (57746)</span>
    </label>                    </li>
            <li>
              <label for="include_work_search_relationship_ids_142528">
                  <input type="checkbox" name="include_work_search[relationship_ids][]" id="include_work_search_relationship_ids_142528" value="142528" />
                <span class="indicator" aria-hidden="true"></span><span>Mycroft Holmes/Greg Lestrade (12345)</span>
    </label>                    </li>
        </ul>
      </dd>
      <dt id="toggle_include_character_tags" class="filter-toggle character tags">
        <span class="landmark">Include </span>Characters
      </dt>
      <dd id="include_character_tags" class="expandable character tags">
        <ul>
            <li>
              <label for="include_work_search_character_ids_4622">
                  <input type="checkbox" name="include_work_search[character_ids][]" id="include_work_search_character_ids_4622" value="4622" />
                <span class="indicator" aria-hidden="true"></span><span>Sherlock Holmes (93301)</span>
    </label>                    </li>
        </ul>
      </dd>
      <dt id="toggle_include_freeform_tags" class="filter-toggle freeform tags">
        <span class="landmark">Include </span>Additional Tags
      </dt>
      <dd id="include_freeform_tags" class="expandable freeform tags">
        <ul>
            <li>
              <label for="include_work_search_freeform_ids_110">
                  <input type="checkbox" name="include_work_search[freeform_ids][]" id="include_work_search_freeform_ids_110" value="110" />
                <span class="indicator" aria-hidden="true"></span><span>Fluff (17354)</span>
    </label>                    </li>
        </ul>
      </dd>
      <dt id="toggle_exclude_relationship_tags" class="filter-toggle relationship tags">
        <span class="landmark">Exclude </span>Relationships
      </dt>
      <dd id="exclude_relationship_tags" class="expandable relationship tags">
        <ul>
            <li>
              <label for="exclude_work_search_relationship_ids_11006">
                  <input type="checkbox" name="exclude_work_search[relationship_ids][]" id="exclude_work_search_relationship_ids_11006" value="11006" />
                <span class="indicator" aria-hidden="true"></span><span>Sherlock Holmes/John Watson (57746)</span>
    </label>                    </li>
        </ul>
      </dd>
    </form>
    </body></html>
    """;

    [Fact]
    public void ParsesLiveWorkSearchMarkup()
    {
        var filters = WorkFiltersParser.Parse(LiveHtml);
        Assert.Equal(["Sherlock Holmes/John Watson", "Mycroft Holmes/Greg Lestrade"], filters.Relationships.Select(f => f.Name));
        // The count comes from the trailing (N) in the plain span, not span.count.
        Assert.Equal(57746, filters.Relationships[0].Count);
        Assert.Equal(["Sherlock Holmes"], filters.Characters.Select(f => f.Name));
        Assert.Equal(93301, filters.Characters[0].Count);
        Assert.Equal(["Fluff"], filters.Freeforms.Select(f => f.Name));
        Assert.Equal(17354, filters.Freeforms[0].Count);
    }

    [Fact]
    public void LiveMarkup_KeepsParenthesesInsideTagNames()
    {
        var filters = WorkFiltersParser.Parse(LiveHtml);
        // Only the trailing count parens are stripped.
        Assert.Equal(["Sherlock (BBC TV 2010)"], filters.Fandoms.Select(f => f.Name));
        Assert.Equal(119208, filters.Fandoms[0].Count);
    }

    [Fact]
    public void LiveMarkup_IgnoresExcludeSection()
    {
        var filters = WorkFiltersParser.Parse(LiveHtml);
        // The exclude half repeats every tag and must not double-count.
        Assert.Single(filters.Relationships, f => f.Name == "Sherlock Holmes/John Watson");
    }

    // Failing closed (RM-001)

    /// <summary>A tag with no works renders the works index without the filter form.</summary>
    [Fact]
    public void TagWithNoWorksReturnsNoFacets()
    {
        var html = AO3PageFixtures.GuestPage("works-index", """
            <h2 class="heading">0 Works in Some Rare Tag</h2>
            <h3 class="landmark heading">Listing Works</h3>
            <ol class="work index group"></ol>
            """);
        var filters = WorkFiltersParser.Parse(html);
        Assert.Empty(filters.Relationships);
        Assert.Empty(filters.Characters);
        Assert.Empty(filters.Fandoms);
        Assert.Empty(filters.Freeforms);
    }

    [Fact]
    public void LoginPageThrowsUnauthorized()
    {
        var e = Assert.Throws<AO3Exception>(() => WorkFiltersParser.Parse(AO3PageFixtures.LoginPage));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
    }

    public static TheoryData<string> GarbagePages => [AO3PageFixtures.ErrorPage, AO3PageFixtures.ForeignPage];

    [Theory]
    [MemberData(nameof(GarbagePages))]
    public void GarbagePageThrowsParseFailed(string html)
    {
        var e = Assert.Throws<AO3Exception>(() => WorkFiltersParser.Parse(html));
        Assert.Equal(AO3ErrorKind.ParseFailed, e.Kind);
    }
}
