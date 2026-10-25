using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Port of ContentSafetyTests.swift. The three DemoAO3Client cases
/// live with the DemoAO3Client port.</summary>
public sealed class ContentSafetyTests
{
    private static AO3WorkSummary Summary(int id, string rating) => new()
    {
        Id = id, Title = $"Work {id}", Author = "a", Summary = "", Rating = rating,
        WordCount = 0, ChapterCount = 1, TotalChapters = 1, Language = "English",
        Kudos = 0, Hits = 0, IsComplete = true, UpdatedAt = null,
    };

    // MARK: HiddenWorkStore

    [Fact]
    public void HideThenUnhide()
    {
        using var ctx = LibraryStore.OpenInMemory();
        Assert.False(HiddenWorkStore.IsHidden(42, ctx));

        HiddenWorkStore.Hide(42, "Secret", ctx);
        Assert.True(HiddenWorkStore.IsHidden(42, ctx));

        // Idempotent: hiding twice doesn't duplicate.
        HiddenWorkStore.Hide(42, "Secret", ctx);
        Assert.Single(ctx.All<HiddenWork>());

        HiddenWorkStore.Unhide(42, ctx);
        Assert.False(HiddenWorkStore.IsHidden(42, ctx));
    }

    // MARK: Blocklist (RM-006)

    private static AO3WorkSummary Tagged(int id, string author = "someone", string login = "someone",
                                         string[]? fandoms = null, string[]? relationships = null,
                                         string[]? freeforms = null, string[]? warnings = null) => new()
    {
        Id = id, Title = $"Work {id}", Author = author, AuthorUsername = login, Summary = "",
        Rating = "General Audiences", Warnings = warnings ?? [], Fandoms = fandoms ?? [],
        Relationships = relationships ?? [], Freeforms = freeforms ?? [],
        WordCount = 0, ChapterCount = 1, TotalChapters = 1, Language = "English",
        Kudos = 0, Hits = 0, IsComplete = true, UpdatedAt = null,
    };

    private static List<int> Kept(IEnumerable<AO3WorkSummary> works, Blocklist blocklist) =>
        ContentFilter.Apply(works, new HashSet<int>(), filterMature: false, blocklist).Select(w => w.Id).ToList();

    [Fact]
    public void BlockedTagMatchesCaseInsensitivelyByAO3Name()
    {
        AO3WorkSummary[] works =
        [
            Tagged(1, freeforms: ["Alternate Universe - Coffee Shops & Cafés"]),
            Tagged(2, relationships: ["Hermione Granger/Draco Malfoy"]),
            Tagged(3, fandoms: ["Harry Potter - J. K. Rowling"], warnings: ["Major Character Death"]),
            Tagged(4, freeforms: ["Fluff"]),
        ];
        var blocklist = new Blocklist(
            ["alternate universe - coffee shops & cafés", " HERMIONE GRANGER/DRACO MALFOY ", "major character death"], []);
        Assert.Equal([4], Kept(works, blocklist));
    }

    [Fact]
    public void BlockedTagNeedsTheWholeAO3Name()
    {
        AO3WorkSummary[] works =
        [
            Tagged(1, freeforms: ["Alternate Universe - Coffee Shops & Cafés"]),
            Tagged(2, fandoms: ["Harry Potter - J. K. Rowling"]),
        ];
        Assert.Equal([1, 2], Kept(works, new Blocklist(["Coffee Shops", "Harry Potter"], [])));
    }

    [Fact]
    public void BlockedAuthorMatchesLoginOrDisplayName()
    {
        AO3WorkSummary[] works =
        [
            Tagged(1, author: "Pseud (writer)", login: "writer"),
            Tagged(2, author: "Anonymous", login: ""),
            Tagged(3, author: "Other", login: "other"),
        ];
        Assert.Equal([3], Kept(works, new Blocklist([], ["Writer", "anonymous"])));
    }

    [Fact]
    public void BlockedAuthorMatchesAnyCoAuthor()
    {
        AO3WorkSummary[] works =
        [
            Tagged(1, author: "First, Second Pseud (second)", login: "first"),
            Tagged(2, author: "First, Third", login: "first"),
        ];
        Assert.Equal([2], Kept(works, new Blocklist([], ["second"])));
        Assert.Equal([1], Kept(works, new Blocklist([], ["Third"])));
    }

    [Fact]
    public void BlocklistWithNoMatchKeepsEverything()
    {
        AO3WorkSummary[] works = [Tagged(1, freeforms: ["Fluff"]), Tagged(2, login: "writer")];
        Assert.Equal([1, 2], Kept(works, new Blocklist(["Angst"], ["nobody"])));
    }

    [Fact]
    public void EmptyBlocklistKeepsEverything()
    {
        AO3WorkSummary[] works = [Tagged(1, freeforms: ["Fluff"]), Tagged(2, author: "", login: "")];
        Assert.True(Blocklist.Empty.IsEmpty);
        Assert.Equal([1, 2], Kept(works, Blocklist.Empty));
        Assert.True(new Blocklist(["  "], [""]).IsEmpty);
    }

    [Fact]
    public void BlockedTermsAskedForByNameAreLifted()
    {
        AO3WorkSummary[] works = [Tagged(1, login: "writer", fandoms: ["Teen Wolf (TV)"], warnings: ["Major Character Death"])];
        var blocklist = new Blocklist(["teen wolf (tv)", "Major Character Death"], ["writer"]);
        var filters = new AO3SearchFilters { OtherTagNames = ["Teen Wolf (TV)"], Warnings = [ArchiveWarning.MajorCharacterDeath] };
        // Still blocked by author until the search names the creator too.
        Assert.Empty(Kept(works, blocklist.Lifting(filters)));
        filters.Creators = "Writer";
        Assert.Equal([1], Kept(works, blocklist.Lifting(filters)));
    }

    [Fact]
    public void BlockThenUnblock()
    {
        using var ctx = LibraryStore.OpenInMemory();
        BlocklistStore.Block(BlockedTermKind.Tag, "Major Character Death", ctx);
        // Same term in another case is the same block.
        BlocklistStore.Block(BlockedTermKind.Tag, "major character death", ctx);
        BlocklistStore.Block(BlockedTermKind.Author, "writer", ctx);
        Assert.Equal(2, ctx.All<BlockedTerm>().Count);
        Assert.True(BlocklistStore.IsBlocked(BlockedTermKind.Tag, "MAJOR CHARACTER DEATH", ctx));
        Assert.False(BlocklistStore.IsBlocked(BlockedTermKind.Author, "Major Character Death", ctx));

        var blocklist = Blocklist.From(ctx);
        Assert.True(blocklist.Blocks(Tagged(1, warnings: ["Major Character Death"])));
        Assert.True(blocklist.Blocks(Tagged(2, login: "writer")));

        BlocklistStore.Unblock(BlockedTermKind.Tag, "Major Character Death", ctx);
        Assert.False(BlocklistStore.IsBlocked(BlockedTermKind.Tag, "Major Character Death", ctx));
        Assert.Single(ctx.All<BlockedTerm>());
    }

    // MARK: Story images

    [Theory]
    [InlineData("General Audiences", true)]
    [InlineData("Teen And Up Audiences", true)]
    [InlineData("Mature", false)]
    [InlineData("Explicit", false)]
    [InlineData("Not Rated", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void StoryImagesOnlyForGeneralAndTeenWorks(string? rating, bool allowed) =>
        Assert.Equal(allowed, ContentFilter.AllowsStoryImages(rating));

    // MARK: ContentFilter

    [Fact]
    public void FilterDropsMatureAndExplicitWhenOn()
    {
        AO3WorkSummary[] works =
        [
            Summary(1, "General Audiences"),
            Summary(2, "Teen And Up Audiences"),
            Summary(3, "Mature"),
            Summary(4, "Explicit"),
        ];
        var kept = ContentFilter.Apply(works, new HashSet<int>(), filterMature: true);
        Assert.Equal([1, 2], kept.Select(w => w.Id));
    }

    [Fact]
    public void FilterKeepsAllRatingsWhenOff()
    {
        AO3WorkSummary[] works = [Summary(3, "Mature"), Summary(4, "Explicit")];
        var kept = ContentFilter.Apply(works, new HashSet<int>(), filterMature: false);
        Assert.Equal(2, kept.Count);
    }

    [Fact]
    public void FilterDropsHiddenIds()
    {
        AO3WorkSummary[] works = [Summary(1, "General Audiences"), Summary(2, "General Audiences")];
        var kept = ContentFilter.Apply(works, new HashSet<int> { 2 }, filterMature: true);
        Assert.Equal([1], kept.Select(w => w.Id));
    }
}
