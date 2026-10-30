using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>A widget tap must never move saved reading progress backwards. The
/// widget's deep link bakes in an anchor from whenever the widget last refreshed —
/// potentially hours stale — so it may only seed progress that doesn't exist
/// yet; only a strictly fresher widget-store entry (progress synced from another
/// device) may override a local record.</summary>
public class ResumeProgressPolicyTests
{
    private static readonly DateTimeOffset Noon = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
    private static DateTimeOffset Earlier => Noon.AddSeconds(-3600);
    private static DateTimeOffset Later => Noon.AddSeconds(3600);

    private static readonly ReadingAnchor UrlAnchor = new(2, 5);
    private static readonly ReadingAnchor StoreAnchor = new(10, 3);

    // The audit's scenario 1: same work, local save stamped ReadingProgress and the
    // widget payload with the same date, but the tapped URL carries an old anchor.
    // Equal timestamps must NOT let the URL anchor through.
    [Fact]
    public void EqualTimestamps_StaleURLAnchorDoesNotOverwrite()
    {
        Assert.Null(ResumeProgressPolicy.AnchorToInstall(UrlAnchor, StoreAnchor, Noon, Noon));
    }

    // The audit's scenario 2: the widget store now holds a different work, so
    // there's no matching entry (nil anchor/freshness) — the stale URL anchor must
    // not overwrite the existing progress for the tapped work.
    [Fact]
    public void WidgetShowsOtherWork_StaleURLAnchorDoesNotOverwrite()
    {
        Assert.Null(ResumeProgressPolicy.AnchorToInstall(UrlAnchor, null, null, Noon));
    }

    [Fact]
    public void OlderStoreEntry_DoesNotOverwrite()
    {
        Assert.Null(ResumeProgressPolicy.AnchorToInstall(UrlAnchor, StoreAnchor, Earlier, Noon));
    }

    // The legitimate override: another device read further and its progress
    // synced through the widget store with a strictly newer stamp.
    [Fact]
    public void StrictlyFresherStoreEntry_InstallsStoreAnchorNotURL()
    {
        Assert.Equal(StoreAnchor, ResumeProgressPolicy.AnchorToInstall(UrlAnchor, StoreAnchor, Later, Noon));
    }

    // A fresher store entry without chapter data has nothing safe to install —
    // the untimestamped URL anchor must not ride in on its freshness.
    [Fact]
    public void FresherStoreEntryWithoutAnchor_InstallsNothing()
    {
        Assert.Null(ResumeProgressPolicy.AnchorToInstall(UrlAnchor, null, Later, Noon));
    }

    // No local progress yet (fresh install / cleared data): seeding is safe, and
    // the store payload wins over the possibly-stale URL snapshot.
    [Fact]
    public void NoLocalProgress_PrefersStoreAnchorOverURL()
    {
        Assert.Equal(StoreAnchor, ResumeProgressPolicy.AnchorToInstall(UrlAnchor, StoreAnchor, Earlier, null));
    }

    [Fact]
    public void NoLocalProgress_FallsBackToURLAnchor()
    {
        Assert.Equal(UrlAnchor, ResumeProgressPolicy.AnchorToInstall(UrlAnchor, null, null, null));
    }

    [Fact]
    public void NothingAvailable_InstallsNothing()
    {
        Assert.Null(ResumeProgressPolicy.AnchorToInstall(null, null, null, null));
    }

    // MARK: - Windows-only: RootView's matching of the widget entry to the route

    [Fact]
    public void RouteOverload_UsesOnlyTheTappedWorksStoreEntry()
    {
        var route = new ResumeWorkRoute(42, UrlAnchor);
        var sameWork = new WidgetStoryProgress(42, "T", "A", 0.5, 10, 3, Later);
        var otherWork = sameWork with { Id = 7 };
        var noChapter = sameWork with { Chapter = null };
        var clamped = sameWork with { Chapter = 0, Paragraph = -4 };

        Assert.Equal(StoreAnchor, ResumeProgressPolicy.AnchorToInstall(route, sameWork, Noon));
        Assert.Null(ResumeProgressPolicy.AnchorToInstall(route, otherWork, Noon));
        Assert.Equal(UrlAnchor, ResumeProgressPolicy.AnchorToInstall(route, otherWork, null));
        Assert.Null(ResumeProgressPolicy.AnchorToInstall(route, noChapter, Noon));
        Assert.Equal(new ReadingAnchor(1, 0), ResumeProgressPolicy.AnchorToInstall(route, clamped, null));
    }
}

/// <summary>Opening a story from the Library (not the widget) takes a strictly
/// newer place synced from another device too, and the reader doesn't save the
/// place it opened at until it moves (#160).</summary>
public class OpeningProgressPolicyTests
{
    private static readonly DateTimeOffset Noon = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
    private static readonly ReadingAnchor Local = new(12, 4);
    private static readonly ReadingAnchor Other = new(20, 7);
    private static WidgetStoryProgress Synced(DateTimeOffset? updatedAt) => new(1, "T", "A", 0.8, 20, 7, updatedAt);

    [Fact]
    public void FresherSyncedEntry_Wins()
    {
        Assert.Equal(Other, OpeningProgressPolicy.Anchor(1, Local, Noon, Synced(Noon.AddSeconds(60))));
    }

    [Fact]
    public void TiedOlderOtherWorkOrChapterlessEntry_LocalWins()
    {
        Assert.Equal(Local, OpeningProgressPolicy.Anchor(1, Local, Noon, Synced(Noon)));
        Assert.Equal(Local, OpeningProgressPolicy.Anchor(1, Local, Noon, Synced(Noon.AddSeconds(-60))));
        Assert.Equal(Local, OpeningProgressPolicy.Anchor(1, Local, Noon, Synced(Noon.AddSeconds(60)) with { Id = 2 }));
        Assert.Equal(Local, OpeningProgressPolicy.Anchor(1, Local, Noon,
            Synced(Noon.AddSeconds(60)) with { Chapter = null, Paragraph = null }));
    }

    [Fact]
    public void NoLocalProgress_OpensSyncedPlace()
    {
        Assert.Equal(Other, OpeningProgressPolicy.Anchor(1, null, null, Synced(null)));
        Assert.Null(OpeningProgressPolicy.Anchor(1, null, null, null));
    }

    [Fact]
    public void Gate_SkipsTheOpenedPlaceUntilTheReaderMoves()
    {
        var gate = new OpenedAnchorGate(Local);
        Assert.False(gate.AllowsSave(Local));
        Assert.False(gate.AllowsSave(Local));
        Assert.True(gate.AllowsSave(Other));
        Assert.True(gate.AllowsSave(Local));
        Assert.True(default(OpenedAnchorGate).AllowsSave(new ReadingAnchor(1, 0)));
    }
}
