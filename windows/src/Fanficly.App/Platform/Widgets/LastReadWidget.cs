using System.Text.Json;
using Fanficly.Core;

namespace Fanficly.App.Platform.Widgets;

/// <summary>
/// The "Continue reading" widget's Adaptive Card: the last-read story's title,
/// author and a progress bar (FanficlyWidget on iOS). Tapping it opens the
/// story where you left off through the fanficly://resume route.
/// </summary>
public static class LastReadWidget
{
    public const string DefinitionId = "LastRead";

    public static string Template(string size) => size == "small" ? SmallTemplate : MediumTemplate;

    /// <summary>The card's data for the current last-read story (or the empty state).</summary>
    public static string Data(WidgetStoryProgress? story)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream))
        {
            w.WriteStartObject();
            if (story is null)
            {
                w.WriteBoolean("hasStory", false);
                w.WriteString("url", "fanficly://search");
            }
            else
            {
                var pct = (int)Math.Round(story.ClampedProgress * 100);
                w.WriteBoolean("hasStory", true);
                w.WriteString("title", story.Title);
                w.WriteString("author", story.Author.Length > 0 ? $"by {story.Author}" : "");
                w.WriteString("percent", pct >= 100 ? "Finished" : $"{pct}% read");
                // Two weighted columns draw the bar; a zero weight would hide a column entirely.
                w.WriteNumber("done", Math.Max(1, pct));
                w.WriteNumber("left", Math.Max(1, 100 - pct));
                w.WriteString("url", DeepLink.ResumeUri(story.Id, story.Chapter, story.Paragraph).ToString());
            }
            w.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(stream.ToArray());
    }

    private const string ProgressBar = """
        {
          "type": "ColumnSet", "spacing": "Small", "minHeight": "6px",
          "columns": [
            { "type": "Column", "width": "${done}", "style": "accent", "minHeight": "6px", "items": [] },
            { "type": "Column", "width": "${left}", "style": "emphasis", "minHeight": "6px", "items": [] }
          ]
        }
        """;

    private static readonly string MediumTemplate = $$"""
        {
          "type": "AdaptiveCard", "$schema": "http://adaptivecards.io/schemas/adaptive-card.json", "version": "1.5",
          "selectAction": { "type": "Action.OpenUrl", "url": "${url}", "tooltip": "Open in Fanficly" },
          "body": [
            { "type": "TextBlock", "text": "CONTINUE READING", "size": "Small", "weight": "Bolder", "color": "Accent", "$when": "${hasStory}" },
            { "type": "TextBlock", "text": "${title}", "size": "Large", "weight": "Bolder", "wrap": true, "maxLines": 2, "fontType": "Default", "$when": "${hasStory}" },
            { "type": "TextBlock", "text": "${author}", "isSubtle": true, "spacing": "None", "wrap": false, "$when": "${hasStory}" },
            { "type": "Container", "spacing": "Medium", "$when": "${hasStory}", "items": [ {{ProgressBar}},
              { "type": "TextBlock", "text": "${percent}", "size": "Small", "isSubtle": true, "spacing": "Small" } ] },
            { "type": "TextBlock", "text": "Nothing read yet", "size": "Medium", "weight": "Bolder", "$when": "${!hasStory}" },
            { "type": "TextBlock", "text": "Open a story in Fanficly and it shows up here, ready to pick up where you left off.", "wrap": true, "isSubtle": true, "$when": "${!hasStory}" }
          ]
        }
        """;

    private static readonly string SmallTemplate = $$"""
        {
          "type": "AdaptiveCard", "$schema": "http://adaptivecards.io/schemas/adaptive-card.json", "version": "1.5",
          "selectAction": { "type": "Action.OpenUrl", "url": "${url}", "tooltip": "Open in Fanficly" },
          "body": [
            { "type": "TextBlock", "text": "${title}", "weight": "Bolder", "wrap": true, "maxLines": 3, "$when": "${hasStory}" },
            { "type": "TextBlock", "text": "${author}", "isSubtle": true, "size": "Small", "spacing": "None", "$when": "${hasStory}" },
            { "type": "Container", "spacing": "Small", "$when": "${hasStory}", "items": [ {{ProgressBar}},
              { "type": "TextBlock", "text": "${percent}", "size": "Small", "isSubtle": true, "spacing": "Small" } ] },
            { "type": "TextBlock", "text": "Nothing read yet", "weight": "Bolder", "wrap": true, "$when": "${!hasStory}" }
          ]
        }
        """;
}
