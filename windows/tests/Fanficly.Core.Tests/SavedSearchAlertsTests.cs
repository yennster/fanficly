using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>New-fic alerts for saved searches (#309): the check runs exactly the
/// saved search by date posted, its first run only takes a baseline, only newly
/// posted works alert (not old works that now match, nor hidden or filtered
/// ones), and the alert state merges forward-only between devices. The Swift
/// app's tests are in <c>PersistenceTests</c> and <c>NotificationRouteTests</c>.</summary>
public sealed class SavedSearchAlertsTests
{
    private static readonly DateTimeOffset T0 = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    private static AO3WorkSummary Work(int id, int chapters = 1, DateTimeOffset? updated = null, string rating = "General Audiences") =>
        new() { Id = id, Title = $"Fic {id}", ChapterCount = chapters, UpdatedAt = updated, Rating = rating };

    private static SavedSearch Alerting(LibraryStore store, string prompt = "tag:\"Slow Burn\"")
    {
        var search = new SavedSearch("Slow burn", prompt);
        store.Insert(search);
        SavedSearchAlerts.SetAlerts(true, search, store);
        return search;
    }

    [Fact]
    public void FiltersRunTheSavedSearchByDatePosted()
    {
        var filters = SavedSearchAlerts.Filters("teen wolf tag:\"Slow Burn\" complete:yes");
        Assert.Equal("teen wolf", filters.Query);
        Assert.Equal(["Slow Burn"], filters.OtherTagNames);
        // "teen" stays a keyword: search never guesses.
        Assert.Empty(filters.Ratings);
        Assert.Equal(SortColumn.CreatedAt, filters.SortColumn);
        Assert.Equal(SortDirection.Desc, filters.SortDirection);
    }

    [Fact]
    public async Task FirstCheckOnlyTakesTheBaseline()
    {
        using var store = LibraryStore.OpenInMemory();
        var search = Alerting(store);
        var client = new PollerFakeClient { SearchResults = [Work(30), Work(20)] };
        var notifier = new RecordingNotifier();

        var posted = await new SubscriptionPoller(client, store, null, notifier).CheckSavedSearchAlertsAsync();

        Assert.Equal(0, posted);
        Assert.Empty(notifier.Posted);
        Assert.Equal([30, 20], search.AlertKnownWorkIds);
        Assert.NotNull(search.AlertsBaselineAt);
        Assert.NotNull(search.AlertsLastCheckedAt);
        Assert.Equal(SortColumn.CreatedAt, Assert.Single(client.SearchFilters).SortColumn);
    }

    [Fact]
    public async Task AlertsForNewlyPostedWorksOnly()
    {
        using var store = LibraryStore.OpenInMemory();
        var search = Alerting(store);
        var client = new PollerFakeClient { SearchResults = [Work(30), Work(20)] };
        var notifier = new RecordingNotifier();
        var poller = new SubscriptionPoller(client, store, null, notifier);
        await poller.CheckSavedSearchAlertsAsync();

        // 40 is new; 10 has four chapters and a lower id: an old work that now
        // matches the search, not a new one.
        client.SearchResults = [Work(40), Work(30), Work(10, chapters: 4), Work(20)];
        Assert.Equal(1, await poller.CheckSavedSearchAlertsAsync());
        var note = Assert.Single(notifier.Posted);
        Assert.Equal(("Slow burn", "New fic: Fic 40"), (note.Title, note.Body));
        Assert.Equal("searchMatch", note.Payload["kind"]);
        Assert.Equal([40], search.AlertNewWorkIds);
        Assert.Equal([40, 30, 20, 10], search.AlertKnownWorkIds);

        // Nothing new: no alert, and the "New" count stays until it's seen.
        Assert.Equal(0, await poller.CheckSavedSearchAlertsAsync());
        Assert.Equal([40], search.AlertNewWorkIds);
        SavedSearchAlerts.MarkSeen(search, store);
        Assert.Empty(search.AlertNewWorkIds);
    }

    [Fact]
    public async Task HiddenAndMatureWorksDontAlert()
    {
        using var store = LibraryStore.OpenInMemory();
        var search = Alerting(store);
        store.Insert(new HiddenWork(41, "Hidden"));
        store.Save();
        var client = new PollerFakeClient { SearchResults = [Work(30)] };
        var notifier = new RecordingNotifier();
        var poller = new SubscriptionPoller(client, store, null, notifier);
        await poller.CheckSavedSearchAlertsAsync();

        // The mature filter is on by default.
        client.SearchResults = [Work(42, rating: "Explicit"), Work(41), Work(30)];
        Assert.Equal(0, await poller.CheckSavedSearchAlertsAsync());
        Assert.Empty(notifier.Posted);
        Assert.Empty(search.AlertNewWorkIds);
        // Both still join the baseline, so they never alert later either.
        Assert.Equal([42, 41, 30], search.AlertKnownWorkIds);
    }

    [Fact]
    public async Task FullPollChecksOnlySearchesWithAlerts()
    {
        using var store = LibraryStore.OpenInMemory();
        store.Insert(new SavedSearch("Quiet", "fluff"));
        store.Save();
        var client = new PollerFakeClient { SearchResults = [] };
        await new SubscriptionPoller(client, store, null).RunFullPollAsync();
        Assert.Empty(client.SearchFilters);

        Alerting(store, "angst");
        await new SubscriptionPoller(client, store, null).RunFullPollAsync();
        Assert.Equal("angst", Assert.Single(client.SearchFilters).Query);
    }

    // An AO3 search can take half a minute; a search edited meanwhile must not
    // take the old search's results as its baseline.
    [Fact]
    public async Task SearchEditedMidCheckKeepsItsFreshBaseline()
    {
        using var store = LibraryStore.OpenInMemory();
        var search = Alerting(store);
        var client = new PollerFakeClient { SearchResults = [Work(30)] };
        client.OnRequest = _ =>
        {
            SavedSearchAlerts.ResetBaseline(search);
            search.Prompt = "angst";
        };
        await new SubscriptionPoller(client, store, null).CheckSavedSearchAlertsAsync();
        Assert.Empty(search.AlertKnownWorkIds);
        Assert.Null(search.AlertsBaselineAt);
    }

    [Fact]
    public void NewMatchesRules()
    {
        var lastCheck = T0;
        var recent = lastCheck.AddHours(-1);
        var old = lastCheck.AddDays(-30);
        AO3WorkSummary[] works = [Work(70, chapters: 3), Work(58, updated: recent), Work(57, updated: old),
                                  Work(56, chapters: 2, updated: recent), Work(60)];
        // 70 is newer than every seen work; 58 is a one-shot posted since the
        // last check (a draft or a revealed gift); 57 is an old one-shot and 56
        // an old multi-chapter work that now match the search.
        Assert.Equal([70, 58], SavedSearchAlerts.NewMatches(works, new HashSet<int> { 50, 60 }, true, lastCheck).Select(w => w.Id));
        // No baseline yet: never alert for what's already there.
        Assert.Empty(SavedSearchAlerts.NewMatches(works, new HashSet<int>(), false, null));
        // A baseline of no results: everything that turns up is new.
        Assert.Equal(5, SavedSearchAlerts.NewMatches(works, new HashSet<int>(), true, lastCheck).Count);
    }

    [Fact]
    public void BaselineKeepsTheNewestIds()
    {
        var kept = SavedSearchAlerts.Baseline(Enumerable.Range(1, 250), [300]);
        Assert.Equal(SavedSearchAlerts.KnownWorkIdLimit, kept.Count);
        Assert.Equal(300, kept[0]);
        Assert.DoesNotContain(1, kept);
    }

    [Fact]
    public void AlertLimit()
    {
        using var store = LibraryStore.OpenInMemory();
        for (var i = 0; i < SavedSearchAlerts.MaxAlertingSearches; i++)
            store.Insert(new SavedSearch($"S{i}", $"p{i}") { AlertsEnabled = true });
        store.Insert(new SavedSearch("Off", "off"));
        store.Save();
        Assert.False(SavedSearchAlerts.CanEnableMore(store));
    }

    [Fact]
    public void OpeningAnAlertedWorkTakesItOffTheNewCount()
    {
        using var store = LibraryStore.OpenInMemory();
        var search = Alerting(store);
        search.AlertNewWorkIds = [1, 2];
        SavedSearchAlerts.MarkWorkSeen(1, store);
        Assert.Equal([2], search.AlertNewWorkIds);
    }

    // MARK: - Backup merge (Swift's mergedSearch)

    private static SearchBackup Backup(string prompt = "angst", DateTimeOffset? savedAt = null, bool? enabled = true,
                                       DateTimeOffset? changedAt = null, IReadOnlyList<int>? known = null,
                                       DateTimeOffset? baselineAt = null, DateTimeOffset? checkedAt = null) =>
        new("Angst", prompt, "_score", "desc", savedAt ?? T0, enabled, changedAt, known, baselineAt, checkedAt);

    [Fact]
    public void Merge_SameAlertsUnionTheirBaselines()
    {
        var local = Backup(changedAt: T0, known: [1, 2], baselineAt: T0.AddMinutes(1), checkedAt: T0.AddMinutes(2));
        var other = Backup(changedAt: T0, known: [2, 3], baselineAt: T0.AddSeconds(30), checkedAt: T0.AddMinutes(3));
        var merged = LibrarySyncManager.MergedSearch(local, other);
        Assert.Equal([3, 2, 1], merged.AlertKnownWorkIds);
        Assert.Equal(T0.AddSeconds(30), merged.AlertsBaselineAt);
        Assert.Equal(T0.AddMinutes(3), merged.AlertsLastCheckedAt);
        Assert.True(merged.AlertsEnabled);
    }

    [Fact]
    public void Merge_LaterSwitchWins()
    {
        var on = Backup(enabled: true, changedAt: T0, known: [1, 2], baselineAt: T0);
        var off = Backup(enabled: null, changedAt: T0.AddMinutes(1));
        Assert.Null(LibrarySyncManager.MergedSearch(on, off).AlertsEnabled);
        Assert.Null(LibrarySyncManager.MergedSearch(on, off).AlertKnownWorkIds);
        Assert.Null(LibrarySyncManager.MergedSearch(off, on).AlertsEnabled);
    }

    [Fact]
    public void Merge_EditedSearchKeepsTheNewerBaseline()
    {
        var local = Backup(prompt: "angst", changedAt: T0, known: [1, 2], baselineAt: T0);
        var other = Backup(prompt: "angst complete:yes", savedAt: T0.AddMinutes(1), changedAt: T0);
        var merged = LibrarySyncManager.MergedSearch(local, other);
        Assert.Equal("angst complete:yes", merged.Prompt);
        Assert.Equal(T0.AddMinutes(1), merged.SavedAt);
        Assert.Null(merged.AlertKnownWorkIds);
        Assert.Null(merged.AlertsBaselineAt);
    }

    [Fact]
    public void Merge_OlderBackupKeepsLocalAlerts()
    {
        var local = Backup(changedAt: T0, known: [5], baselineAt: T0);
        var legacy = new SearchBackup("Angst", "angst", "_score", "desc", T0);
        var merged = LibrarySyncManager.MergedSearch(local, legacy);
        Assert.True(merged.AlertsEnabled);
        Assert.Equal([5], merged.AlertKnownWorkIds);
        Assert.Equal(T0, merged.AlertsBaselineAt);
    }

    // The fields are written as the Swift app writes them (optional keys left
    // out when unset), so a file from either app reads back the same.
    [Fact]
    public void AlertFieldsRoundTripThroughTheBackupFile()
    {
        const string json = """
            {"works":[],"bookmarks":[],"subscriptions":[],"searches":[{"name":"Angst","prompt":"angst","sortColumn":"_score","sortDirection":"desc","savedAt":"2026-04-01T10:00:00Z","alertsEnabled":true,"alertsChangedAt":"2026-04-02T10:00:00Z","alertKnownWorkIds":[30,20],"alertsBaselineAt":"2026-04-02T10:00:05Z","alertsLastCheckedAt":"2026-04-03T10:00:00Z"},{"name":"Old","prompt":"old","sortColumn":"_score","sortDirection":"desc","savedAt":"2026-04-01T10:00:00Z"}],"progress":[],"filters":[],"hidden":[],"timestamp":"2026-04-03T10:00:00Z"}
            """;
        var searches = LibraryBackupJson.Decode(json).Searches;
        var alerting = searches.Single(s => s.Name == "Angst");
        Assert.True(alerting.AlertsEnabled);
        Assert.Equal([30, 20], alerting.AlertKnownWorkIds);
        Assert.Equal(new DateTimeOffset(2026, 4, 2, 10, 0, 5, TimeSpan.Zero), alerting.AlertsBaselineAt);
        var old = searches.Single(s => s.Name == "Old");
        Assert.Null(old.AlertsEnabled);
        Assert.Null(old.AlertKnownWorkIds);

        var again = LibraryBackupJson.Decode(LibraryBackupJson.Encode(LibraryBackupJson.Decode(json))).Searches;
        Assert.Equal([30, 20], again.Single(s => s.Name == "Angst").AlertKnownWorkIds);
        Assert.Equal(alerting.AlertsLastCheckedAt, again.Single(s => s.Name == "Angst").AlertsLastCheckedAt);
        Assert.DoesNotContain("alertsEnabled\":false", System.Text.Encoding.UTF8.GetString(LibraryBackupJson.Encode(LibraryBackupJson.Decode(json))));
    }
}
