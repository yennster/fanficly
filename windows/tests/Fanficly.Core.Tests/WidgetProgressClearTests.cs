using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>#209: deleting or hiding a work, or clearing the history, forgets the
/// last-read entry, so the Continue reading widget and the jump list don't keep
/// the title; a hidden work's reader never writes it back.</summary>
[Collection(GlobalStoreCollection.Name)]
public sealed class WidgetProgressClearTests : IDisposable
{
    private readonly List<int?> _cleared = [];
    private readonly List<int> _saved = [];
    private readonly List<(int, bool)> _hidden = [];

    public WidgetProgressClearTests()
    {
        LibraryHooks.ClearWidgetProgress = id => { lock (_cleared) _cleared.Add(id); };
        LibraryHooks.SetWidgetProgressHidden = (id, hidden) => { lock (_hidden) _hidden.Add((id, hidden)); };
        LibraryHooks.SaveWidgetProgress = u => { lock (_saved) _saved.Add(u.Id); };
    }

    public void Dispose()
    {
        LibraryHooks.ClearWidgetProgress = null;
        LibraryHooks.SetWidgetProgressHidden = null;
        LibraryHooks.SaveWidgetProgress = null;
    }

    private static AO3WorkSummary Summary(int id) => new()
    {
        Id = id, Title = $"Work {id}", Author = "tester", ChapterCount = 1, TotalChapters = 1,
    };

    [Fact]
    public void DeletingAWorkClearsItsEntry()
    {
        using var store = LibraryStore.OpenInMemory();
        var work = WorkPersistence.UpsertMetadata(Summary(82001), store);
        WorkPersistence.DeleteWork(work, store);
        Assert.Equal([82001], _cleared);
    }

    [Fact]
    public void HidingAWorkHidesItsEntry_AndUnhidingLiftsThat()
    {
        using var store = LibraryStore.OpenInMemory();
        HiddenWorkStore.Hide(82002, "Work 82002", store);
        HiddenWorkStore.Hide(82002, "Work 82002", store);
        HiddenWorkStore.Unhide(82002, store);
        Assert.Equal([(82002, true), (82002, false)], _hidden);
    }

    [Fact]
    public void RemovingHistoryEntriesClearsTheirEntries()
    {
        using var store = LibraryStore.OpenInMemory();
        WorkPersistence.RecordView(Summary(82003), store);
        WorkPersistence.RecordView(Summary(82004), store);
        WorkPersistence.RemoveViews(store.All<RecentlyViewed>().Where(r => r.Ao3Id == 82003).ToList(), store);
        Assert.Equal([82003], _cleared);
        Assert.Single(store.All<RecentlyViewed>());
    }

    [Fact]
    public void ClearingTheHistoryClearsWhicheverWorkTheEntryNames()
    {
        using var store = LibraryStore.OpenInMemory();
        WorkPersistence.RecordView(Summary(82005), store);
        WorkPersistence.ClearRecentlyViewed(store);
        Assert.Equal([null], _cleared);
        Assert.Empty(store.All<RecentlyViewed>());
    }

    [Fact]
    public void AHiddenWorksReadingPlaceNeverBecomesTheLastReadEntry()
    {
        using var store = LibraryStore.OpenInMemory();
        ReadingProgressStore.Save(82006, 1, 0, "Work 82006", "tester", store, progress: 0.5);
        HiddenWorkStore.Hide(82007, "Work 82007", store);
        // The reader's closing save after "Hide this work".
        ReadingProgressStore.Save(82007, 1, 3, "Work 82007", "tester", store, progress: 0.6, syncWidgetImmediately: true);
        Assert.Equal([82006], _saved);
        // The place itself is still kept.
        Assert.Equal((1, 3), ReadingProgressStore.Load(82007, store));
    }
}
