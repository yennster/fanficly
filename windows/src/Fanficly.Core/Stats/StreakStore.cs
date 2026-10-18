using System.Globalization;
using System.Text.Json;

namespace Fanficly.Core;

public sealed record StreakInfo(int CurrentStreak, IReadOnlyList<string> ActivityDates)
{
    public bool Equals(StreakInfo? other) =>
        other is not null && CurrentStreak == other.CurrentStreak && ActivityDates.SequenceEqual(other.ActivityDates);

    public override int GetHashCode() => HashCode.Combine(CurrentStreak, ActivityDates.Count);
}

/// <summary>One day of the current week in the streak strip.</summary>
/// <param name="Name">The day's narrow name ("M", "T", …).</param>
public sealed record WeekdayActivity(string Name, bool IsToday, bool IsRead)
{
    public Guid Id { get; init; } = Guid.NewGuid();
}

/// <summary>
/// The reading day-streak. Each day something is read is recorded as a
/// <c>yyyy-MM-dd</c> date (local time; the last 100 kept) in the app's store and
/// the app-group store, and mirrored to the synced store (debounced 1 s); loading
/// unions the local and synced dates so every device counts every device's days.
/// </summary>
public static class StreakStore
{
    public const string AppGroupIdentifier = AppGroupStore.Identifier;
    public const string ActivityDatesKey = "streak.activityDates";
    public const string CurrentStreakKey = "streak.currentStreak";

    private const int HistoryLimit = 100;

    internal static TimeSpan CloudSaveDelay { get; set; } = TimeSpan.FromSeconds(1);

    /// <summary>Test seams; null uses <see cref="KeyValueStores.Default"/>,
    /// <see cref="AppGroupStore.Shared"/> and <see cref="KeyValueStores.Synced"/>.</summary>
    internal static IKeyValueStore? LocalOverride { get; set; }
    internal static IKeyValueStore? SharedOverride { get; set; }
    internal static IKeyValueStore? CloudOverride { get; set; }

    private static IKeyValueStore Local => LocalOverride ?? KeyValueStores.Default;
    private static IKeyValueStore? Shared => SharedOverride ?? AppGroupStore.Shared;
    private static IKeyValueStore Cloud => CloudOverride ?? KeyValueStores.Synced;

    private static readonly KeyValueSyncDebouncer CloudSave = new();
    private static readonly Lock ObserverGate = new();
    private static IKeyValueStore? _observedCloud;
    [ThreadStatic] private static bool _writingCloud;

    public static void RecordReadingEvent(DateTimeOffset? date = null)
    {
        var when = date ?? DateTimeOffset.Now;
        var dateStr = DayKey(when);
        var dates = ReadDatesLocal().ToList();
        if (dates.Contains(dateStr)) return;
        dates.Add(dateStr);
        dates.Sort(StringComparer.Ordinal);
        // Keep history limited to the last 100 days.
        if (dates.Count > HistoryLimit) dates.RemoveRange(0, dates.Count - HistoryLimit);
        Save(dates, CalculateStreak(dates, when));
    }

    public static StreakInfo LoadStreakInfo(DateTimeOffset? relativeTo = null)
    {
        var localDates = ReadDatesLocal();
        var merged = new SortedSet<string>(localDates, StringComparer.Ordinal);
        merged.UnionWith(ReadDatesCloud());
        var mergedDates = merged.ToList();
        if (mergedDates.Count > HistoryLimit) mergedDates.RemoveRange(0, mergedDates.Count - HistoryLimit);

        var streak = CalculateStreak(mergedDates, relativeTo);
        if (!mergedDates.SequenceEqual(localDates)) Save(mergedDates, streak);
        return new StreakInfo(streak, mergedDates);
    }

    /// <summary>Consecutive reading days ending today — or yesterday, so the
    /// streak survives until the end of a day you haven't read yet.</summary>
    public static int CalculateStreak(IEnumerable<string> dates, DateTimeOffset? relativeTo = null, TimeZoneInfo? timeZone = null)
    {
        var today = LocalDay(relativeTo ?? DateTimeOffset.Now, timeZone);
        var yesterday = today.AddDays(-1);
        var dateSet = new HashSet<string>(dates, StringComparer.Ordinal);
        var hasReadToday = dateSet.Contains(Format(today));
        var hasReadYesterday = dateSet.Contains(Format(yesterday));
        if (!hasReadToday && !hasReadYesterday) return 0;

        var streak = 0;
        var checkDate = hasReadToday ? today : yesterday;
        while (dateSet.Contains(Format(checkDate)))
        {
            streak++;
            if (checkDate == DateOnly.MinValue) break;
            checkDate = checkDate.AddDays(-1);
        }
        return streak;
    }

    /// <summary>The seven days of the week containing <paramref name="relativeTo"/>,
    /// starting on the culture's first day of the week.</summary>
    public static IReadOnlyList<WeekdayActivity> GetLast7DaysActivity(
        IEnumerable<string> dates, DateTimeOffset? relativeTo = null,
        CultureInfo? culture = null, TimeZoneInfo? timeZone = null)
    {
        var format = (culture ?? CultureInfo.CurrentCulture).DateTimeFormat;
        var dateSet = new HashSet<string>(dates, StringComparer.Ordinal);
        var today = LocalDay(relativeTo ?? DateTimeOffset.Now, timeZone);
        var todayStr = Format(today);
        var offset = ((int)today.DayOfWeek - (int)format.FirstDayOfWeek + 7) % 7;
        var startOfWeek = today.AddDays(-offset);

        var activities = new List<WeekdayActivity>();
        for (var i = 0; i < 7; i++)
        {
            var day = startOfWeek.AddDays(i);
            var dayStr = Format(day);
            activities.Add(new WeekdayActivity(NarrowDayName(format, day.DayOfWeek), dayStr == todayStr, dateSet.Contains(dayStr)));
        }
        return activities;
    }

    /// <summary>Call once at launch (not in demo or unit-test runs): merges days
    /// read on other devices now and whenever they sync in.</summary>
    public static void InstallCloudSyncObserver()
    {
        var cloud = Cloud;
        lock (ObserverGate)
        {
            if (_observedCloud is not null) return;
            _observedCloud = cloud;
        }
        SyncCloudToLocal();
        cloud.Changed += OnCloudChanged;
    }

    internal static void UninstallCloudSyncObserver()
    {
        lock (ObserverGate)
        {
            if (_observedCloud is null) return;
            _observedCloud.Changed -= OnCloudChanged;
            _observedCloud = null;
        }
    }

    private static void OnCloudChanged(string key)
    {
        // Swift observes only external changes; our own writes are skipped.
        if (key == ActivityDatesKey && !_writingCloud) SyncCloudToLocal();
    }

    public static void SyncCloudToLocal()
    {
        _ = LoadStreakInfo();
        WidgetCenter.ReloadAllTimelines();
    }

    /// <summary>Writes a pending debounced cloud mirror now (app suspend/exit).</summary>
    public static void FlushPendingCloudWrite() => CloudSave.Flush();

    /// <summary>The <c>yyyy-MM-dd</c> key for a moment, in local time.</summary>
    public static string DayKey(DateTimeOffset date, TimeZoneInfo? timeZone = null) => Format(LocalDay(date, timeZone));

    private static DateOnly LocalDay(DateTimeOffset date, TimeZoneInfo? timeZone) =>
        DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(date, timeZone ?? TimeZoneInfo.Local).DateTime);

    private static string Format(DateOnly day) => day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    /// <summary>The single-letter weekday ("EEEEE"): the first character of the
    /// culture's shortest day name.</summary>
    private static string NarrowDayName(DateTimeFormatInfo format, DayOfWeek day)
    {
        var shortest = format.GetShortestDayName(day);
        return shortest.Length == 0 ? "" : StringInfo.GetNextTextElement(shortest);
    }

    private static void Save(IReadOnlyList<string> dates, int streak)
    {
        WriteLocal(dates, streak);
        WriteCloud(dates, streak);
        WidgetCenter.ReloadAllTimelines();
    }

    private static void WriteLocal(IReadOnlyList<string> dates, int streak)
    {
        var encoded = EncodeDates(dates);
        if (Shared is { } shared)
        {
            shared.SetString(ActivityDatesKey, encoded);
            shared.SetInt(CurrentStreakKey, streak);
        }
        Local.SetString(ActivityDatesKey, encoded);
        Local.SetInt(CurrentStreakKey, streak);
    }

    private static IReadOnlyList<string> ReadDatesLocal() =>
        DecodeDates(Shared?.GetString(ActivityDatesKey)) ?? DecodeDates(Local.GetString(ActivityDatesKey)) ?? [];

    private static IReadOnlyList<string> ReadDatesCloud() => DecodeDates(Cloud.GetString(ActivityDatesKey)) ?? [];

    private static void WriteCloud(IReadOnlyList<string> dates, int streak)
    {
        var encoded = EncodeDates(dates);
        CloudSave.Schedule(CloudSaveDelay, () =>
        {
            _writingCloud = true;
            try
            {
                Cloud.SetString(ActivityDatesKey, encoded);
                Cloud.SetInt(CurrentStreakKey, streak);
            }
            finally { _writingCloud = false; }
        });
    }

    /// <summary>The dates as a JSON string array (the store holds strings).</summary>
    internal static string EncodeDates(IEnumerable<string> dates) => WidgetJson.Write(w =>
    {
        w.WriteStartArray();
        foreach (var d in dates) w.WriteStringValue(d);
        w.WriteEndArray();
    });

    /// <summary>Null when absent or not an array of strings (Swift's <c>stringArray(forKey:)</c>).</summary>
    internal static IReadOnlyList<string>? DecodeDates(string? json) =>
        WidgetJson.Read<IReadOnlyList<string>>(json, root => WidgetJson.Array(root,
            e => e.ValueKind == JsonValueKind.String ? e.GetString()! : throw new FormatException("date")));
}
