using System.Diagnostics;
using System.Globalization;

namespace Fanficly.Core;

/// <summary>A local notification to show (title, body) and the route payload
/// a tap opens — <c>NotificationRoute.ToArguments()</c>'s shape.</summary>
public sealed record LocalNotification(
    string Identifier,
    string Title,
    string Body,
    IReadOnlyDictionary<string, string> Payload);

/// <summary>Posts local notifications (toast notifications on Windows).</summary>
public interface ILocalNotifier
{
    Task PostAsync(LocalNotification notification);
}

/// <summary>Builds the tap-route payloads the poller's notifications carry.
/// The app installs one backed by <c>NotificationRoute.ToArguments()</c>; the
/// default writes the Swift app's <c>userInfo</c> keys (kind, workId,
/// authorUsername, authorName) as strings.</summary>
public interface INotificationRoutePayloads
{
    IReadOnlyDictionary<string, string> NewChapters(int workId);
    IReadOnlyDictionary<string, string> NewWork(int workId);
    IReadOnlyDictionary<string, string> NewWorks(string authorUsername, string authorName);
    IReadOnlyDictionary<string, string> SearchMatch(int workId);
    IReadOnlyDictionary<string, string> SavedSearch(string name, string prompt);
}

/// <summary>The default payloads: the Swift <c>NotificationRoute.userInfo</c> keys.</summary>
public sealed class DefaultNotificationRoutePayloads : INotificationRoutePayloads
{
    public IReadOnlyDictionary<string, string> NewChapters(int workId) => new Dictionary<string, string>
    {
        ["kind"] = "newChapters",
        ["workId"] = workId.ToString(CultureInfo.InvariantCulture),
    };

    public IReadOnlyDictionary<string, string> NewWork(int workId) => new Dictionary<string, string>
    {
        ["kind"] = "newWork",
        ["workId"] = workId.ToString(CultureInfo.InvariantCulture),
    };

    public IReadOnlyDictionary<string, string> NewWorks(string authorUsername, string authorName) => new Dictionary<string, string>
    {
        ["kind"] = "newWorks",
        ["authorUsername"] = authorUsername,
        ["authorName"] = authorName,
    };

    public IReadOnlyDictionary<string, string> SearchMatch(int workId) => new Dictionary<string, string>
    {
        ["kind"] = "searchMatch",
        ["workId"] = workId.ToString(CultureInfo.InvariantCulture),
    };

    public IReadOnlyDictionary<string, string> SavedSearch(string name, string prompt) => new Dictionary<string, string>
    {
        ["kind"] = "savedSearch",
        ["searchName"] = name,
        ["searchPrompt"] = prompt,
    };
}

/// <summary>Checks AO3 for news on everything the user follows: account
/// subscriptions (when logged in), locally-followed works (new chapters),
/// locally-followed authors (new works) and saved searches with alerts on (new
/// matching works, #309), posting a local notification for each.</summary>
public sealed class SubscriptionPoller
{
    private readonly IAO3Client _client;
    private readonly LibraryStore _store;
    private readonly ILocalNotifier? _notifier;

    /// <summary>Route payload builder for notifications; the app replaces it with
    /// one backed by <c>NotificationRoute</c>.</summary>
    public static INotificationRoutePayloads RoutePayloads { get; set; } = new DefaultNotificationRoutePayloads();

    /// <param name="username">AO3 username for syncing account subscriptions;
    /// null when logged out (locally-followed works are still polled).</param>
    public SubscriptionPoller(IAO3Client client, LibraryStore store, string? username, ILocalNotifier? notifier = null)
    {
        _client = client;
        _store = store;
        Username = username;
        _notifier = notifier;
    }

    public string? Username { get; }

    /// <summary>Mirrors the account's AO3 subscription list into
    /// <see cref="SubscriptionRecord"/>s. Fails closed on pruning: an empty fetch
    /// with records on hand is far more likely a stale session or markup drift
    /// than a mass unsubscribe, and a wrong delete also destroys the
    /// LastSeenChapterCount baselines new-chapter alerts compare against.</summary>
    public async Task<IReadOnlyList<AO3Subscription>> SyncSubscriptionListAsync(CancellationToken ct = default)
    {
        if (Username is not { } username) return [];
        var fresh = await _client.FetchSubscriptionsAsync(username, ct).ConfigureAwait(false);
        var freshKeys = fresh.Select(s => s.Key).ToHashSet();

        var existing = _store.All<SubscriptionRecord>();
        var existingByKey = new Dictionary<string, SubscriptionRecord>();
        foreach (var rec in existing) existingByKey[rec.Key] = rec;

        foreach (var sub in fresh)
        {
            if (existingByKey.TryGetValue(sub.Key, out var rec))
            {
                rec.DisplayName = sub.Title;
                rec.AuthorName = sub.Author ?? rec.AuthorName;
            }
            else
            {
                var created = new SubscriptionRecord(sub.Key, AO3Subscription.KindRaw(sub.Kind), sub.Title, sub.Author ?? "");
                _store.Insert(created);
                existingByKey[sub.Key] = created;
            }
        }
        // (The parser already throws on a login page; this guards the rest.)
        if (fresh.Count > 0)
            foreach (var rec in existing)
                if (!freshKeys.Contains(rec.Key)) _store.Delete(rec);
        _store.TrySave();
        return fresh;
    }

    /// <summary>How many per-record checks failed (AO3 down, signed out, a page
    /// that didn't read), so a refresh doesn't report "no new chapters" when it
    /// couldn't look.</summary>
    public int FailedChecks { get; private set; }

    /// <summary>A check found the session expired: signed in, but AO3 served a
    /// followed author's works as a guest page, without restricted works (see
    /// <c>AuthState.MarkSessionExpired</c>).</summary>
    public bool SessionExpired { get; private set; }

    public async Task<int> CheckForNewChaptersAsync(CancellationToken ct = default)
    {
        var notifyCount = 0;
        foreach (var rec in WorkSubscriptionRecords()) notifyCount += await CheckWorkSubscriptionAsync(rec, ct).ConfigureAwait(false);
        _store.TrySave();
        return notifyCount;
    }

    /// <summary>Poll locally-followed works (no AO3 login required) for new chapters.</summary>
    public async Task<int> CheckFollowedWorksAsync(CancellationToken ct = default)
    {
        var notifyCount = 0;
        foreach (var work in FollowedWorks()) notifyCount += await CheckFollowedWorkAsync(work, ct).ConfigureAwait(false);
        _store.TrySave();
        return notifyCount;
    }

    /// <summary>Poll locally-followed authors (no AO3 login required) for newly
    /// published works, notifying once per new work.</summary>
    public async Task<int> CheckFollowedAuthorsAsync(CancellationToken ct = default)
    {
        var notifyCount = 0;
        foreach (var author in FollowedAuthors()) notifyCount += await CheckFollowedAuthorAsync(author, ct).ConfigureAwait(false);
        _store.TrySave();
        return notifyCount;
    }

    /// <summary>Check saved searches with alerts on (#309) for newly posted works.</summary>
    public async Task<int> CheckSavedSearchAlertsAsync(CancellationToken ct = default)
    {
        var notifyCount = 0;
        foreach (var search in AlertingSearches())
        {
            if (ct.IsCancellationRequested) break;
            notifyCount += await CheckSavedSearchAsync(search, ct).ConfigureAwait(false);
            _store.TrySave();
        }
        return notifyCount;
    }

    /// <summary>The full background poll. Interleaves all four record kinds
    /// oldest-check-first rather than a fixed subs → works → authors order: every
    /// check costs one throttled (1 req/s) request and a background run gets
    /// limited time, so a fixed order would permanently starve the last
    /// category; oldest-first means whatever was cut off last time runs first
    /// this time. Saves after every record and stops cleanly on cancellation.
    /// Returns the number of notifications posted.</summary>
    public async Task<int> RunFullPollAsync(CancellationToken ct = default)
    {
        try
        {
            await SyncSubscriptionListAsync(ct).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            LibraryHooks.Log?.Invoke($"Subscriptions list fetch failed: {e.Message}");
        }

        var targets = new List<(DateTimeOffset? LastCheckedAt, Func<Task<int>> Check)>();
        if (Username is not null)
            targets.AddRange(WorkSubscriptionRecords().Select(r => (r.LastCheckedAt, (Func<Task<int>>)(() => CheckWorkSubscriptionAsync(r, ct)))));
        targets.AddRange(FollowedWorks().Select(w => (w.LastCheckedAt, (Func<Task<int>>)(() => CheckFollowedWorkAsync(w, ct)))));
        targets.AddRange(FollowedAuthors().Select(a => (a.LastCheckedAt, (Func<Task<int>>)(() => CheckFollowedAuthorAsync(a, ct)))));
        targets.AddRange(AlertingSearches().Select(s => (s.AlertsAttemptedAt ?? s.AlertsLastCheckedAt, (Func<Task<int>>)(() => CheckSavedSearchAsync(s, ct)))));
        var ordered = targets.OrderBy(t => t.LastCheckedAt ?? DateTimeOffset.MinValue).ToList();

        var total = 0;
        foreach (var target in ordered)
        {
            // The scheduler cancels us at expiry — stop cleanly and keep the
            // progress saved so far.
            if (ct.IsCancellationRequested) break;
            total += await target.Check().ConfigureAwait(false);
            // Save after every record so an expiring run keeps its
            // LastCheckedAt stamps — they drive the rotation.
            _store.TrySave();
        }
        LibraryHooks.UpdateWidgetData?.Invoke(_store);
        return total;
    }

    // MARK: - Per-record checks

    /// <summary>Check one AO3 work subscription for a new chapter (one throttled
    /// request). Returns the number of notifications posted. The attempt is
    /// stamped whatever happens: a permanently-failing record (deleted work,
    /// parse drift) must not stay "oldest" forever and hog the queue head.</summary>
    private async Task<int> CheckWorkSubscriptionAsync(SubscriptionRecord rec, CancellationToken ct)
    {
        try
        {
            var parts = rec.Key.Split(':');
            if (parts.Length != 2 || !int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var workId))
                return 0;
            try
            {
                var meta = await _client.FetchWorkMetadataAsync(workId, ct).ConfigureAwait(false);
                var notifyCount = 0;
                if (rec.LastSeenChapterCount is { } lastSeen && meta.ChapterCount > lastSeen)
                {
                    await PostAsync(NewChapterContent(rec.DisplayName, lastSeen, meta.ChapterCount, workId)).ConfigureAwait(false);
                    notifyCount = 1;
                }
                rec.LastSeenChapterCount = meta.ChapterCount;
                return notifyCount;
            }
            catch (Exception e)
            {
                FailedChecks++;
                LibraryHooks.Log?.Invoke($"Skipping work {workId}: {e.Message}");
                return 0;
            }
        }
        finally
        {
            rec.LastCheckedAt = DateTimeOffset.Now;
        }
    }

    private async Task<int> CheckFollowedWorkAsync(Work work, CancellationToken ct)
    {
        try
        {
            var meta = await _client.FetchWorkMetadataAsync(work.Ao3Id, ct).ConfigureAwait(false);
            var notifyCount = 0;
            if (work.LastSeenChapterCount is { } lastSeen && meta.ChapterCount > lastSeen)
            {
                await PostAsync(NewChapterContent(work.Title, lastSeen, meta.ChapterCount, work.Ao3Id)).ConfigureAwait(false);
                notifyCount = 1;
            }
            work.LastSeenChapterCount = meta.ChapterCount;
            return notifyCount;
        }
        catch (Exception e)
        {
            FailedChecks++;
            LibraryHooks.Log?.Invoke($"Skipping followed work {work.Ao3Id}: {e.Message}");
            return 0;
        }
        finally
        {
            work.LastCheckedAt = DateTimeOffset.Now;
        }
    }

    private async Task<int> CheckFollowedAuthorAsync(FollowedAuthor author, CancellationToken ct)
    {
        try
        {
            var result = await _client.FetchAuthorWorksAsync(author.Username, 1, ct).ConfigureAwait(false);
            // Signed in but served the guest page: the session expired. The
            // public works still alert; restricted ones aren't in the baseline
            // yet, so they alert once a signed-in poll sees them.
            if (Username is not null && result.ServedAsGuest) SessionExpired = true;
            var latestIds = result.Works.Select(w => w.Id);
            var known = author.KnownWorkIds.ToHashSet();
            var notifyCount = 0;
            var newWorks = NewlyPostedWorks(result.Works, known);
            if (newWorks.Count > 0)
            {
                await PostAsync(NewWorkContent(author.Username, author.DisplayName, newWorks)).ConfigureAwait(false);
                notifyCount = newWorks.Count;
            }
            known.UnionWith(latestIds);
            author.KnownWorkIds = known.ToList();
            return notifyCount;
        }
        catch (Exception e)
        {
            FailedChecks++;
            LibraryHooks.Log?.Invoke($"Skipping author {author.Username}: {e.Message}");
            return 0;
        }
        finally
        {
            author.LastCheckedAt = DateTimeOffset.Now;
        }
    }

    /// <summary>Run a saved search with alerts on, newest posted first (one
    /// throttled request), and alert for works posted since its baseline. The
    /// first check after alerts go on only takes the baseline. Only a check that
    /// reads the results counts as one (<see cref="SavedSearch.AlertsLastCheckedAt"/>):
    /// one that's cut off, fails, comes back stale or gets a guest page leaves the
    /// baseline and the last check alone.</summary>
    public async Task<int> CheckSavedSearchAsync(SavedSearch search, CancellationToken ct = default)
    {
        var checkedBefore = search.AlertsLastCheckedAt;
        var prompt = search.Prompt;
        var changedAt = search.AlertsChangedAt;
        var filters = SavedSearchAlerts.Filters(prompt);
        search.AlertsAttemptedAt = DateTimeOffset.Now;
        AO3SearchResults result;
        try
        {
            result = await _client.SearchAsync(filters, 1, ct).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            if (e is not OperationCanceledException) FailedChecks++;
            LibraryHooks.Log?.Invoke($"Skipping saved search {search.Name}: {e.Message}");
            return 0;
        }
        // An AO3 search can take half a minute: if the search was deleted, edited
        // or its alerts switched (off, or off and on again) meanwhile, these
        // results are stale.
        if (!ReferenceEquals(_store.GetSavedSearch(search.Name), search) || !search.AlertsEnabled
            || search.Prompt != prompt || search.AlertsChangedAt != changedAt) return 0;
        // Signed in but served the guest page: the session expired, and the
        // results leave out restricted works. Recording them would mark the
        // public ones seen ahead of the restricted ones, which then never alert.
        if (Username is not null && result.ServedAsGuest)
        {
            SessionExpired = true;
            return 0;
        }
        var fresh = SavedSearchAlerts.NewMatches(result.Works, search.AlertKnownWorkIds.ToHashSet(),
                                                 search.AlertsBaselineAt is not null, checkedBefore);
        search.AlertsBaselineAt ??= DateTimeOffset.Now;
        search.AlertKnownWorkIds = SavedSearchAlerts.Baseline(search.AlertKnownWorkIds, result.Works.Select(w => w.Id));
        search.AlertsLastCheckedAt = DateTimeOffset.Now;
        if (fresh.Count == 0) return 0;
        // The same rules as the results list: hidden works, blocked tags and
        // authors (except ones the search names) and, when that setting is on,
        // Mature and Explicit works never alert.
        var shown = ContentFilter.Apply(fresh, HiddenWorkStore.Ids(_store),
            KeyValueStores.Default.GetBool(ContentControl.FilterMatureKey, true),
            Blocklist.From(_store).Lifting(filters));
        if (shown.Count == 0) return 0;
        var alreadyNew = search.AlertNewWorkIds.ToHashSet();
        search.AlertNewWorkIds = search.AlertNewWorkIds.Concat(shown.Select(w => w.Id).Where(id => !alreadyNew.Contains(id))).ToList();
        await PostAsync(SavedSearchContent(search.Name, prompt, shown)).ConfigureAwait(false);
        return shown.Count;
    }

    // MARK: - Record fetches

    private IReadOnlyList<SubscriptionRecord> WorkSubscriptionRecords() => _store.Where<SubscriptionRecord>(s => s.Kind == "work");

    private IReadOnlyList<Work> FollowedWorks() => _store.FollowedWorks();

    private IReadOnlyList<FollowedAuthor> FollowedAuthors() => _store.Where<FollowedAuthor>(a => a.Username.Length > 0);

    /// <summary>At most <see cref="SavedSearchAlerts.MaxAlertingSearches"/>, the most
    /// recently switched on first: a backup merge can bring in more than this PC
    /// lets the reader switch on, and each one costs an AO3 search per poll.</summary>
    private IReadOnlyList<SavedSearch> AlertingSearches() => _store.Where<SavedSearch>(s => s.AlertsEnabled)
        .OrderByDescending(s => s.AlertsChangedAt ?? DateTimeOffset.MinValue)
        .Take(SavedSearchAlerts.MaxAlertingSearches).ToList();

    private async Task PostAsync(LocalNotification notification)
    {
        if (_notifier is null) return;
        try
        {
            await _notifier.PostAsync(notification).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Debug.WriteLine($"Couldn't post a notification: {e.Message}");
        }
    }

    /// <summary>The works on an author's first page that are newly posted since
    /// the baseline <paramref name="known"/> was taken. AO3 lists an author's
    /// works by last update, so an older work we never saw (it was past page 1
    /// at follow time) shows up unknown when it gets a chapter; alerting for it
    /// as a new work opened that old story. An unknown work is new when it's
    /// newer than every known one (AO3 work ids only grow) or has a single
    /// chapter, which an update can't leave it with — that still catches a new
    /// work with a lower id: a gift revealed from an anonymous collection, a
    /// long-held draft, or a restricted work a guest page left out. Empty with
    /// no baseline yet — a freshly-followed author is seeded at follow time, but
    /// a first poll must never alert for the whole back catalogue.</summary>
    internal static IReadOnlyList<AO3WorkSummary> NewlyPostedWorks(IReadOnlyList<AO3WorkSummary> works, IReadOnlySet<int> known)
    {
        if (known.Count == 0) return [];
        var newestKnown = known.Max();
        return works.Where(w => !known.Contains(w.Id) && (w.Id > newestKnown || w.ChapterCount == 1)).ToList();
    }

    // MARK: - Notification content

    /// <summary>A followed author's new work(s). One work opens that work;
    /// several open the author's page.</summary>
    public static LocalNotification NewWorkContent(string authorUsername, string authorName, IReadOnlyList<AO3WorkSummary> newWorks)
    {
        var newestId = newWorks.FirstOrDefault()?.Id ?? 0;
        var identifier = $"author-{authorName}-newwork-{newestId}";
        if (newWorks.Count == 1)
        {
            var work = newWorks[0];
            return new LocalNotification(identifier, authorName, $"New work: {work.Title}", RoutePayloads.NewWork(work.Id));
        }
        return new LocalNotification(identifier, authorName, $"{newWorks.Count} new works posted",
                                     RoutePayloads.NewWorks(authorUsername, authorName));
    }

    /// <summary>New fics for a saved search. One opens that work; several open
    /// the search's results, newest posted first.</summary>
    public static LocalNotification SavedSearchContent(string searchName, string prompt, IReadOnlyList<AO3WorkSummary> newWorks)
    {
        var identifier = $"search-{searchName}-new-{(newWorks.Count > 0 ? newWorks.Max(w => w.Id) : 0)}";
        if (newWorks.Count == 1)
        {
            var work = newWorks[0];
            return new LocalNotification(identifier, searchName, $"New fic: {work.Title}", RoutePayloads.SearchMatch(work.Id));
        }
        return new LocalNotification(identifier, searchName, $"{newWorks.Count} new fics match this search",
                                     RoutePayloads.SavedSearch(searchName, prompt));
    }

    /// <summary>New chapters on a followed or subscribed work; opens the work.</summary>
    public static LocalNotification NewChapterContent(string title, int oldCount, int newCount, int workId)
    {
        var added = newCount - oldCount;
        var body = added == 1
            ? $"1 new chapter posted ({newCount} total)"
            : $"{added} new chapters posted ({newCount} total)";
        return new LocalNotification($"work-{workId}-update-{newCount}", title, body, RoutePayloads.NewChapters(workId));
    }
}

/// <summary>Notification permission. On Windows the app installs
/// <see cref="Request"/> (toast notifications rarely need a prompt, but the
/// hook keeps the follow flow the same).</summary>
public static class NotificationsAuthorization
{
    /// <summary>Asks for permission; returns whether notifications are allowed.</summary>
    public static Func<Task<bool>>? Request { get; set; }

    /// <summary>Demo and test runs set this so screenshot automation and tests
    /// never trip a permission prompt.</summary>
    public static bool IsSuppressed { get; set; }

    /// <summary>Fire-and-forget request for the local-follow flow. Follows are
    /// the headline logged-out feature and their payoff is the poller's
    /// notifications, so ask the moment the user first follows something —
    /// never gated on an AO3 login.</summary>
    public static void RequestAfterFollow()
    {
        if (IsSuppressed || Request is not { } request) return;
        _ = Task.Run(async () =>
        {
            try { await request().ConfigureAwait(false); }
            catch (Exception e) { Debug.WriteLine($"Notification permission request failed: {e.Message}"); }
        });
    }
}

/// <summary>The periodic background poll (Swift <c>BackgroundRefresh</c>). The
/// app schedules it with a Windows background task / timer.</summary>
public static class BackgroundRefresh
{
    public const string Identifier = "io.github.yennster.fanficly.subscriptionRefresh";

    /// <summary>How long after one run the next should be scheduled.</summary>
    public static readonly TimeSpan DefaultInterval = TimeSpan.FromHours(4);

    /// <summary>Runs one full poll. Runs even when logged out
    /// (<paramref name="username"/> null): locally-followed works are still polled.</summary>
    public static async Task<int> RunPollAsync(IAO3Client client, LibraryStore store, string? username,
                                               ILocalNotifier? notifier, CancellationToken ct = default)
    {
        var poller = new SubscriptionPoller(client, store, username, notifier);
        var notified = await poller.RunFullPollAsync(ct).ConfigureAwait(false);
        Debug.WriteLine($"Background poll posted {notified} notifications");
        return notified;
    }
}
