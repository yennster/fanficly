using System.Globalization;
using Fanficly.Core;

namespace Fanficly.App.Views.Stats;

/// <summary>The period the Stats screen aggregates over. <see cref="AllTime"/>
/// has no date interval.</summary>
public enum StatsPeriod { Week, Month, Year, AllTime }

public static class StatsPeriodExtensions
{
    public static readonly StatsPeriod[] All = [StatsPeriod.Week, StatsPeriod.Month, StatsPeriod.Year, StatsPeriod.AllTime];

    public static string Title(this StatsPeriod period) => period switch
    {
        StatsPeriod.Week => "Week",
        StatsPeriod.Month => "Month",
        StatsPeriod.Year => "Year",
        _ => "All Time",
    };

    public static string RawValue(this StatsPeriod period) => period switch
    {
        StatsPeriod.Week => "week",
        StatsPeriod.Month => "month",
        StatsPeriod.Year => "year",
        _ => "allTime",
    };

    /// <summary>The calendar unit this period steps by; null for all-time.</summary>
    public static StatsCalendarUnit? Unit(this StatsPeriod period) => period switch
    {
        StatsPeriod.Week => StatsCalendarUnit.Week,
        StatsPeriod.Month => StatsCalendarUnit.Month,
        StatsPeriod.Year => StatsCalendarUnit.Year,
        _ => null,
    };

    /// <summary>The date interval for <paramref name="anchor"/>'s period; null for all-time.</summary>
    public static DateSpan? Interval(this StatsPeriod period, DateTimeOffset anchor) =>
        period.Unit() is { } unit ? DateSpan.Of(unit, anchor) : null;

    /// <summary>Moves <paramref name="anchor"/> by one period (‹ ›).</summary>
    public static DateTimeOffset Step(this StatsPeriod period, DateTimeOffset anchor, int direction) => period switch
    {
        StatsPeriod.Week => anchor.AddDays(7 * direction),
        StatsPeriod.Month => anchor.AddMonths(direction),
        StatsPeriod.Year => anchor.AddYears(direction),
        _ => anchor,
    };

    /// <summary>Human label for the period shown ("This Week", "Jun 1 – Jun 7",
    /// "June 2026", "2025", "All Time").</summary>
    public static string ScopeTitle(this StatsPeriod period, DateTimeOffset anchor, DateTimeOffset? now = null)
    {
        if (period.Interval(anchor) is not { } interval) return "All Time";
        var culture = CultureInfo.CurrentCulture;
        switch (period)
        {
            case StatsPeriod.Week:
                if (interval.Contains(now ?? DateTimeOffset.Now)) return "This Week";
                var end = interval.End.AddDays(-1);
                return $"{interval.Start.ToString("MMM d", culture)} – {end.ToString("MMM d", culture)}";
            case StatsPeriod.Month:
                return interval.Start.ToString("MMMM yyyy", culture);
            case StatsPeriod.Year:
                return interval.Start.Year.ToString(CultureInfo.InvariantCulture);
            default:
                return "All Time";
        }
    }
}
