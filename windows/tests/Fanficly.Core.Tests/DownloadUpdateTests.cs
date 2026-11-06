using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>A downloaded work in progress offers its new chapters (#180); port
/// of DownloadUpdateTests.swift.</summary>
public sealed class DownloadUpdateTests
{
    private static AO3WorkPayload Payload(int id, int chapters)
    {
        var summary = new AO3WorkSummary
        {
            Id = id, Title = $"Work {id}", Author = "tester", Rating = "General Audiences",
            Fandoms = ["Fandom"], WordCount = 1000, ChapterCount = chapters, Language = "English",
        };
        var chs = Enumerable.Range(1, chapters).Select(i => new AO3ChapterPayload(i, "", $"<p>Chapter {i}</p>")).ToList();
        return new AO3WorkPayload(summary, chs);
    }

    [Fact]
    public void NewChapterCountIsTheHighestKnownCountPastTheSavedChapters()
    {
        Assert.Equal(3, DownloadUpdate.NewChapterCount(5, [5, 8, null]));
        Assert.Equal(2, DownloadUpdate.NewChapterCount(5, [null, 6, 7]));
    }

    [Fact]
    public void NewChapterCountIsZeroWhenUpToDateOrUnknown()
    {
        Assert.Equal(0, DownloadUpdate.NewChapterCount(5, [5, 5]));
        Assert.Equal(0, DownloadUpdate.NewChapterCount(5, [null, null]));
        Assert.Equal(0, DownloadUpdate.NewChapterCount(5, []));
        // AO3 has fewer (a chapter deleted there): nothing to offer.
        Assert.Equal(0, DownloadUpdate.NewChapterCount(5, [4]));
    }

    [Fact]
    public void NewChapterCountIsZeroWithNothingSaved() =>
        // A bookmarked-only work reads live from AO3: nothing to update.
        Assert.Equal(0, DownloadUpdate.NewChapterCount(0, [9]));

    [Fact]
    public void BannerText()
    {
        Assert.Equal("1 new chapter on AO3", DownloadUpdate.BannerText(1));
        Assert.Equal("3 new chapters on AO3", DownloadUpdate.BannerText(3));
    }

    [Fact]
    public void LibraryWorkCountsItsFollowBaseline()
    {
        using var store = LibraryStore.OpenInMemory();
        var work = WorkPersistence.Upsert(Payload(1, 4), store);
        Assert.Equal(0, DownloadUpdate.NewChapterCount(work, store));

        // The poller saw chapter 6 go up.
        work.IsFollowed = true;
        work.LastSeenChapterCount = 6;
        Assert.Equal(2, DownloadUpdate.NewChapterCount(work, store));
    }

    [Fact]
    public void LibraryWorkCountsItsSubscriptionBaseline()
    {
        using var store = LibraryStore.OpenInMemory();
        var work = WorkPersistence.Upsert(Payload(2, 3), store);
        store.Insert(new SubscriptionRecord("work:2", "work", "Work 2") { LastSeenChapterCount = 7 });
        // Another work's subscription doesn't count.
        store.Insert(new SubscriptionRecord("work:20", "work", "Work 20") { LastSeenChapterCount = 40 });
        store.TrySave();

        Assert.Equal(4, DownloadUpdate.NewChapterCount(work, store));
    }

    [Fact]
    public void UpdatingTheDownloadAddsTheNewChaptersAndKeepsTheReadingPlace()
    {
        using var store = LibraryStore.OpenInMemory();
        var work = WorkPersistence.Upsert(Payload(3, 2), store);
        work.LastReadChapter = 2;
        work.LastReadProgress = 0.9;
        work.LastSeenChapterCount = 4;
        Assert.Equal(2, DownloadUpdate.NewChapterCount(work, store));

        var updated = WorkPersistence.Upsert(Payload(3, 4), store);
        Assert.Equal(4, store.ChaptersOf(updated).Count);
        Assert.Equal(2, updated.LastReadChapter);
        Assert.Equal(0.9, updated.LastReadProgress);
        Assert.Equal(0, DownloadUpdate.NewChapterCount(updated, store));
    }

    [Fact]
    public void ApplySavesTheNewChaptersAndMovesTheBaselines()
    {
        using var store = LibraryStore.OpenInMemory();
        var work = WorkPersistence.Upsert(Payload(4, 3), store);
        work.IsFollowed = true;
        work.LastSeenChapterCount = 6;
        var record = new SubscriptionRecord("work:4", "work", "Work 4") { LastSeenChapterCount = 6 };
        store.Insert(record);

        // AO3 has 5 now (one of the 6 the poller saw was deleted).
        var outcome = DownloadUpdate.Apply(Payload(4, 5), work, store);
        Assert.True(outcome.Updated);
        Assert.Equal(2, outcome.Added);
        Assert.Equal(5, store.ChaptersOf(work).Count);
        Assert.Equal(5, work.LastSeenChapterCount);
        Assert.Equal(5, record.LastSeenChapterCount);
        // So the banner doesn't come back offering a sixth.
        Assert.Equal(0, DownloadUpdate.NewChapterCount(work, store));
    }

    [Fact]
    public void ApplyNeverReplacesMoreSavedChaptersWithFewer()
    {
        using var store = LibraryStore.OpenInMemory();
        var work = WorkPersistence.Upsert(Payload(5, 8), store);
        Assert.Equal(new DownloadUpdate.Outcome(false, 0, 8, 5), DownloadUpdate.Apply(Payload(5, 5), work, store));
        Assert.Equal(8, store.ChaptersOf(work).Count);
    }

    [Fact]
    public void ApplyLeavesAnUnfollowedWorkWithoutABaseline()
    {
        using var store = LibraryStore.OpenInMemory();
        var work = WorkPersistence.Upsert(Payload(6, 1), store);
        Assert.Equal(1, DownloadUpdate.Apply(Payload(6, 2), work, store).Added);
        Assert.Null(work.LastSeenChapterCount);
    }
}
