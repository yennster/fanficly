using Fanficly.Core;

namespace Fanficly.Core.Tests;

[Collection(GlobalStoreCollection.Name)]
public class WidgetDataStoreTests
{
    /// <summary>A reading-position save rebuilds no library widget data, in
    /// the save or through the backup it queues; a library change still does
    /// (#165).</summary>
    [Fact]
    public void ReadingPositionSavesDontRebuildWidgetData()
    {
        var previous = LibraryHooks.UpdateWidgetData;
        var rebuilds = 0;
        LibraryHooks.UpdateWidgetData = _ => rebuilds++;
        try
        {
            using var store = LibraryStore.OpenInMemory();
            store.Changed += _ => LibrarySyncManager.QueueBackupShared(store);

            for (var paragraph = 0; paragraph < 3; paragraph++)
                ReadingProgressStore.Save(1, chapter: 1, paragraph: paragraph, title: "T", author: "A", store);
            Assert.Equal(0, rebuilds);

            store.Insert(new SavedSearch("S", "slow burn"));
            store.Save();
            Assert.Equal(1, rebuilds);
        }
        finally
        {
            LibraryHooks.UpdateWidgetData = previous;
        }
    }

    /// <summary>The app's path: the shared sync manager's
    /// <see cref="LibrarySyncManager.QueueBackup"/> (sync off) skips the rebuild
    /// for reading saves too, and still rebuilds for a library change.</summary>
    [Fact]
    public void ReadingPositionSavesDontRebuildWidgetData_ThroughTheSyncManager()
    {
        var previousHook = LibraryHooks.UpdateWidgetData;
        var previousShared = LibrarySyncManager.Shared;
        var rebuilds = 0;
        LibraryHooks.UpdateWidgetData = _ => rebuilds++;
        LibrarySyncManager.Shared = new LibrarySyncManager(new InMemoryKeyValueStore());
        try
        {
            using var store = LibraryStore.OpenInMemory();
            store.Changed += _ => LibrarySyncManager.QueueBackupShared(store);

            ReadingProgressStore.Save(1, chapter: 1, paragraph: 4, title: "T", author: "A", store);
            Assert.Equal(0, rebuilds);

            store.Insert(new SavedSearch("S", "slow burn"));
            store.Save();
            Assert.Equal(1, rebuilds);
        }
        finally
        {
            LibraryHooks.UpdateWidgetData = previousHook;
            LibrarySyncManager.Shared = previousShared;
        }
    }

    /// <summary>Rebuilding the library widgets' data reloads those four
    /// widgets, not Continue reading or the streak (#165).</summary>
    [Fact]
    public void UpdateAll_ReloadsOnlyTheLibraryWidgets()
    {
        WidgetDataStore.LocalOverride = new InMemoryKeyValueStore();
        WidgetDataStore.SharedOverride = new InMemoryKeyValueStore();
        var reloaded = new List<string?>();
        // Only this thread's reloads: a last-read reload an earlier test
        // scheduled can still land on the thread pool.
        var thread = Environment.CurrentManagedThreadId;
        void Record(string? kind) { if (Environment.CurrentManagedThreadId == thread) reloaded.Add(kind); }
        WidgetCenter.ReloadRequested += Record;
        try
        {
            WidgetDataStore.UpdateAll(new WidgetDataSources([], [], [], [], []));
            Assert.Equal<string?>(WidgetDataStore.LibraryWidgetKinds, reloaded);
            Assert.DoesNotContain(WidgetProgressStore.WidgetKind, reloaded);
            Assert.DoesNotContain(StreakStore.WidgetKind, reloaded);
        }
        finally
        {
            WidgetCenter.ReloadRequested -= Record;
            WidgetDataStore.LocalOverride = null;
            WidgetDataStore.SharedOverride = null;
        }
    }

    [Fact]
    public void WidgetDataStore_Serialization()
    {
        var local = new InMemoryKeyValueStore();
        var shared = new InMemoryKeyValueStore();
        WidgetDataStore.LocalOverride = local;
        WidgetDataStore.SharedOverride = shared;
        try
        {
            var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

            // The rows the Swift test inserted into SwiftData, as the database
            // layer hands them over.
            // 1. A saved search
            var search = new WidgetSavedSearchSource("My Harry Potter Search", "harry potter complete", now);
            // 2. A saved filter
            var filter = new WidgetSavedFilterSource("Drarry Filter", "{\"query\":\"Drarry\"}", now);
            // 3. A custom folder holding the work
            var folder = new WidgetFolderSource("Favorites", WorkCount: 1, CreatedAt: now);
            var work = new WidgetWorkSource
            {
                Ao3Id = 12345,
                Title = "An Epic Drarry Romance",
                AuthorName = "Jane Doe",
                Summary = "A summary with some <b>HTML</b> tags.",
                Fandoms = ["Harry Potter"],
                Relationships = ["Harry/Draco"],
                IsStarred = true,
                IsFollowed = true,
                SavedAt = now,
            };
            // 4. An online subscription
            var sub = new WidgetSubscriptionSource("work:67890", "work", "Online Work Title", "John Smith", 12, null);

            // Execute widget updates
            WidgetDataStore.UpdateAll(new WidgetDataSources([search], [filter], [folder], [work], [sub]), now);

            // Verify saved searches
            var savedSearches = WidgetDataStore.LoadLocalSavedSearches();
            Assert.Equal(2, savedSearches.Count);
            Assert.Contains(savedSearches, s => s.Name == "My Harry Potter Search" && s.Query == "harry potter complete" && !s.IsFilter);
            Assert.Contains(savedSearches, s => s.Name == "Drarry Filter" && s.Query == "{\"query\":\"Drarry\"}" && s.IsFilter);

            // Verify folder shortcuts
            var foldersList = WidgetDataStore.LoadLocalFolders();
            Assert.Single(foldersList);
            Assert.Equal("Favorites", foldersList[0].Name);
            Assert.Equal(1, foldersList[0].WorkCount);

            // Verify subscriptions tracker
            var subsList = WidgetDataStore.LoadLocalSubscriptions();
            Assert.Equal(2, subsList.Count);

            var localFollowSub = subsList.FirstOrDefault(s => s.WorkId == 12345);
            Assert.NotNull(localFollowSub);
            Assert.Equal("An Epic Drarry Romance", localFollowSub.Title);
            Assert.Equal("Jane Doe", localFollowSub.Author);
            Assert.True(localFollowSub.IsFollowed);

            var onlineSub = subsList.FirstOrDefault(s => s.WorkId == 67890);
            Assert.NotNull(onlineSub);
            Assert.Equal("Online Work Title", onlineSub.Title);
            Assert.Equal("John Smith", onlineSub.Author);
            Assert.False(onlineSub.IsFollowed);
            Assert.Equal(12, onlineSub.ChapterCount);

            // Verify recommendations
            var recs = WidgetDataStore.LoadLocalRecommendations();
            Assert.Single(recs);
            Assert.Equal(12345, recs[0].WorkId);
            Assert.Equal("An Epic Drarry Romance", recs[0].Title);
            Assert.Equal("Jane Doe", recs[0].Author);
            Assert.Equal("A summary with some HTML tags.", recs[0].Summary);
            Assert.Equal(["Harry Potter", "Harry/Draco"], recs[0].Tags);

            // Windows-only: both stores hold the Swift JSONEncoder shape
            // (dates as seconds since 2001-01-01).
            Assert.Equal(shared.GetString(WidgetDataStore.SubscriptionsKey), local.GetString(WidgetDataStore.SubscriptionsKey));
            Assert.Equal("[{\"name\":\"Favorites\",\"workCount\":1}]", shared.GetString(WidgetDataStore.CustomFoldersKey));
            Assert.Contains("\"updatedAt\":821692800", shared.GetString(WidgetDataStore.SubscriptionsKey));
        }
        finally
        {
            WidgetDataStore.LocalOverride = null;
            WidgetDataStore.SharedOverride = null;
        }
    }

    [Fact]
    public void Subscriptions_SortByUpdatedDateNotLastCheck()
    {
        // #197: a subscription polled a minute ago but updated months back
        // sorts below a follow updated yesterday; one never checked sorts last.
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        var works = new[]
        {
            new WidgetWorkSource { Ao3Id = 1, Title = "Followed", ChapterCount = 12, IsFollowed = true,
                                   SavedAt = now.AddDays(-30), UpdatedAt = now.AddDays(-1) },
        };
        var subs = new[]
        {
            new WidgetSubscriptionSource("work:2", "work", "Old", "", 3, now, now.AddDays(-200)),
            new WidgetSubscriptionSource("work:3", "work", "Fresh", "", 5, now.AddHours(-1), now),
            new WidgetSubscriptionSource("work:4", "work", "Unchecked", "", null, null),
        };

        var updates = WidgetDataStore.BuildSubscriptions(works, subs, now);

        Assert.Equal([3, 1, 2, 4], updates.Select(u => u.WorkId));
        Assert.Equal(12, updates[1].ChapterCount);
    }

    [Fact]
    public void Build_OrdersAndCapsLikeTheSwiftUpdater()
    {
        // Windows-only: the pure builders behind UpdateAll.
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        var works = Enumerable.Range(1, 25).Select(i => new WidgetWorkSource
        {
            Ao3Id = i, Title = $"W{i}", SavedAt = t0.AddDays(i), IsFollowed = true,
            IsPinned = i == 3, IsStarred = i == 2,
            Summary = new string('x', 200), Characters = ["C"],
        }).ToList();
        var subs = new[]
        {
            new WidgetSubscriptionSource("work:5", "work", "dup", "", 1, t0), // already followed
            new WidgetSubscriptionSource("work:", "work", "bad key", "", 1, t0),
            new WidgetSubscriptionSource("series:9", "series", "series", "", 1, t0),
        };

        var updates = WidgetDataStore.BuildSubscriptions(works, subs, t0);
        Assert.Equal(20, updates.Count);
        Assert.Equal(25, updates[0].WorkId); // newest first
        Assert.DoesNotContain(updates, u => u.Title is "dup" or "bad key" or "series");

        var recs = WidgetDataStore.BuildRecommendations(works);
        Assert.Equal(WidgetDataStore.ListLimit, recs.Count); // the top 20 only (#165)
        Assert.Equal([2, 3, 25], recs.Take(3).Select(r => r.WorkId)); // starred, pinned, then newest
        Assert.Equal(180, recs[0].Summary.Length);
        Assert.Equal(["C"], recs[0].Tags);

        var searches = WidgetDataStore.BuildSavedSearches(
            Enumerable.Range(1, 15).Select(i => new WidgetSavedSearchSource($"S{i}", "", t0.AddDays(i))),
            Enumerable.Range(1, 10).Select(i => new WidgetSavedFilterSource($"F{i}", "{}", t0.AddDays(i))));
        Assert.Equal(20, searches.Count);
        Assert.Equal("S15", searches[0].Name);
        Assert.Equal("F10", searches[15].Name);
    }
}
