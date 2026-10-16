using System.Globalization;
using Fanficly.Core;

namespace Fanficly.App.Platform.Widgets;

/// <summary>
/// "Recommendation" (FanficlyRecommendationWidget on iOS): a random story from
/// the library (starred and pinned ones first in the list it picks from),
/// with its author and — on medium — its summary and first tag. Tapping opens
/// it through <c>fanficly://resume/&lt;id&gt;</c>, like the Swift link.
/// </summary>
public static class RecommendationWidget
{
    public const string DefinitionId = "Recommendation";

    /// <summary>The Swift timeline keeps a pick for 30 minutes. Windows widgets
    /// update whenever the app pushes (every reading-progress save), so the pick
    /// is kept in the widget's custom state and only re-rolled once it's this old.</summary>
    public static readonly TimeSpan PickLifetime = TimeSpan.FromMinutes(30);

    internal static WidgetContent Content(string size, IReadOnlyList<WidgetRecommendation> recs, string? customState, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.Now;
        var rec = Pick(recs, customState, at, out var pickedAt);
        var state = rec is null ? "" : $"{rec.WorkId.ToString(CultureInfo.InvariantCulture)}|{pickedAt.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture)}";
        return new(Template(size), Data(rec), state);
    }

    /// <summary>Keeps the previous pick while it's still in the list and younger
    /// than <see cref="PickLifetime"/>; otherwise picks at random.</summary>
    internal static WidgetRecommendation? Pick(IReadOnlyList<WidgetRecommendation> recs, string? customState, DateTimeOffset now, out DateTimeOffset pickedAt)
    {
        pickedAt = now;
        if (recs.Count == 0) return null;
        var parts = (customState ?? "").Split('|');
        if (parts.Length == 2
            && int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var id)
            && long.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var seconds))
        {
            var then = DateTimeOffset.FromUnixTimeSeconds(seconds);
            var kept = recs.FirstOrDefault(r => r.WorkId == id);
            if (kept is not null && now - then < PickLifetime && then <= now)
            {
                pickedAt = then;
                return kept;
            }
        }
        return recs[Random.Shared.Next(recs.Count)];
    }

    public static string Template(string size) => WidgetCards.IsSmall(size) ? SmallTemplate : MediumTemplate;

    public static string Data(WidgetRecommendation? rec) => WidgetCards.Json(w =>
    {
        w.WriteStartObject();
        w.WriteBoolean("hasRec", rec is not null);
        w.WriteString("url", rec is null ? WidgetCards.OpenAppUrl : DeepLink.ResumeUri(rec.WorkId).AbsoluteUri);
        w.WriteString("tip", rec is null ? "Open Fanficly" : $"Open {rec.Title}");
        if (rec is not null)
        {
            w.WriteString("title", rec.Title);
            w.WriteString("author", rec.Author);
            w.WriteString("summary", rec.Summary);
            w.WriteBoolean("hasSummary", rec.Summary.Length > 0);
            w.WriteString("tag", rec.Tags.Count > 0 ? rec.Tags[0] : "");
            w.WriteBoolean("hasTag", rec.Tags.Count > 0);
        }
        w.WriteEndObject();
    });

    private static readonly string MediumTemplate = WidgetCards.Card("${url}", "${tip}", $$"""
        {{WidgetCards.Badge("FOR YOU")}},
        {{WidgetCards.Empty("medium", "No Starred Works", "Star works to get recs", "${!hasRec}")}},
        { "type": "Container", "$when": "${hasRec}", "spacing": "Small", "items": [
          { "type": "TextBlock", "text": "${title}", "size": "Medium", "weight": "Bolder", "wrap": false },
          { "type": "TextBlock", "text": "${author}", "isSubtle": true, "spacing": "None", "wrap": false },
          { "type": "TextBlock", "text": "${summary}", "size": "Small", "wrap": true, "maxLines": 2, "spacing": "Medium", "$when": "${hasSummary}" },
          { "type": "TextBlock", "text": "${tag}", "size": "Small", "weight": "Bolder", "color": "Accent", "wrap": false, "spacing": "Small", "$when": "${hasTag}" }
        ] }
        """);

    private static readonly string SmallTemplate = WidgetCards.Card("${url}", "${tip}", $$"""
        {{WidgetCards.Badge("FOR YOU")}},
        {{WidgetCards.Empty("small", "No Starred Works", "Star works to get recs", "${!hasRec}")}},
        { "type": "Container", "$when": "${hasRec}", "spacing": "Small", "items": [
          { "type": "TextBlock", "text": "${title}", "weight": "Bolder", "wrap": true, "maxLines": 2 },
          { "type": "TextBlock", "text": "${author}", "size": "Small", "isSubtle": true, "spacing": "None", "wrap": false },
          { "type": "ColumnSet", "spacing": "Medium", "columns": [
            { "type": "Column", "width": "auto", "verticalContentAlignment": "Center", "items": [
              {{WidgetCards.Glyph(WidgetGlyphs.Book, 12)}} ] },
            { "type": "Column", "width": "stretch", "verticalContentAlignment": "Center", "items": [
              { "type": "TextBlock", "text": "Random Rec", "size": "Small", "weight": "Bolder", "wrap": false } ] }
          ] }
        ] }
        """);
}
