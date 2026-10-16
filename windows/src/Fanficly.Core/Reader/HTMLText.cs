using System.Text.RegularExpressions;

namespace Fanficly.Core;

/// <summary>The pure half of the Swift <c>HTMLText</c> view (summaries, notes,
/// comments): a quick plain-text fallback to show at once, and the cached rich
/// conversion (<see cref="HTMLToAttributed.Convert"/>, links enabled) that
/// replaces it once ready.</summary>
public static partial class HTMLText
{
    /// <summary>A cheap plain-text rendering shown until the rich conversion lands:
    /// <c>&lt;br&gt;</c> → newline, <c>&lt;/p&gt;</c> → blank line, other tags
    /// stripped, the common entities decoded, trimmed.</summary>
    public static string FallbackText(string html)
    {
        var temp = html.Replace("\r\n", "\n");
        // Replace paragraph closures and breaks with newlines.
        temp = BreakRegex().Replace(temp, "\n");
        temp = ParagraphCloseRegex().Replace(temp, "\n\n");
        // Strip other HTML tags.
        temp = TagRegex().Replace(temp, "");
        // Decode common HTML entities.
        temp = temp.Replace("&amp;", "&")
                   .Replace("&lt;", "<")
                   .Replace("&gt;", ">")
                   .Replace("&quot;", "\"")
                   .Replace("&apos;", "'")
                   .Replace("&#39;", "'")
                   .Replace("&nbsp;", " ");
        return temp.Trim();
    }

    /// <summary>The rich text to show (cached by <see cref="HTMLToAttributed"/>).</summary>
    public static ReaderRichText Convert(string html) => HTMLToAttributed.Convert(html);

    /// <summary><see cref="Convert"/> off the UI thread, as the Swift view's
    /// detached <c>.task(id: html)</c> does.</summary>
    public static Task<ReaderRichText> ConvertAsync(string html, CancellationToken cancellationToken = default) =>
        Task.Run(() => HTMLToAttributed.Convert(html), cancellationToken);

    [GeneratedRegex(@"<br\s*/?>", RegexOptions.IgnoreCase)]
    private static partial Regex BreakRegex();

    [GeneratedRegex("</p>", RegexOptions.IgnoreCase)]
    private static partial Regex ParagraphCloseRegex();

    [GeneratedRegex("<[^>]+>")]
    private static partial Regex TagRegex();
}
