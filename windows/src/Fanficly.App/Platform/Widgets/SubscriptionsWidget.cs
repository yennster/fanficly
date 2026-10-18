using System.Globalization;
using Fanficly.Core;

namespace Fanficly.App.Platform.Widgets;

/// <summary>
/// "Subscriptions" (FanficlySubscriptionsWidget on iOS): followed works and AO3
/// work subscriptions, most recently updated first. Small shows the latest one
/// and how many there are; medium lists the top three, each opening its work
/// through <c>fanficly://resume/&lt;id&gt;</c> like the Swift links (the saved
/// copy if it's in the library, else the live work page).
/// </summary>
public static class SubscriptionsWidget
{
    public const string DefinitionId = "Subscriptions";

    internal static WidgetContent Content(string size, IReadOnlyList<WidgetSubscriptionUpdate> updates) =>
        new(Template(size), Data(updates));

    public static string Template(string size) => WidgetCards.IsSmall(size) ? SmallTemplate : MediumTemplate;

    public static string Data(IReadOnlyList<WidgetSubscriptionUpdate> updates)
    {
        var culture = CultureInfo.CurrentCulture;
        return WidgetCards.Json(w =>
        {
            w.WriteStartObject();
            w.WriteBoolean("hasItems", updates.Count > 0);
            w.WriteString("url", WidgetCards.OpenAppUrl);
            // Small is one tap target: the latest update's work, or the app when empty.
            w.WriteString("cardUrl", updates.Count > 0 ? DeepLink.ResumeUri(updates[0].WorkId).AbsoluteUri : WidgetCards.OpenAppUrl);
            w.WriteString("cardTip", updates.Count > 0 ? $"Open {updates[0].Title}" : "Open Fanficly");
            if (updates.Count > 0)
            {
                var first = updates[0];
                w.WriteString("firstTitle", first.Title);
                w.WriteString("firstAuthor", $"By {first.Author}");
                w.WriteString("countText", WidgetCards.Count(updates.Count, "Update", "Updates"));
                w.WriteString("lastText", $"Last: Ch {first.ChapterCount.ToString(culture)}");
            }
            w.WriteStartArray("rows");
            for (var i = 0; i < Math.Min(3, updates.Count); i++)
            {
                var u = updates[i];
                w.WriteStartObject();
                w.WriteString("title", u.Title);
                w.WriteString("author", u.Author);
                w.WriteString("chapter", $"Ch {u.ChapterCount.ToString(culture)}");
                w.WriteString("url", DeepLink.ResumeUri(u.WorkId).AbsoluteUri);
                w.WriteString("tip", $"Open {u.Title}");
                w.WriteBoolean("separator", i > 0);
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteEndObject();
        });
    }

    private static readonly string MediumTemplate = WidgetCards.Card("${url}", "Open Fanficly", $$"""
        {{WidgetCards.Badge("UPDATES")}},
        {{WidgetCards.Empty("medium", "No Updates", "Everything is read", "${!hasItems}")}},
        { "type": "Container", "$when": "${hasItems}", "spacing": "Small", "items": [
          { "type": "Container", "$data": "${rows}", "separator": "${separator}", "spacing": "Small",
            "selectAction": { "type": "Action.OpenUrl", "url": "${url}", "tooltip": "${tip}" },
            "items": [
              { "type": "ColumnSet", "columns": [
                { "type": "Column", "width": "stretch", "items": [
                  { "type": "TextBlock", "text": "${title}", "weight": "Bolder", "wrap": false },
                  { "type": "TextBlock", "text": "${author}", "size": "Small", "isSubtle": true, "spacing": "None", "wrap": false } ] },
                { "type": "Column", "width": "auto", "verticalContentAlignment": "Center", "items": [
                  { "type": "TextBlock", "text": "${chapter}", "size": "Small", "weight": "Bolder", "color": "Accent", "wrap": false } ] }
              ] }
            ] }
        ] }
        """);

    private static readonly string SmallTemplate = WidgetCards.Card("${cardUrl}", "${cardTip}", $$"""
        {{WidgetCards.Badge("UPDATES")}},
        {{WidgetCards.Empty("small", "No Updates", "Everything is read", "${!hasItems}")}},
        { "type": "Container", "$when": "${hasItems}", "spacing": "Small", "items": [
          { "type": "TextBlock", "text": "${firstTitle}", "weight": "Bolder", "wrap": false },
          { "type": "TextBlock", "text": "${firstAuthor}", "size": "Small", "isSubtle": true, "spacing": "None", "wrap": false },
          { "type": "TextBlock", "text": "${countText}", "size": "Small", "weight": "Bolder", "spacing": "Medium", "wrap": false },
          { "type": "TextBlock", "text": "${lastText}", "size": "Small", "isSubtle": true, "spacing": "None", "wrap": false }
        ] }
        """);
}
