using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>The background poll: one queue of every followed thing, oldest
/// check first, a save after each record, a clean stop on cancellation, and
/// the right notification for each kind of news.</summary>
public sealed class SubscriptionPollerTests
{
    private static readonly DateTimeOffset T0 = DateTimeOffset.FromUnixTimeSeconds(1_780_000_000);

    private static AO3WorkSummary Summary(int id, string title = "") => new() { Id = id, Title = title };

    [Fact]
    public async Task FullPoll_ChecksEveryKindOldestFirst()
    {
        using var store = LibraryStore.OpenInMemory();
        store.Insert(new SubscriptionRecord("work:10", "work", "Sub") { LastSeenChapterCount = 2, LastCheckedAt = T0.AddHours(-1) });
        store.Insert(new SubscriptionRecord("series:9", "series", "Saga")); // not a work: never checked
        store.Insert(new Work(20, "Followed", "A") { IsFollowed = true, LastSeenChapterCount = 4, LastCheckedAt = T0.AddHours(-3) });
        store.Insert(new Work(21, "Saved only", "A"));                       // not followed: never checked
        store.Insert(new FollowedAuthor("never-checked", "Never", knownWorkIds: [1]));
        store.Save();

        var client = new PollerFakeClient
        {
            SubscriptionsResponse = [new AO3Subscription(AO3SubscriptionKind.Work, "10", "Sub", "x"),
                                     new AO3Subscription(AO3SubscriptionKind.Series, "9", "Saga", null)],
        };
        client.ChapterCounts[10] = 3;
        client.ChapterCounts[20] = 6;
        client.AuthorWorks["never-checked"] = [Summary(1), Summary(2, "Brand New")];
        var notifier = new RecordingNotifier();

        var posted = await new SubscriptionPoller(client, store, "reader", notifier).RunFullPollAsync();

        // Never checked first, then the oldest stamp.
        Assert.Equal(["author:never-checked", "work:20", "work:10"], client.Requests);
        Assert.Equal(3, posted);
        Assert.Equal(3, notifier.Posted.Count);

        var authorNote = notifier.Posted[0];
        Assert.Equal("Never", authorNote.Title);
        Assert.Equal("New work: Brand New", authorNote.Body);
        Assert.Equal("author-Never-newwork-2", authorNote.Identifier);
        Assert.Equal("newWork", authorNote.Payload["kind"]);
        Assert.Equal("2", authorNote.Payload["workId"]);

        var followedNote = notifier.Posted[1];
        Assert.Equal(("Followed", "2 new chapters posted (6 total)", "work-20-update-6"),
                     (followedNote.Title, followedNote.Body, followedNote.Identifier));
        Assert.Equal("newChapters", followedNote.Payload["kind"]);
        Assert.Equal("1 new chapter posted (3 total)", notifier.Posted[2].Body);

        // Baselines advanced and every record stamped — and saved.
        Assert.Equal(6, store.GetWork(20)!.LastSeenChapterCount);
        Assert.Equal(3, store.GetSubscription("work:10")!.LastSeenChapterCount);
        Assert.Equal([1, 2], store.GetFollowedAuthor("never-checked")!.KnownWorkIds.Order());
        Assert.NotNull(store.GetFollowedAuthor("never-checked")!.LastCheckedAt);
        Assert.Null(store.GetWork(21)!.LastCheckedAt);
        Assert.False(store.HasChanges);
    }

    [Fact]
    public async Task FullPoll_FetchesAWorkThatsSubscribedAndFollowedOnce()
    {
        // #148: one request per work id per run, one notification, and both
        // records take the new baseline and stamp.
        using var store = LibraryStore.OpenInMemory();
        store.Insert(new SubscriptionRecord("work:10", "work", "Sub name") { LastSeenChapterCount = 2, LastCheckedAt = T0 });
        store.Insert(new Work(10, "Both", "A") { IsFollowed = true, LastSeenChapterCount = 4, LastCheckedAt = T0.AddHours(-2) });
        store.Insert(new Work(20, "Followed", "A") { IsFollowed = true, LastSeenChapterCount = 1, LastCheckedAt = T0.AddHours(-1) });
        store.Save();
        var client = new PollerFakeClient
        {
            SubscriptionsResponse = [new AO3Subscription(AO3SubscriptionKind.Work, "10", "Sub name", "x")],
        };
        client.ChapterCounts[10] = 5;
        client.ChapterCounts[20] = 1;
        var notifier = new RecordingNotifier();

        var posted = await new SubscriptionPoller(client, store, "reader", notifier).RunFullPollAsync();

        // Work 10 is queued by its staler record, the follow.
        Assert.Equal(["work:10", "work:20"], client.Requests);
        Assert.Equal(1, posted);
        var note = Assert.Single(notifier.Posted);
        // Against the higher baseline: the follow had already seen chapter 4.
        Assert.Equal(("Both", "1 new chapter posted (5 total)"), (note.Title, note.Body));
        Assert.Equal(5, store.GetSubscription("work:10")!.LastSeenChapterCount);
        Assert.Equal(5, store.GetWork(10)!.LastSeenChapterCount);
        Assert.True(store.GetSubscription("work:10")!.LastCheckedAt > T0);
        Assert.True(store.GetWork(10)!.LastCheckedAt > T0);
    }

    [Fact]
    public async Task FullPoll_LoggedOutSkipsAccountSubscriptions()
    {
        using var store = LibraryStore.OpenInMemory();
        store.Insert(new SubscriptionRecord("work:10", "work", "Sub") { LastSeenChapterCount = 2 });
        store.Insert(new Work(20, "Followed", "A") { IsFollowed = true, LastSeenChapterCount = 4 });
        store.Save();
        var client = new PollerFakeClient();
        client.ChapterCounts[10] = 9;
        client.ChapterCounts[20] = 4;

        var posted = await new SubscriptionPoller(client, store, username: null, new RecordingNotifier()).RunFullPollAsync();

        Assert.Equal(["work:20"], client.Requests);
        Assert.Equal(0, posted); // no new chapters on the followed work
    }

    [Fact]
    public async Task FailedChecksAreStillStampedSoTheyDontHogTheQueue()
    {
        using var store = LibraryStore.OpenInMemory();
        store.Insert(new Work(404, "Deleted on AO3", "A") { IsFollowed = true, LastSeenChapterCount = 1 });
        store.Insert(new SubscriptionRecord("work:bad", "work", "Malformed key"));
        store.Save();
        var client = new PollerFakeClient { SubscriptionsError = AO3Exception.Unauthorized() };

        Assert.Equal(0, await new SubscriptionPoller(client, store, "reader").RunFullPollAsync());
        Assert.NotNull(store.GetWork(404)!.LastCheckedAt);
        Assert.NotNull(store.GetSubscription("work:bad")!.LastCheckedAt);
        Assert.Equal(1, store.GetWork(404)!.LastSeenChapterCount);
        // A failed subscription-list fetch never prunes.
        Assert.Equal(1, store.Count<SubscriptionRecord>());
    }

    [Fact]
    public async Task FailedChecksAreCountedSoARefreshCanSaySo()
    {
        using var store = LibraryStore.OpenInMemory();
        store.Insert(new Work(404, "Unreachable", "A") { IsFollowed = true, LastSeenChapterCount = 1 });
        store.Insert(new Work(20, "Fine", "A") { IsFollowed = true, LastSeenChapterCount = 4 });
        store.Save();
        var client = new PollerFakeClient();
        client.ChapterCounts[20] = 4;
        var poller = new SubscriptionPoller(client, store, null);

        Assert.Equal(0, await poller.CheckFollowedWorksAsync());
        Assert.Equal(1, poller.FailedChecks);
    }

    [Fact]
    public async Task FirstPollOfAnUnseededAuthorDoesNotAlertForTheBackCatalogue()
    {
        using var store = LibraryStore.OpenInMemory();
        store.Insert(new FollowedAuthor("prolific", "Prolific"));
        store.Save();
        var client = new PollerFakeClient();
        client.AuthorWorks["prolific"] = [Summary(1), Summary(2), Summary(3)];
        var notifier = new RecordingNotifier();
        var poller = new SubscriptionPoller(client, store, null, notifier);

        Assert.Equal(0, await poller.CheckFollowedAuthorsAsync());
        Assert.Empty(notifier.Posted);
        Assert.Equal([1, 2, 3], store.GetFollowedAuthor("prolific")!.KnownWorkIds.Order());

        // Two new works at once → one notification that opens the author.
        client.AuthorWorks["prolific"] = [Summary(5, "Five"), Summary(4, "Four"), Summary(1)];
        Assert.Equal(2, await poller.CheckFollowedAuthorsAsync());
        var note = Assert.Single(notifier.Posted);
        Assert.Equal("2 new works posted", note.Body);
        Assert.Equal("newWorks", note.Payload["kind"]);
        Assert.Equal("prolific", note.Payload["authorUsername"]);
        Assert.Equal("Prolific", note.Payload["authorName"]);
    }

    /// <summary>AO3 lists an author's works by last update, so an old work that
    /// was never in the baseline (past page 1 at follow time) rises to the top
    /// when it gets a chapter. It isn't a new work: alerting for it opened that
    /// old story, or the author's page when a real new work came in with it.</summary>
    [Fact]
    public async Task AnUpdatedOlderWorkIsNotANewWork()
    {
        using var store = LibraryStore.OpenInMemory();
        store.Insert(new FollowedAuthor("prolific", "Prolific", knownWorkIds: [50, 60]));
        store.Save();
        var client = new PollerFakeClient();
        client.AuthorWorks["prolific"] = [Summary(70, "Brand New"), Summary(10, "Old, Just Updated") with { ChapterCount = 4 }, Summary(60), Summary(50)];
        var notifier = new RecordingNotifier();
        var poller = new SubscriptionPoller(client, store, null, notifier);

        Assert.Equal(1, await poller.CheckFollowedAuthorsAsync());
        var note = Assert.Single(notifier.Posted);
        Assert.Equal("New work: Brand New", note.Body);
        Assert.Equal("newWork", note.Payload["kind"]);
        Assert.Equal("70", note.Payload["workId"]);
        // The old work joins the baseline quietly.
        Assert.Equal([10, 50, 60, 70], store.GetFollowedAuthor("prolific")!.KnownWorkIds.Order());

        // Only an updated old work: no alert at all.
        client.AuthorWorks["prolific"] = [Summary(5, "Older Still") with { ChapterCount = 2 }, Summary(70), Summary(10)];
        Assert.Equal(0, await poller.CheckFollowedAuthorsAsync());
        Assert.Single(notifier.Posted);

        // A one-chapter work with a lower id (a gift revealed from an anonymous
        // collection, a long-held draft) is still a new work.
        client.AuthorWorks["prolific"] = [Summary(65, "Revealed Gift"), Summary(70), Summary(10)];
        Assert.Equal(1, await poller.CheckFollowedAuthorsAsync());
        Assert.Equal("New work: Revealed Gift", notifier.Posted[^1].Body);
    }

    /// <summary>Signed in, a guest page means the session expired (#131): the
    /// public works still alert, and the poller says so.</summary>
    [Fact]
    public async Task GuestAuthorPageWhileSignedInFlagsTheExpiredSession()
    {
        using var store = LibraryStore.OpenInMemory();
        store.Insert(new FollowedAuthor("locked", "Locked", knownWorkIds: [1]));
        store.Save();
        var client = new PollerFakeClient();
        client.AuthorWorks["locked"] = [Summary(1), Summary(2)];
        client.GuestAuthorPages.Add("locked");
        var notifier = new RecordingNotifier();
        var poller = new SubscriptionPoller(client, store, "reader", notifier);

        Assert.Equal(1, await poller.CheckFollowedAuthorsAsync());
        Assert.Single(notifier.Posted);
        Assert.True(poller.SessionExpired);
        Assert.Equal([1, 2], store.GetFollowedAuthor("locked")!.KnownWorkIds.Order());

        // Signed out, the guest page is all there is.
        var guest = new SubscriptionPoller(client, store, null, notifier);
        await guest.CheckFollowedAuthorsAsync();
        Assert.False(guest.SessionExpired);
    }

    [Fact]
    public async Task CancellationStopsAfterTheCurrentRecordAndKeepsItsStamp()
    {
        using var store = LibraryStore.OpenInMemory();
        for (var id = 1; id <= 3; id++)
            store.Insert(new Work(id, $"W{id}", "A") { IsFollowed = true, LastSeenChapterCount = 1, LastCheckedAt = T0.AddMinutes(id) });
        store.Save();
        using var cts = new CancellationTokenSource();
        var client = new PollerFakeClient { OnRequest = _ => cts.Cancel() };
        for (var id = 1; id <= 3; id++) client.ChapterCounts[id] = 1;

        await new SubscriptionPoller(client, store, null).RunFullPollAsync(cts.Token);

        Assert.Equal(["work:1"], client.Requests);
        Assert.NotEqual(T0.AddMinutes(1), store.GetWork(1)!.LastCheckedAt);
        Assert.Equal(T0.AddMinutes(2), store.GetWork(2)!.LastCheckedAt);
        Assert.False(store.HasChanges); // the checked record was saved
    }

    [Fact]
    public void NotificationContent()
    {
        var chapter = SubscriptionPoller.NewChapterContent("A Fic", oldCount: 3, newCount: 5, workId: 12345);
        Assert.Equal("A Fic", chapter.Title);
        Assert.Equal("2 new chapters posted (5 total)", chapter.Body);
        Assert.Equal("12345", chapter.Payload["workId"]);

        var single = SubscriptionPoller.NewWorkContent("someone", "Some Pseud", [Summary(67890, "Brand New")]);
        Assert.Equal("New work: Brand New", single.Body);
        Assert.Equal("newWork", single.Payload["kind"]);
        Assert.Equal("67890", single.Payload["workId"]);

        var several = SubscriptionPoller.NewWorkContent("someone", "Some Pseud", [Summary(1, "One"), Summary(2, "Two")]);
        Assert.Equal("Some Pseud", several.Title);
        Assert.Equal("2 new works posted", several.Body);
        Assert.Equal("someone", several.Payload["authorUsername"]);
    }

    [Fact]
    public async Task RestoreDownloadCenterDownloadsSequentiallyAndCountsFailures()
    {
        using var store = LibraryStore.OpenInMemory();
        foreach (var (id, title) in new[] { (987650001, "Beta"), (987650002, "alpha"), (987650003, "Gamma") })
        {
            var work = new Work(id, title, "A");
            store.Insert(work);
            new Chapter(work, 1, "Ch", "<p>x</p>");
        }
        store.Insert(new Work(987650004, "Metadata only", "A"));
        store.Save();

        var center = new RestoreDownloadCenter { FinishedBannerDuration = TimeSpan.Zero };
        var announcements = new List<string>();
        center.Announcement += announcements.Add;
        center.ProposeRedownload(store);
        Assert.Equal([987650002, 987650001, 987650003], center.ProposedIds!); // by title, case-insensitive

        var client = new PollerFakeClient();
        client.FailingDownloads.Add(987650001);
        await center.StartDownloads(client);

        Assert.Equal(["epub:987650002", "epub:987650001", "epub:987650003"], client.Requests);
        Assert.Null(center.ProposedIds);
        Assert.Null(center.Progress); // the finished banner cleared itself
        Assert.Equal("Downloads finished. 2 succeeded, 1 failed.", announcements[^1]);
    }

    [Fact]
    public async Task RestoreDownloadCenterCancelStopsTheRun()
    {
        using var store = LibraryStore.OpenInMemory();
        for (var id = 987660001; id <= 987660003; id++)
        {
            var work = new Work(id, $"W{id}", "A");
            store.Insert(work);
            new Chapter(work, 1, "Ch", "<p>x</p>");
        }
        store.Save();
        var center = new RestoreDownloadCenter();
        center.ProposeRedownload(store);
        var client = new PollerFakeClient();
        client.OnRequest = _ => center.Cancel();

        await center.StartDownloads(client);

        Assert.Single(client.Requests);
        Assert.Null(center.Progress);
        Assert.False(center.IsDownloading);
    }

    // MARK: - Folder Download All (RM-010)

    [Fact]
    public void FolderDownloadCandidatesSkipDownloadedKeepOrder()
    {
        var works = new[] { 3, 1, 2, 1 }.Select(id => new Work(id, $"W{id}", "A")).ToList();
        Assert.Equal([3, 1], RestoreDownloadCenter.FolderDownloadCandidates(works, id => id == 2));
        Assert.Empty(RestoreDownloadCenter.FolderDownloadCandidates(works, _ => true));
    }

    [Fact]
    public void DownloadProgressBookkeeping()
    {
        var tally = new RestoreDownloadCenter.DownloadProgress(0, 0, 3, false)
            .Recording(succeeded: true).Recording(succeeded: false).Recording(succeeded: true);
        Assert.Equal(new RestoreDownloadCenter.DownloadProgress(2, 1, 3, false), tally);
        Assert.Equal(new RestoreDownloadCenter.DownloadProgress(2, 1, 3, true), tally.Finishing());
    }

    [Fact]
    public async Task DownloadQueueSkipsFailures()
    {
        var downloaded = new List<int>();
        var reports = new List<RestoreDownloadCenter.DownloadProgress>();
        var result = await RestoreDownloadCenter.RunQueueAsync([1, 2, 3], (id, _) =>
        {
            if (id == 2) throw AO3Exception.Http(404);
            downloaded.Add(id);
            return Task.CompletedTask;
        }, reports.Add, CancellationToken.None);

        Assert.Equal([1, 3], downloaded);
        Assert.Equal(3, reports.Count);
        Assert.Equal(new RestoreDownloadCenter.DownloadProgress(2, 1, 3, true), result);
    }

    /// <summary>Cancelling mid-run stops before the next story and undoes
    /// nothing: the stories that finished stay downloaded.</summary>
    [Fact]
    public async Task DownloadQueueCancelKeepsFinished()
    {
        using var cts = new CancellationTokenSource();
        var downloaded = new List<int>();
        var reports = new List<RestoreDownloadCenter.DownloadProgress>();
        var result = await RestoreDownloadCenter.RunQueueAsync([1, 2, 3], (id, _) =>
        {
            downloaded.Add(id);
            if (id == 2) cts.Cancel();
            return Task.CompletedTask;
        }, reports.Add, cts.Token);

        Assert.Null(result);
        Assert.Equal([1, 2], downloaded);
        Assert.Equal([new RestoreDownloadCenter.DownloadProgress(1, 0, 3, false)], reports);
    }

    [Fact]
    public async Task FolderDownloadSavesTextWhenMissingThenEpub()
    {
        using var store = LibraryStore.OpenInMemory();
        var withText = new Work(987670001, "Saved text", "A");
        store.Insert(withText);
        new Chapter(withText, 1, "Ch", "<p>x</p>");
        store.Insert(new Work(987670002, "Metadata only", "A"));
        store.Save();

        var client = new PollerFakeClient();
        client.Works[987670002] = new AO3WorkPayload(
            new AO3WorkSummary { Id = 987670002, Title = "Metadata only", Author = "A", ChapterCount = 2 },
            [new AO3ChapterPayload(1, "One", "<p>1</p>"), new AO3ChapterPayload(2, "Two", "<p>2</p>")]);
        var center = new RestoreDownloadCenter { FinishedBannerDuration = TimeSpan.Zero };
        await center.StartFolderDownload(client, store, [987670001, 987670002]);

        // Stored text isn't fetched again; the metadata-only work gets its chapters first.
        Assert.Equal(["epub:987670001", "fetch:987670002", "epub:987670002"], client.Requests);
        Assert.Equal(2, store.ChaptersOf(store.GetWork(987670002)!).Count);
        Assert.Equal(RestoreDownloadCenter.DownloadKind.Folder, center.Kind);
        Assert.False(center.IsDownloading);
        Assert.Null(center.Progress);
    }

    /// <summary>A story removed from the library before its turn is skipped:
    /// no request, no EPUB, and it doesn't come back.</summary>
    [Fact]
    public async Task FolderDownloadSkipsWorksRemovedMidRun()
    {
        using var store = LibraryStore.OpenInMemory();
        var gone = new Work(987680001, "Gone", "A");
        store.Insert(gone);
        store.Save();
        store.Delete(gone);
        store.Save();

        var client = new PollerFakeClient();
        await RestoreDownloadCenter.SaveOfflineAsync(client, store, 987680001);

        Assert.Empty(client.Requests);
        Assert.Null(store.GetWork(987680001));
    }
}
