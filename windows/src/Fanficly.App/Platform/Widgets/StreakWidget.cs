using System.Globalization;
using Fanficly.Core;

namespace Fanficly.App.Platform.Widgets;

/// <summary>
/// "Reading Streak" (FanficlyStreakWidget on iOS): the current day-streak and
/// this week's reading days as dots, today ringed. Like the Swift widget it has
/// no destination of its own, so a tap just opens Fanficly.
/// </summary>
public static class StreakWidget
{
    public const string DefinitionId = "ReadingStreak";

    internal static WidgetContent Content(string size, IReadOnlyList<string> activityDates, DateTimeOffset? now = null) =>
        new(Template(size), Data(activityDates, now ?? DateTimeOffset.Now));

    public static string Template(string size) => WidgetCards.IsSmall(size) ? SmallTemplate : MediumTemplate;

    /// <summary>The card's data. The streak is recomputed from the dates (as
    /// <c>StreakStore.loadStreakInfo</c> does), so a streak that lapsed since the
    /// app last wrote reads 0, not the stale stored number.</summary>
    public static string Data(IReadOnlyList<string> activityDates, DateTimeOffset now)
    {
        var culture = CultureInfo.CurrentCulture;
        var streak = StreakStore.CalculateStreak(activityDates, now);
        var days = StreakStore.GetLast7DaysActivity(activityDates, now, culture);
        var readCount = days.Count(d => d.IsRead);
        var firstDay = (int)culture.DateTimeFormat.FirstDayOfWeek;
        return WidgetCards.Json(w =>
        {
            w.WriteStartObject();
            w.WriteString("url", WidgetCards.OpenAppUrl);
            w.WriteString("streakText", $"{streak.ToString(culture)} {(streak == 1 ? "Day" : "Days")}");
            w.WriteString("readSummary", $"Read {readCount.ToString(culture)} of last 7 days");
            w.WriteStartArray("days");
            for (var i = 0; i < days.Count; i++)
            {
                var day = days[i];
                // Full weekday names for Narrator — the one-letter labels are ambiguous.
                var fullName = culture.DateTimeFormat.DayNames[(firstDay + i) % 7];
                var alt = $"{fullName}, {(day.IsRead ? "read" : "not read")}{(day.IsToday ? ", today" : "")}";
                w.WriteStartObject();
                w.WriteString("name", day.Name);
                w.WriteBoolean("subtle", !day.IsToday);
                w.WriteString("weight", day.IsToday ? "Bolder" : "Default");
                // Which of the template's four dots this day shows.
                w.WriteString("dot", (day.IsRead ? "read" : "unread") + (day.IsToday ? "Today" : ""));
                w.WriteString("alt", alt);
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteEndObject();
        });
    }

    /// <summary>One dot image, shown only on days of its kind (the images live
    /// in the template once rather than in every day's data).</summary>
    private static string Dot(string kind, string uri, int px) =>
        $$"""{ "type": "Image", "$when": "${dot == '{{kind}}'}", "url": "{{uri}}", "altText": "${alt}", "width": "{{px}}px", "height": "{{px}}px", "horizontalAlignment": "Center", "spacing": "Small" }""";

    private static string DayColumns(int dot, string nameSize) => $$"""
        { "type": "Container", "style": "emphasis", "spacing": "Small", "items": [
          { "type": "ColumnSet", "columns": [
            { "type": "Column", "$data": "${days}", "width": "stretch", "spacing": "None", "items": [
              { "type": "TextBlock", "text": "${name}", "size": "{{nameSize}}", "weight": "${weight}", "isSubtle": "${subtle}", "horizontalAlignment": "Center", "wrap": false },
              {{Dot("read", WidgetGlyphs.DotRead, dot)}},
              {{Dot("readToday", WidgetGlyphs.DotReadToday, dot)}},
              {{Dot("unread", WidgetGlyphs.DotUnread, dot)}},
              {{Dot("unreadToday", WidgetGlyphs.DotUnreadToday, dot)}}
            ] }
          ] }
        ] }
        """;

    private static readonly string MediumTemplate = WidgetCards.Card(WidgetCards.OpenAppUrl, "Open Fanficly", $$"""
        {{WidgetCards.Badge("STREAK")}},
        { "type": "TextBlock", "text": "${streakText}", "size": "Large", "weight": "Bolder", "spacing": "Small", "wrap": false },
        { "type": "TextBlock", "text": "Reading Streak", "isSubtle": true, "spacing": "None", "wrap": false },
        { "type": "ColumnSet", "spacing": "Large", "columns": [
          { "type": "Column", "width": "stretch", "verticalContentAlignment": "Bottom", "items": [
            { "type": "TextBlock", "text": "Weekly progress", "size": "Small", "weight": "Bolder", "wrap": false } ] },
          { "type": "Column", "width": "auto", "verticalContentAlignment": "Bottom", "items": [
            { "type": "TextBlock", "text": "${readSummary}", "size": "Small", "isSubtle": true, "wrap": false } ] }
        ] },
        {{DayColumns(18, "Small")}}
        """);

    private static readonly string SmallTemplate = WidgetCards.Card(WidgetCards.OpenAppUrl, "Open Fanficly", $$"""
        {{WidgetCards.Badge("STREAK")}},
        { "type": "TextBlock", "text": "${streakText}", "size": "Medium", "weight": "Bolder", "spacing": "Small", "wrap": false },
        { "type": "TextBlock", "text": "Reading Streak", "size": "Small", "isSubtle": true, "spacing": "None", "wrap": false },
        { "type": "TextBlock", "text": "Weekly progress", "size": "Small", "weight": "Bolder", "spacing": "Medium", "wrap": false },
        {{DayColumns(14, "Small")}}
        """);
}
