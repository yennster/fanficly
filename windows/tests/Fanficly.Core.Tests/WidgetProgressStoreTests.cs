using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Windows-only: the last-read widget payload — the Swift encoding, the
/// freshest-copy-wins reads, and the debounced synced mirror.</summary>
[Collection(GlobalStoreCollection.Name)]
public sealed class WidgetProgressStoreTests : IDisposable
{
    private readonly InMemoryKeyValueStore _local = new();
    private readonly InMemoryKeyValueStore _shared = new();
    private readonly InMemoryKeyValueStore _cloud = new();
    private static readonly DateTimeOffset Noon = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);

    public WidgetProgressStoreTests()
    {
        WidgetProgressStore.LocalOverride = _local;
        WidgetProgressStore.SharedOverride = _shared;
        WidgetProgressStore.CloudOverride = _cloud;
    }

    public void Dispose()
    {
        WidgetProgressStore.FlushPendingCloudWrite();
        WidgetProgressStore.UninstallCloudSyncObserver();
        WidgetProgressStore.LocalOverride = null;
        WidgetProgressStore.SharedOverride = null;
        WidgetProgressStore.CloudOverride = null;
    }

    [Fact]
    public void Encoding_MatchesSwiftJSONEncoder()
    {
        var p = new WidgetStoryProgress(7, "Title", "Author", 0.5, 2, null, DateTimeOffset.FromUnixTimeSeconds(978_307_200 + 100));
        Assert.Equal("{\"id\":7,\"title\":\"Title\",\"author\":\"Author\",\"progress\":0.5,\"chapter\":2,\"updatedAt\":100}", p.Encode());
        Assert.Equal(p, WidgetStoryProgress.Decode(p.Encode()));
        Assert.Equal(p with { Chapter = null, UpdatedAt = null },
                     WidgetStoryProgress.Decode("{\"id\":7,\"title\":\"Title\",\"author\":\"Author\",\"progress\":0.5}"));
        Assert.Null(WidgetStoryProgress.Decode("{\"id\":7}"));
        Assert.Null(WidgetStoryProgress.Decode("garbage"));
        Assert.Equal(1, (p with { Progress = 3 }).ClampedProgress);
    }

    [Fact]
    public void Save_WritesBothLocalStores_AndMirrorsAfterTheDebounce()
    {
        WidgetProgressStore.Save(1, "A", "B", 0.25, chapter: 3, paragraph: 4, updatedAt: Noon);
        Assert.NotNull(_shared.GetString(WidgetProgressStore.LastReadProgressKey));
        Assert.Equal(_shared.GetString(WidgetProgressStore.LastReadProgressKey), _local.GetString(WidgetProgressStore.LastReadProgressKey));
        Assert.Null(_cloud.GetString(WidgetProgressStore.LastReadProgressKey)); // still debounced

        WidgetProgressStore.FlushPendingCloudWrite();
        Assert.Equal(1, WidgetStoryProgress.Decode(_cloud.GetString(WidgetProgressStore.LastReadProgressKey))?.Id);

        WidgetProgressStore.Save(2, "C", "D", 0.5, updatedAt: Noon.AddSeconds(1), syncImmediately: true);
        Assert.Equal(2, WidgetStoryProgress.Decode(_cloud.GetString(WidgetProgressStore.LastReadProgressKey))?.Id);
    }

    [Fact]
    public void Clear_RemovesEveryCopyNamingTheWork_AndLeavesOtherWorks()
    {
        WidgetProgressStore.Save(1, "A", "B", 0.25, updatedAt: Noon, syncImmediately: true);
        Assert.False(WidgetProgressStore.Clear(2));
        Assert.Equal(1, WidgetProgressStore.Load()?.Id);

        Assert.True(WidgetProgressStore.Clear(1));
        Assert.Null(_shared.GetString(WidgetProgressStore.LastReadProgressKey));
        Assert.Null(_local.GetString(WidgetProgressStore.LastReadProgressKey));
        Assert.Null(_cloud.GetString(WidgetProgressStore.LastReadProgressKey));
        Assert.Null(WidgetProgressStore.Load());
        Assert.False(WidgetProgressStore.Clear(1));
    }

    [Fact]
    public void Clear_KeepsAnOlderEntryForAnotherWork()
    {
        // The synced copy still names the work read before; only the deleted one goes.
        _cloud.SetString(WidgetProgressStore.LastReadProgressKey, new WidgetStoryProgress(2, "Old", "X", 0.5, null, null, Noon).Encode());
        WidgetProgressStore.Save(1, "A", "B", 0.25, updatedAt: Noon.AddSeconds(5));
        Assert.True(WidgetProgressStore.Clear(1));
        Assert.Equal(2, WidgetProgressStore.Load()?.Id);
    }

    [Fact]
    public void Clear_KeepsASyncedCopyFromBeforeIt_FromComingBack()
    {
        // Another PC sharing the sync folder pushes its older copy back after the clear.
        WidgetProgressStore.Save(1, "A", "B", 0.25, updatedAt: Noon, syncImmediately: true);
        var stale = _cloud.GetString(WidgetProgressStore.LastReadProgressKey);
        Assert.True(WidgetProgressStore.Clear(1));
        _cloud.SetString(WidgetProgressStore.LastReadProgressKey, stale);
        WidgetProgressStore.SyncCloudToLocal();
        Assert.Null(_shared.GetString(WidgetProgressStore.LastReadProgressKey));
        Assert.Null(WidgetProgressStore.Load());

        // Reading it again afterwards shows it again.
        WidgetProgressStore.Save(1, "A", "B", 0.5, updatedAt: DateTimeOffset.Now.AddMinutes(1));
        Assert.Equal(1, WidgetProgressStore.Load()?.Id);
    }

    [Fact]
    public void AHiddenWork_NeverComesBack_EvenFromANewerCopy_UntilUnhidden()
    {
        WidgetProgressStore.Save(1, "A", "B", 0.25, updatedAt: Noon, syncImmediately: true);
        Assert.True(WidgetProgressStore.SetHidden(1, hidden: true));
        Assert.Null(WidgetProgressStore.Load());

        // Another device still reading it saves a newer copy.
        var newer = new WidgetStoryProgress(1, "A", "B", 0.75, null, null, DateTimeOffset.Now.AddMinutes(1));
        _cloud.SetString(WidgetProgressStore.LastReadProgressKey, newer.Encode());
        WidgetProgressStore.SyncCloudToLocal();
        Assert.Null(WidgetProgressStore.Load());

        Assert.False(WidgetProgressStore.SetHidden(1, hidden: false));
        Assert.Equal(1, WidgetProgressStore.Load()?.Id);
    }

    [Fact]
    public void ClearMarks_RoundTrip_AndOldDatedOnesArePruned()
    {
        _local.SetString(WidgetProgressStore.ClearedKey, $"7:{Noon.ToUnixTimeSeconds()},*:{DateTimeOffset.Now.ToUnixTimeSeconds()},9:-,junk,x:1");
        WidgetProgressStore.Clear(8);
        var marks = WidgetProgressStore.LoadMarks();
        Assert.DoesNotContain(marks, m => m.Id == 7); // older than 90 days
        Assert.Contains(marks, m => m.Id is null && m.At is not null);
        Assert.Contains(marks, m => m.Id == 9 && m.At is null);
        Assert.Contains(marks, m => m.Id == 8 && m.At is not null);
        Assert.Equal(3, marks.Count);
    }

    [Fact]
    public void Clear_WithNoWork_RemovesWhicheverWorkItNames()
    {
        WidgetProgressStore.Save(1, "A", "B", 0.25, updatedAt: Noon, syncImmediately: true);
        Assert.True(WidgetProgressStore.Clear());
        Assert.Null(WidgetProgressStore.Load());
    }

    [Fact]
    public void Clear_DropsAPendingMirror_SoItCantWriteTheEntryBack()
    {
        WidgetProgressStore.Save(1, "A", "B", 0.25, updatedAt: Noon); // mirror still debounced
        Assert.True(WidgetProgressStore.Clear(1));
        WidgetProgressStore.FlushPendingCloudWrite();
        Assert.Null(_cloud.GetString(WidgetProgressStore.LastReadProgressKey));
        Assert.Null(WidgetProgressStore.Load());
    }

    [Fact]
    public void Load_TakesTheFreshestCopy()
    {
        WidgetProgressStore.Save(1, "Local", "", 0.1, updatedAt: Noon, syncImmediately: true);
        Assert.Equal("Local", WidgetProgressStore.Load()?.Title);

        // Another device's newer progress synced in.
        _cloud.SetString(WidgetProgressStore.LastReadProgressKey,
            new WidgetStoryProgress(2, "Cloud", "", 0.9, 5, 1, Noon.AddMinutes(5)).Encode());
        Assert.Equal("Cloud", WidgetProgressStore.Load()?.Title);
        Assert.Equal("Cloud", WidgetStoryProgress.Decode(_shared.GetString(WidgetProgressStore.LastReadProgressKey))?.Title);
    }

    [Fact]
    public void SyncCloudToLocal_NeverRegressesFresherLocalProgress()
    {
        WidgetProgressStore.InstallCloudSyncObserver();
        WidgetProgressStore.Save(1, "Local", "", 0.5, updatedAt: Noon);
        _cloud.SetString(WidgetProgressStore.LastReadProgressKey,
            new WidgetStoryProgress(1, "Older cloud", "", 0.1, 1, 0, Noon.AddMinutes(-5)).Encode());
        Assert.Equal("Local", WidgetStoryProgress.Decode(_local.GetString(WidgetProgressStore.LastReadProgressKey))?.Title);

        _cloud.SetString(WidgetProgressStore.LastReadProgressKey,
            new WidgetStoryProgress(1, "Newer cloud", "", 0.9, 9, 0, Noon.AddMinutes(5)).Encode());
        Assert.Equal("Newer cloud", WidgetStoryProgress.Decode(_local.GetString(WidgetProgressStore.LastReadProgressKey))?.Title);
    }
}
