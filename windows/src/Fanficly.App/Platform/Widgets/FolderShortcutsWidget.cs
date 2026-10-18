using System.Globalization;
using Fanficly.Core;

namespace Fanficly.App.Platform.Widgets;

/// <summary>
/// "Folder Shortcuts" (FanficlyFolderShortcutWidget on iOS): the custom library
/// folders, newest first. Small shows one folder and its story count; medium
/// lists three. Each opens the Library on that folder
/// (<c>fanficly://library?folder=…</c>).
/// </summary>
public static class FolderShortcutsWidget
{
    public const string DefinitionId = "FolderShortcuts";

    internal static WidgetContent Content(string size, IReadOnlyList<WidgetFolderShortcut> folders) =>
        new(Template(size), Data(folders));

    public static string Template(string size) => WidgetCards.IsSmall(size) ? SmallTemplate : MediumTemplate;

    public static string Data(IReadOnlyList<WidgetFolderShortcut> folders)
    {
        var culture = CultureInfo.CurrentCulture;
        return WidgetCards.Json(w =>
        {
            w.WriteStartObject();
            w.WriteBoolean("hasItems", folders.Count > 0);
            w.WriteString("url", WidgetCards.OpenAppUrl);
            w.WriteString("cardUrl", folders.Count > 0 ? DeepLink.LibraryFolderUri(folders[0].Name).AbsoluteUri : WidgetCards.OpenAppUrl);
            w.WriteString("cardTip", folders.Count > 0 ? $"Open {folders[0].Name}" : "Open Fanficly");
            if (folders.Count > 0)
            {
                var first = folders[0];
                w.WriteString("firstName", first.Name);
                w.WriteString("firstCount", first.WorkCount.ToString(culture));
                w.WriteString("firstNoun", first.WorkCount == 1 ? "story" : "stories");
            }
            w.WriteStartArray("rows");
            for (var i = 0; i < Math.Min(3, folders.Count); i++)
            {
                var f = folders[i];
                w.WriteStartObject();
                w.WriteString("name", f.Name);
                w.WriteString("count", WidgetCards.Count(f.WorkCount, "story", "stories"));
                w.WriteString("url", DeepLink.LibraryFolderUri(f.Name).AbsoluteUri);
                w.WriteString("tip", $"Open {f.Name}");
                w.WriteBoolean("separator", i > 0);
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteEndObject();
        });
    }

    private static readonly string MediumTemplate = WidgetCards.Card("${url}", "Open Fanficly", $$"""
        {{WidgetCards.Badge("FOLDERS")}},
        {{WidgetCards.Empty("medium", "No Folders", "Organize works in app", "${!hasItems}")}},
        { "type": "Container", "$when": "${hasItems}", "spacing": "Small", "items": [
          { "type": "Container", "$data": "${rows}", "separator": "${separator}", "spacing": "Small",
            "selectAction": { "type": "Action.OpenUrl", "url": "${url}", "tooltip": "${tip}" },
            "items": [
              { "type": "ColumnSet", "columns": [
                { "type": "Column", "width": "auto", "verticalContentAlignment": "Center", "items": [
                  {{WidgetCards.Glyph(WidgetGlyphs.Folder, 16)}} ] },
                { "type": "Column", "width": "stretch", "verticalContentAlignment": "Center", "items": [
                  { "type": "TextBlock", "text": "${name}", "weight": "Bolder", "wrap": false } ] },
                { "type": "Column", "width": "auto", "verticalContentAlignment": "Center", "items": [
                  { "type": "TextBlock", "text": "${count}", "size": "Small", "weight": "Bolder", "isSubtle": true, "wrap": false } ] }
              ] }
            ] }
        ] }
        """);

    private static readonly string SmallTemplate = WidgetCards.Card("${cardUrl}", "${cardTip}", $$"""
        {{WidgetCards.Badge("FOLDERS")}},
        {{WidgetCards.Empty("small", "No Folders", "Organize works in app", "${!hasItems}")}},
        { "type": "Container", "$when": "${hasItems}", "spacing": "Small", "items": [
          { "type": "TextBlock", "text": "${firstName}", "weight": "Bolder", "wrap": false },
          { "type": "TextBlock", "text": "Library Folder", "size": "Small", "isSubtle": true, "spacing": "None", "wrap": false },
          { "type": "ColumnSet", "spacing": "Small", "columns": [
            { "type": "Column", "width": "auto", "verticalContentAlignment": "Bottom", "items": [
              { "type": "TextBlock", "text": "${firstCount}", "size": "ExtraLarge", "weight": "Bolder", "wrap": false } ] },
            { "type": "Column", "width": "stretch", "verticalContentAlignment": "Bottom", "items": [
              { "type": "TextBlock", "text": "${firstNoun}", "size": "Small", "weight": "Bolder", "isSubtle": true, "wrap": false } ] }
          ] }
        ] }
        """);
}
