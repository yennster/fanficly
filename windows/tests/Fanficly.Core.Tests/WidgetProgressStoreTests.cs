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
