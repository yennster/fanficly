using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Reader profiles: the merge/tombstone rules (ported from the profile cases
/// in the Swift PersistenceTests), the JSON shape shared with the Apple apps, the
/// per-device keys and legacy migration, and the sync store.</summary>
public class ReaderProfileTests
{
    private static DateTimeOffset At(double seconds) => DateTimeOffset.UnixEpoch.AddSeconds(seconds);

    private static ReaderProfile Profile(string name, string theme, double fontSize) =>
        ReaderProfile.DefaultProfiles[0] with { Name = name, ThemeRaw = theme, FontSizePt = fontSize };

    [Fact]
    public void ProfileDeletionTombstonesAndSurvivesMerge()
    {
        var t0 = At(1_000);
        var t1 = At(2_000);
        var @base = ReaderProfile.DefaultProfiles[0];
        var night = Profile("Night", "dracula", 20);

        var original = ReaderProfile.SaveProfiles([@base, night], previousJSON: "", now: t0);
        // A stale copy that predates the sync stamps entirely.
        var legacyCloud = ReaderProfile.SaveProfiles([@base, night]);

        // Deleting keeps the profile in the stored JSON as a hidden tombstone.
        var afterDelete = ReaderProfile.SaveProfiles([@base], previousJSON: original, now: t1);
        Assert.Equal([@base.Name], ReaderProfile.LoadProfiles(afterDelete).Select(p => p.Name));
        var tombstone = ReaderProfile.DecodeProfiles(afterDelete)?.FirstOrDefault(p => p.Name == "Night");
        Assert.Equal(2_000, tombstone?.DeletedAt);

        // The deletion beats stale live copies in both merge directions
        // (PublishLocalProfiles merges local into cloud, SyncCloudToLocal the
        // reverse), including copies stamped before the delete.
        foreach (var merged in new[]
                 {
                     ReaderProfile.MergedProfiles(legacyCloud, afterDelete, now: t1),
                     ReaderProfile.MergedProfiles(afterDelete, legacyCloud, now: t1),
                     ReaderProfile.MergedProfiles(original, afterDelete, now: t1),
                 })
        {
            Assert.DoesNotContain(ReaderProfile.LoadProfiles(merged), p => p.Name == "Night");
            Assert.Contains(ReaderProfile.DecodeProfiles(merged)!, p => p.Name == "Night" && p.IsDeleted);
        }
    }

    [Fact]
    public void ProfileRecreateAfterDeleteBeatsTombstone()
    {
        var @base = ReaderProfile.DefaultProfiles[0];
        var night = Profile("Night", "dracula", 20);

        var original = ReaderProfile.SaveProfiles([@base, night], previousJSON: "", now: At(1_000));
        var deleted = ReaderProfile.SaveProfiles([@base], previousJSON: original, now: At(2_000));
        var recreated = ReaderProfile.SaveProfiles([@base, night], previousJSON: deleted, now: At(3_000));

        foreach (var merged in new[]
                 {
                     ReaderProfile.MergedProfiles(deleted, recreated),
                     ReaderProfile.MergedProfiles(recreated, deleted),
                 })
        {
            Assert.Contains(ReaderProfile.LoadProfiles(merged), p => p.Name == "Night");
        }

        // Re-saving an unchanged profile must not bump its stamp, or a routine
        // save on one device would override edits and deletes made elsewhere.
        var baseEntry = ReaderProfile.DecodeProfiles(recreated)?.FirstOrDefault(p => p.Name == @base.Name);
        Assert.Equal(1_000, baseEntry?.UpdatedAt);
    }

    [Fact]
    public void ProfileTombstoneExpires()
    {
        var @base = ReaderProfile.DefaultProfiles[0];
        var night = Profile("Night", "dracula", 20);

        var original = ReaderProfile.SaveProfiles([@base, night], previousJSON: "", now: At(1_000));
        var deleted = ReaderProfile.SaveProfiles([@base], previousJSON: original, now: At(2_000));

        var beyond = At(2_000 + ReaderProfile.TombstoneLifetime.TotalSeconds + 1);
        var merged = ReaderProfile.MergedProfiles(deleted, deleted, now: beyond);
        Assert.DoesNotContain(ReaderProfile.DecodeProfiles(merged)!, p => p.Name == "Night");

        // The save path prunes expired tombstones too.
        var resaved = ReaderProfile.SaveProfiles([@base], previousJSON: deleted, now: beyond);
        Assert.DoesNotContain(ReaderProfile.DecodeProfiles(resaved)!, p => p.Name == "Night");

        // Just inside the window the tombstone is still carried.
        var inside = At(2_000 + ReaderProfile.TombstoneLifetime.TotalSeconds - 1);
        var carried = ReaderProfile.MergedProfiles(deleted, deleted, now: inside);
        Assert.Contains(ReaderProfile.DecodeProfiles(carried)!, p => p.Name == "Night" && p.IsDeleted);
    }

    [Fact]
    public void ProfileMergeKeepsNewestEditAndLegacyUnion()
    {
        var @base = ReaderProfile.DefaultProfiles[0];
        var night = Profile("Night", "dracula", 20);
        var original = ReaderProfile.SaveProfiles([@base, night], previousJSON: "", now: At(1_000));

        var editedNight = night with { FontSizePt = 24 };
        var edited = ReaderProfile.SaveProfiles([@base, editedNight], previousJSON: original, now: At(2_000));

        foreach (var merged in new[]
                 {
                     ReaderProfile.MergedProfiles(original, edited),
                     ReaderProfile.MergedProfiles(edited, original),
                 })
        {
            Assert.Equal(24, ReaderProfile.LoadProfiles(merged).First(p => p.Name == "Night").FontSizePt);
        }

        // Two pre-tombstone copies with no stamps keep the original union
        // behavior: names union and the incoming copy wins a name collision.
        var legacyA = ReaderProfile.SaveProfiles([@base, night]);
        var legacyNight = night with { FontSizePt = 30 };
        var legacyB = ReaderProfile.SaveProfiles([legacyNight, Profile("Sepia", "sepia", 18)]);
        var profiles = ReaderProfile.LoadProfiles(ReaderProfile.MergedProfiles(legacyA, legacyB));
        Assert.Equal(30, profiles.First(p => p.Name == "Night").FontSizePt);
        Assert.Equal(new HashSet<string> { @base.Name, "Night", "Sepia" }, profiles.Select(p => p.Name).ToHashSet());
    }

    // MARK: - JSON shape shared with the Apple apps

    [Fact]
    public void EncodesTheSwiftJSONShape()
    {
        // Swift's JSONEncoder: declared key order, nil optionals omitted, integral
        // doubles without ".0".
        Assert.Equal(
            "[{\"name\":\"Default\",\"themeRaw\":\"system\",\"fontFamilyRaw\":\"newYork\",\"widthRaw\":\"medium\"," +
            "\"widthPercent\":70,\"modeRaw\":\"continuous\",\"fontSizePt\":18,\"lineSpacingPt\":6,\"paragraphSpacingPt\":16," +
            "\"pageTurnHaptics\":false,\"pageTurnAnimations\":true,\"kerningPt\":0,\"boldText\":false}]",
            ReaderProfile.SaveProfiles(ReaderProfile.DefaultProfiles));

        var stamped = ReaderProfile.SaveProfiles([Profile("A/B \"x\"", "dark", 17.5) with { KerningPt = null, BoldText = null }],
                                                 previousJSON: "", now: At(1_760_000_000.25));
        Assert.Contains("\"name\":\"A\\/B \\\"x\\\"\"", stamped);
        Assert.Contains("\"fontSizePt\":17.5", stamped);
        Assert.Contains("\"updatedAt\":1760000000.25", stamped);
        Assert.DoesNotContain("kerningPt", stamped);
        Assert.DoesNotContain("deletedAt", stamped);
        Assert.Equal("A/B \"x\"", ReaderProfile.LoadProfiles(stamped)[0].Name);
    }

    [Fact]
    public void DecodesSwiftJSONAndFillsLegacyWidth()
    {
        // As an older Apple build wrote it: no widthPercent / kerning / bold /
        // stamps, plus a key this build doesn't know.
        const string json =
            "[{\"name\":\"Old\",\"themeRaw\":\"sepia\",\"fontFamilyRaw\":\"serif\",\"widthRaw\":\"wide\",\"modeRaw\":\"pageByPage\"," +
            "\"fontSizePt\":20,\"lineSpacingPt\":6.5,\"paragraphSpacingPt\":16,\"pageTurnHaptics\":true,\"pageTurnAnimations\":false," +
            "\"futureKey\":[1,2]}," +
            "{\"name\":\"NoWidth\",\"themeRaw\":\"light\",\"fontFamilyRaw\":\"sans\",\"widthRaw\":null,\"modeRaw\":\"continuous\"," +
            "\"fontSizePt\":18,\"lineSpacingPt\":6,\"paragraphSpacingPt\":16,\"pageTurnHaptics\":false,\"pageTurnAnimations\":true}]";
        var profiles = ReaderProfile.DecodeProfiles(json)!;
        Assert.Equal(2, profiles.Count);
        Assert.Equal(85.0, profiles[0].WidthPercent);
        Assert.Equal(6.5, profiles[0].LineSpacingPt);
        Assert.Null(profiles[0].KerningPt);
        Assert.Equal(70.0, profiles[1].WidthPercent);
    }

    [Fact]
    public void UndecodableJSONFallsBackToDefaults()
    {
        Assert.Null(ReaderProfile.DecodeProfiles(""));
        Assert.Null(ReaderProfile.DecodeProfiles("not json"));
        Assert.Null(ReaderProfile.DecodeProfiles("{}"));
        // One bad entry (a missing required field) fails the whole list, like JSONDecoder.
        Assert.Null(ReaderProfile.DecodeProfiles("[{\"name\":\"x\"}]"));
        Assert.Equal(ReaderProfile.DefaultProfiles, ReaderProfile.LoadProfiles("garbage"));
    }

    // MARK: - Per-device keys

    [Fact]
    public void DeviceKeysUseTheWindowsSuffix()
    {
        Assert.Equal("reader.theme.windows", ReaderProfile.DeviceKey("reader.theme"));
        Assert.Equal("reader.activeProfile.windows", ReaderProfile.DeviceActiveProfileKey);
        Assert.Equal("reader.theme.pad", ReaderProfile.DeviceKey("reader.theme", ReaderDevice.Pad));
        Assert.Equal("reader.fontSizePt.mac", ReaderProfile.DeviceKey("reader.fontSizePt", ReaderDevice.Mac));
        Assert.Equal("reader.mode.phone", ReaderProfile.DeviceKey("reader.mode", ReaderDevice.Phone));
    }

    [Fact]
    public void LegacySettingsMigrateOnceToTheDeviceKey()
    {
        var store = new InMemoryKeyValueStore();
        store.SetString("reader.theme", "sepia");
        store.SetDouble("reader.fontSizePt", 22);
        store.SetString("reader.mode", "pageByPage");
        // A device value already set is never overwritten.
        store.SetString("reader.mode.windows", "continuous");
        // Not a reader typography key: left alone.
        store.SetString("content.filterMatureExplicit", "true");

        ReaderProfile.MigrateLegacySettingsIfNeeded(store);

        Assert.Equal("sepia", store.GetString("reader.theme.windows"));
        Assert.Equal(22, store.GetDouble("reader.fontSizePt.windows"));
        Assert.Equal("continuous", store.GetString("reader.mode.windows"));
        Assert.False(store.Contains("content.filterMatureExplicit.windows"));
        Assert.False(store.Contains("reader.fontFamily.windows"));

        // Running again changes nothing, even after the legacy value changes.
        store.SetString("reader.theme", "dark");
        ReaderProfile.MigrateLegacySettingsIfNeeded(store);
        Assert.Equal("sepia", store.GetString("reader.theme.windows"));
    }

    // MARK: - Sync store

    [Fact]
    public void SyncMergesBothWaysAndPropagatesDeletes()
    {
        var local = new InMemoryKeyValueStore();
        var cloud = new InMemoryKeyValueStore();
        var @base = ReaderProfile.DefaultProfiles[0];
        var night = Profile("Night", "dracula", 20);

        // Another device published Night; this one only has Sepia locally.
        cloud.SetString(ReaderProfileSyncStore.ProfilesKey, ReaderProfile.SaveProfiles([@base, night], "", At(1_000)));
        local.SetString(ReaderProfileSyncStore.ProfilesKey,
                        ReaderProfile.SaveProfiles([@base, Profile("Sepia", "sepia", 18)], "", At(1_500)));

        ReaderProfileSyncStore.SyncCloudToLocal(local, cloud, At(1_600));
        var names = ReaderProfile.LoadProfiles(local.GetString(ReaderProfileSyncStore.ProfilesKey)).Select(p => p.Name).ToHashSet();
        Assert.Equal(new HashSet<string> { "Default", "Night", "Sepia" }, names);
        // The union went back up, stamped.
        Assert.Equal(local.GetString(ReaderProfileSyncStore.ProfilesKey), cloud.GetString(ReaderProfileSyncStore.ProfilesKey));
        Assert.True(cloud.Contains(ReaderProfileSyncStore.ProfilesUpdatedAtKey));

        // Deleting Night here publishes a tombstone the cloud keeps.
        var previous = local.GetString(ReaderProfileSyncStore.ProfilesKey)!;
        var edited = ReaderProfile.LoadProfiles(previous).Where(p => p.Name != "Night");
        ReaderProfileSyncStore.PublishLocalProfiles(ReaderProfile.SaveProfiles(edited, previous, At(2_000)), local, cloud, At(2_000));
        Assert.DoesNotContain(ReaderProfile.LoadProfiles(cloud.GetString(ReaderProfileSyncStore.ProfilesKey)), p => p.Name == "Night");
        Assert.DoesNotContain(ReaderProfile.LoadProfiles(local.GetString(ReaderProfileSyncStore.ProfilesKey)), p => p.Name == "Night");
    }

    [Fact]
    public void SyncIgnoresAnEmptyCloud()
    {
        var local = new InMemoryKeyValueStore();
        var cloud = new InMemoryKeyValueStore();
        local.SetString(ReaderProfileSyncStore.ProfilesKey, ReaderProfile.SaveProfiles(ReaderProfile.DefaultProfiles));
        ReaderProfileSyncStore.SyncCloudToLocal(local, cloud, At(1_000));
        Assert.False(cloud.Contains(ReaderProfileSyncStore.ProfilesKey));
        Assert.Equal(ReaderProfile.SaveProfiles(ReaderProfile.DefaultProfiles), local.GetString(ReaderProfileSyncStore.ProfilesKey));
    }
}
