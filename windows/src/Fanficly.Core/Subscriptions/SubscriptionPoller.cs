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
}

/// <summary>Checks AO3 for news on everything the user follows: account
/// subscriptions (when logged in), locally-followed works (new chapters) and
/// locally-followed authors (new works), posting a local notification for each.</summary>
public sealed class SubscriptionPoller
{
    private readonly IAO3Client _client;
    private readonly LibraryStore _store;
    private readonly ILocalNotifier? _notifier;
    private readonly IKeyValueStore? _syncStamps;

    /// <summary>Route payload builder for notifications; the app replaces it with
    /// one backed by <c>NotificationRoute</c>.</summary>
    public static INotificationRoutePayloads RoutePayloads { get; set; } = new DefaultNotificationRoutePayloads();

    /// <param name="username">AO3 username for syncing account subscriptions;
    /// null when logged out (locally-followed works are still polled).</param>
    /// <param name="syncStamps">Where the last list sync is stamped; defaults to
    /// the widgets' shared store, which the app and the background task both
    /// write, else <see cref="KeyValueStores.Default"/>.</param>
    public SubscriptionPoller(IAO3Client client, LibraryStore store, string? username, ILocalNotifier? notifier = null,
                              IKeyValueStore? syncStamps = null)
    {
        _client = client;
        _store = store;
        Username = username;
        _notifier = notifier;
        _syncStamps = syncStamps;
    }

    public string? Username { get; }

    /// <summary>Where the poller reads and changes library records (the UI
    /// thread in the app); the AO3 requests and notifications run off it, so
    /// a poll never changes a record while a screen is using it (#139).</summary>
    public RecordsThread? Records { get; init; } = RecordsThread.Main;

    private Task<T> OnRecords<T>(Func<T> body) => RecordsThread.RunAsync(Records, body);

    private Task OnRecords(Action body) => RecordsThread.RunAsync(Records, body);

    /// <summary>How often <see cref="RunFullPollAsync"/> re-reads the subscriptions
    /// list. The walk costs one throttled request per 20 subscriptions (up to 50),
    /// which on a big list is the background task's whole ~30 s, and the list
    /// rarely changes; the Subscriptions tab syncs it whenever it refreshes (#150).</summary>
    public static readonly TimeSpan ListSyncInterval = TimeSpan.FromHours(24);

    private IKeyValueStore SyncStamps => _syncStamps ?? AppGroupStore.Shared ?? KeyValueStores.Default;

    private string? ListSyncKey => Username is { } u ? $"subscriptions.listSyncedAt.{u}" : null;

    /// <summary>Whether <see cref="RunFullPollAsync"/> should re-read the
    /// subscriptions list: signed in, and no sync (or attempt) for this account
    /// in <see cref="ListSyncInterval"/>.</summary>
    public bool ListSyncIsDue(DateTimeOffset? now = null)
    {
        if (ListSyncKey is not { } key) return false;
        if (SyncStamps.GetDate(key) is not { } last) return true;
        var at = now ?? DateTimeOffset.Now;
        // A clock set back leaves a future stamp; don't let it block syncs.
        return last > at || at - last >= ListSyncInterval;
    }

    private void StampListSync()
    {
        if (ListSyncKey is { } key) SyncStamps.SetDate(key, DateTimeOffset.Now);
    }

    /// <summary>Mirrors the account's AO3 subscription list into
    /// <see cref="SubscriptionRecord"/>s. Fails closed on pruning: an empty fetch
    /// with records on hand is far more likely a stale session or markup drift
    /// than a mass unsubscribe, and a wrong delete also destroys the
    /// LastSeenChapterCount baselines new-chapter alerts compare against.</summary>
    public async Task<IReadOnlyList<AO3Subscription>> SyncSubscriptionListAsync(CancellationToken ct = default)
    {
        if (Username is not { } username) return [];
        var list = await _client.FetchSubscriptionsAsync(username, ct).ConfigureAwait(false);
        StampListSync();
        await OnRecords(() => MergeSubscriptionList(list)).ConfigureAwait(false);
        return list.Subscriptions;
    }

    private void MergeSubscriptionList(AO3SubscriptionList list)
    {
        var fresh = list.Subscriptions;
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
        // A list cut off at the page ceiling is missing real subscriptions, so
        // it prunes nothing either.
        if (fresh.Count > 0 && list.IsComplete)
            foreach (var rec in existing)
                if (!freshKeys.Contains(rec.Key)) _store.Delete(rec);
        if (!list.IsComplete)
            LibraryHooks.Log?.Invoke("Subscriptions list ran past the page ceiling; kept the records it didn't reach");
        _store.TrySave();
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
        foreach (var rec in await OnRecords(WorkSubscriptionRecords).ConfigureAwait(false))
            notifyCount += await CheckWorkSubscriptionAsync(rec, ct).ConfigureAwait(false);
        await OnRecords(() => _store.TrySave()).ConfigureAwait(false);
        return notifyCount;
    }

    /// <summary>Poll locally-followed works (no AO3 login required) for new chapters.</summary>
    public async Task<int> CheckFollowedWorksAsync(CancellationToken ct = default)
    {
        var notifyCount = 0;
        foreach (var work in await OnRecords(FollowedWorks).ConfigureAwait(false))
            notifyCount += await CheckFollowedWorkAsync(work, ct).ConfigureAwait(false);
        await OnRecords(() => _store.TrySave()).ConfigureAwait(false);
        return notifyCount;
    }

    /// <summary>Check AO3 work subscriptions (when logged in) and followed works for
    /// new chapters together: one request per work id, so a work that's both
    /// subscribed and followed is fetched once and notifies once (#148).</summary>
    public async Task<int> CheckWorksForNewChaptersAsync(CancellationToken ct = default)
    {
        var notifyCount = 0;
        var targets = await OnRecords(() => WorkTargets(Username is not null ? WorkSubscriptionRecords() : [], FollowedWorks()))
            .ConfigureAwait(false);
        foreach (var t in targets)
        {
            if (ct.IsCancellationRequested) break;
            notifyCount += await CheckWorkAsync(t.Id, t.Subscription, t.Followed, ct).ConfigureAwait(false);
        }
        await OnRecords(() => _store.TrySave()).ConfigureAwait(false);
        return notifyCount;
    }

    /// <summary>Poll locally-followed authors (no AO3 login required) for newly
    /// published works, notifying once per new work.</summary>
    public async Task<int> CheckFollowedAuthorsAsync(CancellationToken ct = default)
    {
        var notifyCount = 0;
        foreach (var author in await OnRecords(FollowedAuthors).ConfigureAwait(false))
            notifyCount += await CheckFollowedAuthorAsync(author, ct).ConfigureAwait(false);
        await OnRecords(() => _store.TrySave()).ConfigureAwait(false);
        return notifyCount;
    }

    /// <summary>The full background poll. Interleaves all three record kinds
    /// oldest-check-first rather than a fixed subs → works → authors order: every
    /// check costs one throttled (1 req/s) request and a background run gets
    /// limited time, so a fixed order would permanently starve the last
    /// category; oldest-first means whatever was cut off last time runs first
    /// this time. Saves after every record and stops cleanly on cancellation.
    /// Returns the number of notifications posted.</summary>
    public async Task<int> RunFullPollAsync(CancellationToken ct = default)
    {
        // At most once a day, so the run goes to the checks below (#150).
        // Stamped before the walk: a list too long to finish in one background
        // run would otherwise be retried, and cut off, every time.
        if (ListSyncIsDue())
        {
            StampListSync();
            try
            {
                await SyncSubscriptionListAsync(ct).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                LibraryHooks.Log?.Invoke($"Subscriptions list fetch failed: {e.Message}");
            }
        }

        var ordered = await OnRecords(() =>
        {
            var targets = new List<(DateTimeOffset? LastCheckedAt, Func<Task<int>> Check)>();
            // One target per work id: a work that's both AO3-subscribed and followed
            // is fetched once (#148), queued by the staler of its two records.
            targets.AddRange(WorkTargets(Username is not null ? WorkSubscriptionRecords() : [], FollowedWorks())
                .Select(t => (Stalest(t.Subscription, t.Followed), (Func<Task<int>>)(() => CheckWorkAsync(t.Id, t.Subscription, t.Followed, ct)))));
            targets.AddRange(FollowedAuthors().Select(a => (a.LastCheckedAt, (Func<Task<int>>)(() => CheckFollowedAuthorAsync(a, ct)))));
            return targets.OrderBy(t => t.LastCheckedAt ?? DateTimeOffset.MinValue).ToList();
        }).ConfigureAwait(false);

        var total = 0;
        foreach (var target in ordered)
        {
            // The scheduler cancels us at expiry — stop cleanly and keep the
            // progress saved so far.
            if (ct.IsCancellationRequested) break;
            total += await target.Check().ConfigureAwait(false);
            // Save after every record so an expiring run keeps its
            // LastCheckedAt stamps — they drive the rotation.
            await OnRecords(() => _store.TrySave()).ConfigureAwait(false);
        }
        await OnRecords(() => LibraryHooks.UpdateWidgetData?.Invoke(_store)).ConfigureAwait(false);
        return total;
    }

    // MARK: - Per-record checks

    /// <summary>The work targets of a poll, one per AO3 work id: a subscription
    /// and a follow of the same work share a target, so the work is fetched once.</summary>
    private static List<(int Id, SubscriptionRecord? Subscription, Work? Followed)> WorkTargets(
        IReadOnlyList<SubscriptionRecord> subscriptions, IReadOnlyList<Work> followed)
    {
        var ids = new List<int>();
        var recs = new Dictionary<int, SubscriptionRecord>();
        var works = new Dictionary<int, Work>();
        foreach (var rec in subscriptions)
        {
            if (WorkId(rec) is { } id)
            {
                if (recs.TryAdd(id, rec)) ids.Add(id);
            }
            // A key that names no work can't be checked; stamp it like a failed check.
            else rec.LastCheckedAt = DateTimeOffset.Now;
        }
        foreach (var work in followed)
            if (works.TryAdd(work.Ao3Id, work) && !recs.ContainsKey(work.Ao3Id)) ids.Add(work.Ao3Id);
        return ids.Select(id => (id, recs.GetValueOrDefault(id), works.GetValueOrDefault(id))).ToList();
    }

    /// <summary>The staler of a target's records; a record never checked goes first.</summary>
    private static DateTimeOffset? Stalest(SubscriptionRecord? rec, Work? work) =>
        new[] { rec is null ? (DateTimeOffset?)null : rec.LastCheckedAt ?? DateTimeOffset.MinValue,
                work is null ? null : work.LastCheckedAt ?? DateTimeOffset.MinValue }.Min();

    /// <summary>The work id in a work subscription's key (<c>work:&lt;id&gt;</c>).</summary>
    private static int? WorkId(SubscriptionRecord rec)
    {
        var parts = rec.Key.Split(':');
        return parts.Length == 2 && int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var id) ? id : null;
    }

    /// <summary>Check one AO3 work subscription for a new chapter (one throttled
    /// request). Returns the number of notifications posted.</summary>
    private async Task<int> CheckWorkSubscriptionAsync(SubscriptionRecord rec, CancellationToken ct)
    {
        // A record's key and id never change, so they're read here.
        if (WorkId(rec) is not { } workId)
        {
            await OnRecords(() => rec.LastCheckedAt = DateTimeOffset.Now).ConfigureAwait(false);
            return 0;
        }
        return await CheckWorkAsync(workId, rec, null, ct).ConfigureAwait(false);
    }

    private Task<int> CheckFollowedWorkAsync(Work work, CancellationToken ct) => CheckWorkAsync(work.Ao3Id, null, work, ct);

    /// <summary>Check a work for new chapters with one throttled request of its
    /// light page, for its subscription, its follow or both, and post at most one
    /// notification. The attempt is stamped whatever happens: a permanently-failing
    /// record (deleted work, parse drift) must not stay "oldest" forever and hog
    /// the queue head.</summary>
    private async Task<int> CheckWorkAsync(int workId, SubscriptionRecord? rec, Work? work, CancellationToken ct)
    {
        try
        {
            var meta = await _client.FetchWorkMetadataAsync(workId, ct).ConfigureAwait(false);
            var (lastSeen, title) = await OnRecords(() =>
            {
                // Against the higher baseline: chapters either record already counted
                // were notified (or seen) then, and mustn't notify again.
                var seen = new[] { rec?.LastSeenChapterCount, work?.LastSeenChapterCount }.Max();
                if (rec is not null) rec.LastSeenChapterCount = meta.ChapterCount;
                if (work is not null) work.LastSeenChapterCount = meta.ChapterCount;
                return (seen, work?.Title ?? rec?.DisplayName ?? "");
            }).ConfigureAwait(false);
            if (lastSeen is not { } seenCount || meta.ChapterCount <= seenCount) return 0;
            await PostAsync(NewChapterContent(title, seenCount, meta.ChapterCount, workId)).ConfigureAwait(false);
            return 1;
        }
        catch (Exception e)
        {
            FailedChecks++;
            LibraryHooks.Log?.Invoke($"Skipping work {workId}: {e.Message}");
            return 0;
        }
        finally
        {
            await OnRecords(() =>
            {
                if (rec is not null) rec.LastCheckedAt = DateTimeOffset.Now;
                if (work is not null) work.LastCheckedAt = DateTimeOffset.Now;
            }).ConfigureAwait(false);
        }
    }

    private async Task<int> CheckFollowedAuthorAsync(FollowedAuthor author, CancellationToken ct)
    {
        // A followed author's username never changes, so it's read here.
        var username = author.Username;
        try
        {
            var result = await _client.FetchAuthorWorksAsync(username, 1, ct).ConfigureAwait(false);
            // Signed in but served the guest page: the session expired. The
            // public works still alert; restricted ones aren't in the baseline
            // yet, so they alert once a signed-in poll sees them.
            if (Username is not null && result.ServedAsGuest) SessionExpired = true;
            var latestIds = result.Works.Select(w => w.Id);
            var (known, followedAt, displayName) = await OnRecords(() =>
                (author.KnownWorkIds.ToHashSet(), author.FollowedAt, author.DisplayName)).ConfigureAwait(false);
            var newWorks = NewlyPostedWorks(result.Works, known);
            IReadOnlySet<int> undated = new HashSet<int>();
            if (known.Count == 0)
                (newWorks, undated) = await WorksPostedSinceFollowAsync(result.Works, followedAt, ct).ConfigureAwait(false);
            known.UnionWith(latestIds);
            known.ExceptWith(undated);
            await OnRecords(() => author.KnownWorkIds = known.ToList()).ConfigureAwait(false);
            if (newWorks.Count == 0) return 0;
            await PostAsync(NewWorkContent(username, displayName, newWorks)).ConfigureAwait(false);
            return newWorks.Count;
        }
        catch (Exception e)
        {
            FailedChecks++;
            LibraryHooks.Log?.Invoke($"Skipping author {username}: {e.Message}");
            return 0;
        }
        finally
        {
            await OnRecords(() => author.LastCheckedAt = DateTimeOffset.Now).ConfigureAwait(false);
        }
    }

    /// <summary>No baseline: Follow was tapped before the author's list loaded (or
    /// they had no public works yet), so nothing on page 1 is known. A work last
    /// updated well before the follow was already there. A later one may be new or
    /// an old work that got a chapter, so its work page's published date decides:
    /// one request for each. AO3 dates are days, shown to guests in UTC, so "later"
    /// starts the day before the follow day: a work posted just after a follow east
    /// of UTC can carry the previous date. The cost is at worst an alert for a work
    /// posted shortly before the follow.
    ///
    /// Works that couldn't be dated (an error page, or the poll was cancelled) come
    /// back in <c>Undated</c> and stay out of the baseline. Once the rest is the
    /// baseline, the next poll judges them by the id rule in
    /// <see cref="NewlyPostedWorks"/>; with nothing dated, the next poll dates them
    /// again.</summary>
    private async Task<(IReadOnlyList<AO3WorkSummary> Posted, IReadOnlySet<int> Undated)> WorksPostedSinceFollowAsync(
        IReadOnlyList<AO3WorkSummary> works, DateTimeOffset followedAt, CancellationToken ct)
    {
        var since = followedAt.ToLocalTime().Date.AddDays(-1);
        var posted = new List<AO3WorkSummary>();
        var undated = new HashSet<int>();
        foreach (var work in works)
        {
            if (work.UpdatedAt is not { } updatedAt || updatedAt.ToLocalTime().Date < since) continue;
            if (ct.IsCancellationRequested)
            {
                undated.Add(work.Id);
                continue;
            }
            try
            {
                var meta = await _client.FetchWorkMetadataAsync(work.Id, ct).ConfigureAwait(false);
                if (meta.PublishedAt is not { } publishedAt) undated.Add(work.Id);
                else if (publishedAt.ToLocalTime().Date >= since) posted.Add(work);
            }
            catch (Exception e)
            {
                if (e is not OperationCanceledException) LibraryHooks.Log?.Invoke($"Couldn't date work {work.Id}: {e.Message}");
                undated.Add(work.Id);
            }
        }
        return (posted, undated);
    }

    // MARK: - Record fetches

    private IReadOnlyList<SubscriptionRecord> WorkSubscriptionRecords() => _store.Where<SubscriptionRecord>(s => s.Kind == "work");

    private IReadOnlyList<Work> FollowedWorks() => _store.FollowedWorks();

    private IReadOnlyList<FollowedAuthor> FollowedAuthors() => _store.Where<FollowedAuthor>(a => a.Username.Length > 0);

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
    /// no baseline: the poller dates those works instead
    /// (<see cref="WorksPostedSinceFollowAsync"/>), so a first poll never alerts
    /// for the whole back catalogue.</summary>
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
