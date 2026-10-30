using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Switching AO3 accounts (#159): forgetting an account deletes its
/// subscriptions and list-sync stamps, and a list that was still on its way when
/// the account changed is dropped.</summary>
[Collection(GlobalStoreCollection.Name)] // AccountData.Generation is app-wide
public sealed class AccountDataTests
{
    private static readonly AO3Subscription Fic = new(AO3SubscriptionKind.Work, "1", "Fic One", "carol");

    [Fact]
    public async Task ForgetDeletesSubscriptionsAndSyncStamps()
    {
        using var store = LibraryStore.OpenInMemory();
        var stamps = new InMemoryKeyValueStore();
        var client = new PollerFakeClient { SubscriptionsResponse = [Fic] };
        var poller = new SubscriptionPoller(client, store, "alice", syncStamps: stamps);
        await poller.SyncSubscriptionListAsync();
        stamps.SetString("reader.theme", "kept");
        Assert.True(poller.HasSyncedList);
        Assert.Single(store.Subscriptions());

        AccountData.Forget(store, stamps);

        Assert.Empty(store.Subscriptions());
        Assert.False(poller.HasSyncedList);
        Assert.True(poller.ListSyncIsDue());
        Assert.Equal("kept", stamps.GetString("reader.theme"));
    }

    // Alice's list arrives after she signed out: it mustn't land under Bob.
    [Fact]
    public async Task ListArrivingAfterTheAccountChangedIsDropped()
    {
        using var store = LibraryStore.OpenInMemory();
        var stamps = new InMemoryKeyValueStore();
        var client = new PollerFakeClient { SubscriptionsResponse = [Fic] };
        client.OnFetchSubscriptions = () => AccountData.Forget(store, stamps);
        var poller = new SubscriptionPoller(client, store, "alice", syncStamps: stamps);

        var fresh = await poller.SyncSubscriptionListAsync();

        Assert.Empty(fresh);
        Assert.Empty(store.Subscriptions());
        Assert.False(poller.HasSyncedList);
    }

    // Alice signs out while Refresh checks her subscriptions for new chapters:
    // her remaining subscriptions aren't fetched, touched or alerted for.
    [Fact]
    public async Task ChapterCheckSkipsSubscriptionsOnceTheAccountChanges()
    {
        using var store = LibraryStore.OpenInMemory();
        var stamps = new InMemoryKeyValueStore();
        store.Insert(new SubscriptionRecord("work:1", "work", "Fic One") { LastSeenChapterCount = 1 });
        store.Insert(new SubscriptionRecord("work:2", "work", "Fic Two") { LastSeenChapterCount = 1 });
        store.Save();
        var client = new PollerFakeClient();
        client.ChapterCounts[1] = 2;
        client.ChapterCounts[2] = 2;
        client.OnRequest = _ => AccountData.Forget(store, stamps);
        var notifier = new RecordingNotifier();
        var poller = new SubscriptionPoller(client, store, "alice", notifier, stamps);

        Assert.Equal(0, await poller.CheckWorksForNewChaptersAsync());

        Assert.Single(client.Requests);
        Assert.Empty(notifier.Posted);
        Assert.Empty(store.Subscriptions());
    }

    // A shared backup keeps another AO3 account's subscriptions, but they never
    // restore here; one from before subscriptions recorded their account does.
    [Fact]
    public void BackedUpSubscriptionsRestoreOnlyForTheirAccount()
    {
        SubscriptionBackup Sub(string? account) => new("work:1", "work", "Fic", "", 1, null, account);
        Assert.True(LibrarySyncManager.SubscriptionBelongs(Sub("alice"), "Alice"));
        Assert.False(LibrarySyncManager.SubscriptionBelongs(Sub("alice"), "bob"));
        Assert.False(LibrarySyncManager.SubscriptionBelongs(Sub("alice"), null));
        Assert.True(LibrarySyncManager.SubscriptionBelongs(Sub(null), "bob"));
        Assert.Equal("alice", LibrarySyncManager.MergedSubscription(Sub(null), Sub("alice")).Account);

        var backup = new LibraryBackup([], [], [Sub("alice"), Sub(null) with { Key = "work:2" }], [], [], [], [], null, null, [],
                                       DateTimeOffset.UnixEpoch);
        var decoded = LibraryBackupJson.Decode(LibraryBackupJson.Encode(backup));
        Assert.Equal(["alice", null], decoded.Subscriptions.Select(s => s.Account));
    }

    [Fact]
    public async Task RestoreSkipsAnotherAccountsSubscriptions()
    {
        var path = Path.Combine(Path.GetTempPath(), $"test_backup_{Guid.NewGuid()}.json");
        try
        {
            using var alicePC = LibraryStore.OpenInMemory();
            alicePC.Insert(new SubscriptionRecord("work:1", "work", "Alice's fic"));
            alicePC.Save();
            string? account = "alice";
            var sync = new LibrarySyncManager(new InMemoryKeyValueStore()) { BackupPathOverride = path, CurrentAccount = () => account };
            sync.Backup(alicePC);

            // Signed out, nothing goes into the file untagged.
            account = null;
            var empty = Path.Combine(Path.GetTempPath(), $"test_backup_{Guid.NewGuid()}.json");
            try
            {
                new LibrarySyncManager(new InMemoryKeyValueStore()) { BackupPathOverride = empty, CurrentAccount = () => account }.Backup(alicePC);
                Assert.Empty(LibraryBackupJson.Decode(File.ReadAllText(empty)).Subscriptions);
            }
            finally
            {
                try { File.Delete(empty); } catch (IOException) { }
            }

            using var bobPC = LibraryStore.OpenInMemory();
            account = "bob";
            Assert.True(await sync.RestoreAsync(bobPC));
            Assert.Empty(bobPC.Subscriptions());

            account = "Alice";
            Assert.True(await sync.RestoreAsync(bobPC));
            Assert.Single(bobPC.Subscriptions());
        }
        finally
        {
            try { File.Delete(path); } catch (IOException) { }
        }
    }
}
