using Fanficly.Core;

namespace Fanficly.App.Platform.Widgets;

/// <summary>
/// "Saved Searches" (FanficlySavedSearchesWidget on iOS): saved searches, then
/// saved filters. Small offers the newest with a Run Search pill; medium lists
/// three. Each runs its query in Search (<c>fanficly://search?query=…</c>; a
/// saved filter's query is its filters JSON, exactly as the Swift widget sends).
/// </summary>
public static class SavedSearchesWidget
{
    public const string DefinitionId = "SavedSearches";

    internal static WidgetContent Content(string size, IReadOnlyList<WidgetSavedSearch> searches) =>
        new(Template(size), Data(searches));

    public static string Template(string size) => WidgetCards.IsSmall(size) ? SmallTemplate : MediumTemplate;

    public static string Data(IReadOnlyList<WidgetSavedSearch> searches) => WidgetCards.Json(w =>
    {
        w.WriteStartObject();
        w.WriteBoolean("hasItems", searches.Count > 0);
        w.WriteString("url", WidgetCards.OpenAppUrl);
        w.WriteString("cardUrl", searches.Count > 0 ? DeepLink.SearchUri(searches[0].Query).AbsoluteUri : WidgetCards.OpenAppUrl);
        w.WriteString("cardTip", searches.Count > 0 ? $"Run {searches[0].Name}" : "Open Fanficly");
        if (searches.Count > 0)
        {
            var first = searches[0];
            w.WriteString("firstName", first.Name);
            w.WriteString("firstKind", first.IsFilter ? "Saved Filter" : "Saved Search");
        }
        w.WriteStartArray("rows");
        for (var i = 0; i < Math.Min(3, searches.Count); i++)
        {
            var s = searches[i];
            w.WriteStartObject();
            w.WriteString("name", s.Name);
            w.WriteString("kind", s.IsFilter ? "Filter" : "Search");
            w.WriteString("url", DeepLink.SearchUri(s.Query).AbsoluteUri);
            w.WriteString("tip", $"Run {s.Name}");
            w.WriteBoolean("separator", i > 0);
            w.WriteEndObject();
        }
        w.WriteEndArray();
        w.WriteEndObject();
    });

    private static readonly string MediumTemplate = WidgetCards.Card("${url}", "Open Fanficly", $$"""
        {{WidgetCards.Badge("SEARCHES")}},
        {{WidgetCards.Empty("medium", "No Searches", "Save search queries in app", "${!hasItems}")}},
        { "type": "Container", "$when": "${hasItems}", "spacing": "Small", "items": [
          { "type": "Container", "$data": "${rows}", "separator": "${separator}", "spacing": "Small",
            "selectAction": { "type": "Action.OpenUrl", "url": "${url}", "tooltip": "${tip}" },
            "items": [
              { "type": "ColumnSet", "columns": [
                { "type": "Column", "width": "auto", "verticalContentAlignment": "Center", "items": [
                  {{WidgetCards.Glyph(WidgetGlyphs.Magnifier, 14)}} ] },
                { "type": "Column", "width": "stretch", "verticalContentAlignment": "Center", "items": [
                  { "type": "TextBlock", "text": "${name}", "weight": "Bolder", "wrap": false } ] },
                { "type": "Column", "width": "auto", "verticalContentAlignment": "Center", "items": [
                  { "type": "TextBlock", "text": "${kind}", "size": "Small", "weight": "Bolder", "isSubtle": true, "wrap": false } ] }
              ] }
            ] }
        ] }
        """);

    private static readonly string SmallTemplate = WidgetCards.Card("${cardUrl}", "${cardTip}", $$"""
        {{WidgetCards.Badge("SEARCHES")}},
        {{WidgetCards.Empty("small", "No Searches", "Save search queries in app", "${!hasItems}")}},
        { "type": "Container", "$when": "${hasItems}", "spacing": "Small", "items": [
          { "type": "TextBlock", "text": "${firstName}", "weight": "Bolder", "wrap": false },
          { "type": "TextBlock", "text": "${firstKind}", "size": "Small", "isSubtle": true, "spacing": "None", "wrap": false },
          { "type": "Container", "style": "emphasis", "spacing": "Medium", "items": [
            { "type": "ColumnSet", "columns": [
              { "type": "Column", "width": "auto", "verticalContentAlignment": "Center", "items": [
                {{WidgetCards.Glyph(WidgetGlyphs.Magnifier, 12)}} ] },
              { "type": "Column", "width": "stretch", "verticalContentAlignment": "Center", "items": [
                { "type": "TextBlock", "text": "Run Search", "size": "Small", "weight": "Bolder", "wrap": false } ] }
            ] }
          ] }
        ] }
        """);
}
