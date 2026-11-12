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
        string[] dates = ["2026-06-11", "2026-06-10", "2026-06-08", "2026-06-04"]; // Thu, Wed, Mon, and the Thursday before (outside the window)

        // The rolling seven days ending today: Fri 5 … Thu 11, whatever the
        // culture's first day of the week, with no future days.
        foreach (var name in new[] { "en-US", "en-GB" })
        {
            var days = StreakStore.GetLast7DaysActivity(dates, reference, CultureInfo.GetCultureInfo(name));
            Assert.Equal(7, days.Count);
            Assert.Equal(new[] { false, false, false, true, false, true, true }, days.Select(d => d.IsRead));
            Assert.Equal(new[] { false, false, false, false, false, false, true }, days.Select(d => d.IsToday));
            Assert.Equal("F", days[0].Name);
            Assert.Equal("Friday", days[0].FullName);
            Assert.Equal("T", days[6].Name);
            Assert.Equal("Thursday", days[6].FullName);
        }

        // Whatever the current culture: exactly one today, and it's last.
        Assert.True(StreakStore.GetLast7DaysActivity(dates, reference)[6].IsToday);
    }

    [Fact]
    public void GetLast7DaysActivity_MondayCountsTheWholeWeek()
    {
        // #200: on a Monday after a week of daily reading, the calendar week read "1 of last 7 days".
        var reference = Date("2026-06-15"); // Monday
        string[] dates = ["2026-06-09", "2026-06-10", "2026-06-11", "2026-06-12", "2026-06-13", "2026-06-14", "2026-06-15"];
        var days = StreakStore.GetLast7DaysActivity(dates, reference, CultureInfo.GetCultureInfo("en-GB"));
        Assert.Equal(7, days.Count(d => d.IsRead));
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
