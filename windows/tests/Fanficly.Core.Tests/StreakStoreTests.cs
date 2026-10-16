using System.Globalization;
using Fanficly.Core;

namespace Fanficly.Core.Tests;

[Collection(GlobalStoreCollection.Name)]
public class StreakStoreTests
{
    /// <summary>Local noon on the given day (the Swift tests use local midnight;
    /// noon can't land in a DST gap).</summary>
    private static DateTimeOffset Date(string s)
    {
        var local = DateTime.ParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture).AddHours(12);
        return new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local));
    }

    [Fact]
    public void CalculateStreak_EmptyDates()
    {
        Assert.Equal(0, StreakStore.CalculateStreak([], Date("2026-06-11")));
    }

    [Fact]
    public void CalculateStreak_OnlyToday()
    {
        Assert.Equal(1, StreakStore.CalculateStreak(["2026-06-11"], Date("2026-06-11")));
    }

    [Fact]
    public void CalculateStreak_OnlyYesterday()
    {
        Assert.Equal(1, StreakStore.CalculateStreak(["2026-06-10"], Date("2026-06-11")));
    }

    [Fact]
    public void CalculateStreak_OnlyTwoDaysAgo()
    {
        Assert.Equal(0, StreakStore.CalculateStreak(["2026-06-09"], Date("2026-06-11"))); // Streak is broken
    }

    [Fact]
    public void CalculateStreak_ConsecutiveDays()
    {
        var reference = Date("2026-06-11");
        // Contiguous including today
        Assert.Equal(3, StreakStore.CalculateStreak(["2026-06-09", "2026-06-10", "2026-06-11"], reference));
        // Contiguous ending yesterday
        Assert.Equal(2, StreakStore.CalculateStreak(["2026-06-09", "2026-06-10"], reference));
        // Skipped day breaks the streak
        Assert.Equal(2, StreakStore.CalculateStreak(["2026-06-08", "2026-06-10", "2026-06-11"], reference)); // June 9 was skipped
    }

    [Fact]
    public void GetLast7DaysActivity()
    {
        var reference = Date("2026-06-11"); // June 11, 2026 is a Thursday
        string[] dates = ["2026-06-11", "2026-06-10", "2026-06-08"]; // Read Thursday, Wednesday, Monday.

        // The Swift test branches on the device calendar's first weekday; both
        // branches run here by passing the culture explicitly.

        // Sunday start — days: Sun 7, Mon 8, Tue 9, Wed 10, Thu 11, Fri 12, Sat 13
        var sunday = StreakStore.GetLast7DaysActivity(dates, reference, CultureInfo.GetCultureInfo("en-US"));
        Assert.Equal(7, sunday.Count);
        Assert.False(sunday[0].IsToday);
        Assert.False(sunday[0].IsRead);
        Assert.Equal("S", sunday[0].Name);
        Assert.False(sunday[1].IsToday);
        Assert.True(sunday[1].IsRead);
        Assert.Equal("M", sunday[1].Name);
        Assert.False(sunday[3].IsToday);
        Assert.True(sunday[3].IsRead);
        Assert.Equal("W", sunday[3].Name);
        Assert.True(sunday[4].IsToday);
        Assert.True(sunday[4].IsRead);
        Assert.Equal("T", sunday[4].Name);

        // Monday start — days: Mon 8, Tue 9, Wed 10, Thu 11, Fri 12, Sat 13, Sun 14
        var monday = StreakStore.GetLast7DaysActivity(dates, reference, CultureInfo.GetCultureInfo("en-GB"));
        Assert.Equal(7, monday.Count);
        Assert.False(monday[0].IsToday);
        Assert.True(monday[0].IsRead);
        Assert.Equal("M", monday[0].Name);
        Assert.False(monday[2].IsToday);
        Assert.True(monday[2].IsRead);
        Assert.Equal("W", monday[2].Name);
        Assert.True(monday[3].IsToday);
        Assert.True(monday[3].IsRead);
        Assert.Equal("T", monday[3].Name);

        // Whatever the current culture: exactly one today.
        Assert.Single(StreakStore.GetLast7DaysActivity(dates, reference), a => a.IsToday);
    }

    // MARK: - Windows-only: the stores behind the streak

    [Fact]
    public void RecordAndLoad_UnionLocalAndSyncedDays()
    {
        var local = new InMemoryKeyValueStore();
        var shared = new InMemoryKeyValueStore();
        var cloud = new InMemoryKeyValueStore();
        StreakStore.LocalOverride = local;
        StreakStore.SharedOverride = shared;
        StreakStore.CloudOverride = cloud;
        try
        {
            StreakStore.RecordReadingEvent(Date("2026-06-11"));
            StreakStore.RecordReadingEvent(Date("2026-06-11")); // same day: no change
            Assert.Equal("[\"2026-06-11\"]", shared.GetString(StreakStore.ActivityDatesKey));
            Assert.Equal(1, local.GetInt(StreakStore.CurrentStreakKey));

            StreakStore.FlushPendingCloudWrite();
            Assert.Equal("[\"2026-06-11\"]", cloud.GetString(StreakStore.ActivityDatesKey));

            // Another device read yesterday.
            cloud.SetString(StreakStore.ActivityDatesKey, StreakStore.EncodeDates(["2026-06-10", "2026-06-11"]));
            var info = StreakStore.LoadStreakInfo(Date("2026-06-11"));
            Assert.Equal(new StreakInfo(2, ["2026-06-10", "2026-06-11"]), info);
            Assert.Equal(["2026-06-10", "2026-06-11"], StreakStore.DecodeDates(shared.GetString(StreakStore.ActivityDatesKey))!);
            Assert.Null(StreakStore.DecodeDates("{\"not\":\"an array\"}"));
        }
        finally
        {
            StreakStore.FlushPendingCloudWrite();
            StreakStore.LocalOverride = null;
            StreakStore.SharedOverride = null;
            StreakStore.CloudOverride = null;
        }
    }
}

/// <summary>Test classes that swap a store's static test seams run one at a time.</summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class GlobalStoreCollection
{
    public const string Name = "Widget and streak stores";
}
