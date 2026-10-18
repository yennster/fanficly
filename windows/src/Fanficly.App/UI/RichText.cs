using Fanficly.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.UI.Text;

namespace Fanficly.App.UI;

/// <summary>
/// Draws Core's <see cref="ReaderRichText"/> (AO3 HTML converted to styled runs)
/// as WinUI inlines: bold, italic, underline, strikethrough and links.
/// </summary>
public static class RichText
{
    public static void Fill(InlineCollection inlines, ReaderRichText text, Brush? linkForeground = null)
    {
        inlines.Clear();
        foreach (var run in text.Runs)
        {
            if (run.Text.Length == 0) continue;
            var r = new Run { Text = run.Text };
            if (run.IsBold) r.FontWeight = FontWeights.SemiBold;
            if (run.IsItalic) r.FontStyle = FontStyle.Italic;
            var decorations = TextDecorations.None;
            if (run.IsUnderlined) decorations |= TextDecorations.Underline;
            if (run.IsStrikethrough) decorations |= TextDecorations.Strikethrough;
            if (decorations != TextDecorations.None) r.TextDecorations = decorations;
            if (run.Link is { } link && (link.Scheme == "https" || link.Scheme == "http"))
            {
                var hyperlink = new Hyperlink { NavigateUri = link };
                if (linkForeground is not null) hyperlink.Foreground = linkForeground;
                hyperlink.Inlines.Add(r);
                inlines.Add(hyperlink);
            }
            else
            {
                inlines.Add(r);
            }
        }
    }

    /// <summary>A text block for an AO3 summary / comment body: plain text at
    /// once, formatted text when the (cached) conversion finishes.</summary>
    public static TextBlock Html(string html, Theme.Style style = Theme.Style.Callout, int maxLines = 0, Brush? foreground = null, bool selectable = false)
    {
        var block = UI.Text(HTMLText.FallbackText(html), style, foreground, maxLines: maxLines, selectable: selectable);
        _ = FillLaterAsync(block, html);
        return block;
    }

    private static async Task FillLaterAsync(TextBlock block, string html)
    {
        try
        {
            var rich = await HTMLText.ConvertAsync(html);
            if (rich.IsEmpty) return;
            Fill(block.Inlines, rich, Theme.Accent);
        }
        catch { }
    }
}
