using Fanficly.Core;

namespace Fanficly.Core.Tests;

[Collection(GlobalStoreCollection.Name)]
public class WidgetDataStoreTests
{
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
