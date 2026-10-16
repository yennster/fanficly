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
