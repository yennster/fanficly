using System.Globalization;

namespace Fanficly.Core;

/// <summary>Mirrors <c>reader.profiles</c> between the local settings store
/// (<see cref="KeyValueStores.Default"/>) and the cross-device store
/// (<see cref="KeyValueStores.Synced"/>), merging with
/// <see cref="ReaderProfile.MergedProfiles"/> both ways — never last-writer-wins, and
/// deletions travel as tombstones.</summary>
public static class ReaderProfileSyncStore
{
    public const string ProfilesKey = "reader.profiles";
    public const string ProfilesUpdatedAtKey = "reader.profiles.updatedAt";

    private static readonly Lock Gate = new();
    private static IKeyValueStore? _observedCloud;
    private static Action<string>? _observer;
    private static readonly Lock SyncLock = new();
    [ThreadStatic] private static bool _inSync;

    /// <summary>Pulls the cloud copy in, publishes the local one if the cloud is empty,
    /// and from then on merges whenever another device's change arrives. Once per
    /// process (the app skips it in demo and test runs).</summary>
    public static void InstallCloudSyncObserver()
    {
        var cloud = KeyValueStores.Synced;
        lock (Gate)
        {
            if (_observer is not null) return;
            _observer = key =>
            {
                if (key == ProfilesKey) SyncCloudToLocal();
            };
            _observedCloud = cloud;
        }
        SyncCloudToLocal();
        PublishLocalProfilesIfCloudIsEmpty();
        cloud.Changed += _observer;
    }

    /// <summary>Removes the observer <see cref="InstallCloudSyncObserver"/> added (tests, shutdown).</summary>
    public static void UninstallCloudSyncObserver()
    {
        lock (Gate)
        {
            if (_observer is not null && _observedCloud is not null) _observedCloud.Changed -= _observer;
            _observer = null;
            _observedCloud = null;
        }
    }

    /// <summary>After a local edit: merge the edited profiles into the cloud copy and
    /// store the result on both sides.</summary>
    public static void PublishLocalProfiles(string profilesJSON) =>
        PublishLocalProfiles(profilesJSON, KeyValueStores.Default, KeyValueStores.Synced, DateTimeOffset.UtcNow);

    /// <summary>Another device changed the cloud copy: merge it into the local one, and
    /// write the merge back to the cloud if it differs.</summary>
    public static void SyncCloudToLocal() =>
        SyncCloudToLocal(KeyValueStores.Default, KeyValueStores.Synced, DateTimeOffset.UtcNow);

    internal static void PublishLocalProfiles(string profilesJSON, IKeyValueStore local, IKeyValueStore cloud,
                                              DateTimeOffset now)
    {
        if (profilesJSON.Length == 0) return;
        RunGuarded(() =>
        {
            var cloudJSON = cloud.GetString(ProfilesKey);
            var mergedJSON = ReaderProfile.MergedProfiles(cloudJSON, profilesJSON, now);
            if (local.GetString(ProfilesKey) != mergedJSON) local.SetString(ProfilesKey, mergedJSON);
            cloud.SetString(ProfilesKey, mergedJSON);
            SetStamp(cloud, now);
        });
    }

    internal static void SyncCloudToLocal(IKeyValueStore local, IKeyValueStore cloud, DateTimeOffset now)
    {
        var cloudJSON = cloud.GetString(ProfilesKey);
        if (string.IsNullOrEmpty(cloudJSON)) return;
        RunGuarded(() =>
        {
            var localJSON = local.GetString(ProfilesKey);
            var mergedJSON = ReaderProfile.MergedProfiles(localJSON, cloudJSON, now);
            if (localJSON != mergedJSON) local.SetString(ProfilesKey, mergedJSON);
            if (cloudJSON != mergedJSON)
            {
                cloud.SetString(ProfilesKey, mergedJSON);
                SetStamp(cloud, now);
            }
        });
    }

    private static void PublishLocalProfilesIfCloudIsEmpty()
    {
        var cloudJSON = KeyValueStores.Synced.GetString(ProfilesKey);
        if (!string.IsNullOrEmpty(cloudJSON)) return;
        var localJSON = KeyValueStores.Default.GetString(ProfilesKey);
        if (string.IsNullOrEmpty(localJSON)) return;
        PublishLocalProfiles(localJSON);
    }

    private static void SetStamp(IKeyValueStore cloud, DateTimeOffset now) =>
        cloud.SetString(ProfilesUpdatedAtKey,
                        ReaderProfile.UnixSeconds(now).ToString("R", CultureInfo.InvariantCulture));

    /// <summary>Unlike iCloud's external-change notification, the synced store's
    /// <see cref="IKeyValueStore.Changed"/> also fires (synchronously, on the writing
    /// thread) for our own writes; skip those so a merge doesn't re-enter itself.
    /// Merges from different threads run one at a time.</summary>
    private static void RunGuarded(Action body)
    {
        if (_inSync) return;
        lock (SyncLock)
        {
            _inSync = true;
            try
            {
                body();
            }
            finally
            {
                _inSync = false;
            }
        }
    }
}
