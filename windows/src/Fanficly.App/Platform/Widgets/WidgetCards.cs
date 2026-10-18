using System.Globalization;
using System.Text.Json;

namespace Fanficly.App.Platform.Widgets;

/// <summary>What one widget shows: its Adaptive Card template, the data bound
/// into it, and (optionally) state Windows keeps with the widget between updates.</summary>
internal readonly record struct WidgetContent(string Template, string Data, string? CustomState = null);

/// <summary>Pieces the widget cards share (the Swift widgets' common header row
/// and empty state).</summary>
internal static class WidgetCards
{
    /// <summary>Opens the app without a destination — the Swift widgets without
    /// a <c>widgetURL</c> just open Fanficly. (<c>DeepLink.Parse</c> doesn't know
    /// this host, so the app comes to the front and stays where it was.)</summary>
    public const string OpenAppUrl = "fanficly://open";

    public static bool IsSmall(string size) => size == "small";

    public static string Json(Action<Utf8JsonWriter> write)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream)) write(w);
        return System.Text.Encoding.UTF8.GetString(stream.ToArray());
    }

    /// <summary>"1 story" / "3 stories" style counts.</summary>
    public static string Count(int n, string one, string many) =>
        $"{n.ToString(CultureInfo.CurrentCulture)} {(n == 1 ? one : many)}";

    /// <summary>The badge the Swift widgets show at the top right ("Streak",
    /// "Updates", …), drawn as LastRead's accent caption. The board's own
    /// header already names the app, so the "Fanficly" wordmark isn't repeated.</summary>
    public static string Badge(string text) =>
        $$"""{ "type": "TextBlock", "text": "{{text}}", "size": "Small", "weight": "Bolder", "color": "Accent", "wrap": false }""";

    /// <summary>The empty state: a headline and one subtle line.</summary>
    public static string Empty(string size, string title, string detail, string when) => $$"""
        { "type": "Container", "$when": "{{when}}", "spacing": "Small", "items": [
          { "type": "TextBlock", "text": "{{title}}", "size": "{{(IsSmall(size) ? "Default" : "Medium")}}", "weight": "Bolder", "wrap": true },
          { "type": "TextBlock", "text": "{{detail}}", "size": "Small", "isSubtle": true, "spacing": "None", "wrap": true }
        ] }
        """;

    /// <summary>A small inline glyph (see <see cref="WidgetGlyphs"/>), decorative.</summary>
    public static string Glyph(string dataUri, int px) =>
        $$"""{ "type": "Image", "url": "{{dataUri}}", "width": "{{px}}px", "height": "{{px}}px", "altText": "" }""";

    public static string Card(string selectUrl, string tooltip, string body) => $$"""
        {
          "type": "AdaptiveCard", "$schema": "http://adaptivecards.io/schemas/adaptive-card.json", "version": "1.5",
          "selectAction": { "type": "Action.OpenUrl", "url": "{{selectUrl}}", "tooltip": "{{tooltip}}" },
          "body": [ {{body}} ]
        }
        """;
}
