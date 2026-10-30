namespace Fanficly.Core;

/// <summary>What this PC keeps about the signed-in AO3 account (#159): its
/// subscription records (and their chapter baselines) and when its list was last
/// synced. Signing out, or signing in as someone else, forgets them, so the next
/// account never sees or gets alerts for the last one's subscriptions. Locally
/// followed works and authors aren't account data. Call it on the records thread.</summary>
public static class AccountData
{
    private static int s_generation;

    /// <summary>Goes up each time an account's data is forgotten. A list sync that
    /// started before then fetched the previous account's list.</summary>
    public static int Generation => Volatile.Read(ref s_generation);

    public static void Forget(LibraryStore store, IKeyValueStore? syncStamps = null)
    {
        Interlocked.Increment(ref s_generation);
        foreach (var record in store.All<SubscriptionRecord>()) store.Delete(record);
        store.TrySave();
        var stamps = syncStamps ?? SubscriptionPoller.DefaultSyncStamps;
        foreach (var key in stamps.Keys.Where(k => k.StartsWith(SubscriptionPoller.ListSyncKeyPrefix, StringComparison.Ordinal)).ToList())
            stamps.Remove(key);
    }
}
