using System.Globalization;
using System.Text;
using AngleSharp.Dom;
using AngleSharp.Html.Parser;

namespace Fanficly.Core;

/// <summary>Shared AngleSharp helpers that reproduce the SwiftSoup (jsoup) calls the
/// Swift parsers make, so the ported parsers read the same strings out of the
/// same markup. Selectors that jsoup accepts unquoted (<c>a[href^=/tags/]</c>) must
/// be written quoted here (<c>a[href^='/tags/']</c>); AngleSharp follows the CSS
/// grammar strictly.</summary>
public static class HtmlDom
{
    private static readonly HtmlParser Parser = new();

    /// <summary>Tags SwiftSoup treats as block-level: <see cref="Text"/> puts a space
    /// before each one (as at a <c>&lt;br&gt;</c>). Unknown tags are inline.</summary>
    private static readonly HashSet<string> BlockTags = new(StringComparer.Ordinal)
    {
        "html", "head", "body", "frameset", "script", "noscript", "style", "meta", "link", "title", "frame",
        "noframes", "noembed", "section", "nav", "aside", "hgroup", "header", "footer", "p", "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "pre", "listing", "div", "blockquote", "hr", "address", "figure", "figcaption", "form", "fieldset",
        "center", "dir", "applet", "marquee", "ins",
        "del", "s", "dl", "dt", "dd", "li", "table", "caption", "thead", "tfoot", "tbody", "colgroup", "col", "tr", "th",
        "td", "video", "audio", "canvas", "details", "menu", "plaintext", "template", "article", "main",
        "svg", "math",
    };

    /// <summary>Tags whose text keeps its whitespace verbatim in <see cref="Text"/>.</summary>
    private static readonly HashSet<string> PreserveWhitespaceTags = new(StringComparer.Ordinal)
    {
        "pre", "plaintext", "title", "textarea",
    };

    /// <summary>Parses an HTML string (a full page or a fragment) into a document,
    /// HTML5-style, as <c>SwiftSoup.parse</c> does.</summary>
    public static IDocument Parse(string html) => Parser.ParseDocument(html);

    /// <summary>Every match of <paramref name="selector"/> under <paramref name="root"/>, in
    /// document order. Like jsoup's <c>Element.select</c>, the root element itself is
    /// included when it matches.</summary>
    public static IReadOnlyList<IElement> Select(this IParentNode root, string selector)
    {
        var found = root.QuerySelectorAll(selector);
        if (root is IElement el && el.Matches(selector))
        {
            var list = new List<IElement>(found.Length + 1) { el };
            list.AddRange(found);
            return list;
        }
        return found.ToList();
    }

    /// <summary>The first match of <paramref name="selector"/> (root included), or null.</summary>
    public static IElement? SelectFirst(this IParentNode root, string selector)
    {
        if (root is IElement el && el.Matches(selector)) return el;
        return root.QuerySelector(selector);
    }

    /// <summary>The element's text exactly as SwiftSoup's <c>Element.text()</c> produces
    /// it: whitespace runs (ASCII whitespace and NBSP) collapse to one space, a
    /// space separates block-level elements and stands in for <c>&lt;br&gt;</c>, text
    /// inside <c>pre</c>/<c>textarea</c>/<c>title</c> keeps its whitespace, script and
    /// style contents are left out, and the result is trimmed.</summary>
    public static string Text(this INode? node)
    {
        if (node is null) return "";
        var accum = new StringBuilder();
        if (node is IText t)
        {
            AppendText(accum, t);
        }
        else
        {
            foreach (var child in node.ChildNodes) Collect(child, accum);
        }
        return accum.ToString().Trim(' ', '\t', '\n', '\f', '\r');
    }

    private static void Collect(INode node, StringBuilder accum)
    {
        switch (node)
        {
            case IText text:
                AppendText(accum, text);
                break;
            case IElement element:
                var name = element.LocalName;
                if (accum.Length > 0 && (BlockTags.Contains(name) || name == "br") && !LastCharIsSpace(accum))
                    accum.Append(' ');
                // Script/style bodies are data nodes in SwiftSoup, never text.
                if (name is "script" or "style") break;
                foreach (var child in element.ChildNodes) Collect(child, accum);
                break;
        }
    }

    private static void AppendText(StringBuilder accum, IText text)
    {
        if (text.ParentElement is { LocalName: "script" or "style" }) return;
        var data = text.Data;
        if (PreservesWhitespace(text.ParentElement))
        {
            accum.Append(data);
            return;
        }
        var stripLeading = accum.Length == 0 || LastCharIsSpace(accum);
        var lastWasWhite = false;
        var reachedNonWhite = false;
        foreach (var c in data)
        {
            if (IsTextWhitespace(c))
            {
                if ((stripLeading && !reachedNonWhite) || lastWasWhite) continue;
                accum.Append(' ');
                lastWasWhite = true;
            }
            else
            {
                accum.Append(c);
                lastWasWhite = false;
                reachedNonWhite = true;
            }
        }
    }

    private static bool PreservesWhitespace(IElement? element)
    {
        for (var e = element; e is not null; e = e.ParentElement)
            if (PreserveWhitespaceTags.Contains(e.LocalName)) return true;
        return false;
    }

    private static bool IsTextWhitespace(char c) => c is ' ' or '\t' or '\n' or '\f' or '\r' or ' ';

    private static bool LastCharIsSpace(StringBuilder sb) => sb.Length > 0 && sb[^1] == ' ';

    /// <summary>The element's inner HTML, trimmed (SwiftSoup's <c>Element.html()</c>).
    /// SwiftSoup also pretty-prints; AngleSharp serializes the markup as parsed,
    /// which renders the same.</summary>
    public static string InnerHtml(this IElement? element) => element?.InnerHtml.Trim() ?? "";

    /// <summary>An attribute's value, or "" when absent (SwiftSoup's <c>attr(_:)</c>).</summary>
    public static string Attr(this IElement? element, string name) => element?.GetAttribute(name) ?? "";

    /// <summary>Swift's <c>Int(String)</c>: an optional sign then ASCII digits, nothing
    /// else (no whitespace, no separators); null when it doesn't parse or overflows.</summary>
    public static int? ParseSwiftInt(string? s)
    {
        if (string.IsNullOrEmpty(s)) return null;
        var start = s[0] is '+' or '-' ? 1 : 0;
        if (start == s.Length) return null;
        for (var i = start; i < s.Length; i++)
            if (!char.IsAsciiDigit(s[i])) return null;
        return int.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) ? n : null;
    }

    /// <summary>Splits on <paramref name="separator"/> dropping empty pieces, like Swift's
    /// <c>split(separator:)</c>.</summary>
    internal static string[] SwiftSplit(this string s, char separator) =>
        s.Split(separator, StringSplitOptions.RemoveEmptyEntries);

    /// <summary>Swift's <c>trimmingCharacters(in: .whitespaces)</c>: spaces and tabs
    /// (any Unicode space separator), but not line breaks.</summary>
    internal static string TrimSwiftWhitespaces(this string s)
    {
        static bool IsSpace(char c) => c == '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;
        int start = 0, end = s.Length;
        while (start < end && IsSpace(s[start])) start++;
        while (end > start && IsSpace(s[end - 1])) end--;
        return s[start..end];
    }

    /// <summary>The pagination numbers of an AO3 (Rails will_paginate) listing.
    /// AO3 marks the current page with a "current" class that, depending on the
    /// page, lands on the <c>&lt;li&gt;</c> itself OR on an inner <c>&lt;span&gt;</c>/<c>&lt;em&gt;</c>
    /// (<c>&lt;li&gt;&lt;span class="current"&gt;2&lt;/span&gt;&lt;/li&gt;</c>, where the
    /// <c>&lt;li&gt;</c> has no class). Both are checked, or the current page sticks at 1
    /// and "Load more" keeps re-requesting the same page.</summary>
    internal static (int Current, int Total) Pagination(IDocument doc, string itemSelector = "ol.pagination li")
    {
        var current = 1;
        var total = 1;
        foreach (var li in doc.Select(itemSelector))
        {
            if (ParseSwiftInt(li.Text().TrimSwiftWhitespaces()) is not { } num) continue;
            total = Math.Max(total, num);
            var liIsCurrent = li.Attr("class").Contains("current", StringComparison.Ordinal);
            var innerIsCurrent = li.Select(".current").Count > 0;
            if (liIsCurrent || innerIsCurrent) current = num;
        }
        return (current, total);
    }

    /// <summary>AO3's "12/20" chapter fraction: "?" as the total means unknown (null);
    /// a missing total means the work is as long as it is.</summary>
    internal static (int Current, int? Total) ParseChapterFraction(string s)
    {
        var parts = s.SwiftSplit('/').Select(p => p.TrimSwiftWhitespaces()).ToArray();
        var current = ParseSwiftInt(parts.Length > 0 ? parts[0] : "1") ?? 1;
        int? total;
        if (parts.Length > 1 && parts[1] == "?") total = null;
        else if (parts.Length > 1 && ParseSwiftInt(parts[1]) is { } n) total = n;
        else total = current;
        return (current, total);
    }

    /// <summary>Parses a date in the given fixed format (en_US_POSIX) as local
    /// midnight, like a Swift <c>DateFormatter</c> in the current time zone. Null when
    /// empty or unparseable.</summary>
    internal static DateTimeOffset? ParseDate(string s, string format)
    {
        var trimmed = s.TrimSwiftWhitespaces();
        if (trimmed.Length == 0) return null;
        if (!DateTime.TryParseExact(trimmed, format, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d))
            return null;
        return new DateTimeOffset(DateTime.SpecifyKind(d, DateTimeKind.Local));
    }
}
