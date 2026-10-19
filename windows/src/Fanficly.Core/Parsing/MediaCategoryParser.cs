using System.Text.RegularExpressions;
using AngleSharp.Dom;

namespace Fanficly.Core;

/// <summary>Parses a media category's fandom list (<c>/media/&lt;category&gt;/fandoms</c>).</summary>
public static partial class MediaCategoryParser
{
    public static IReadOnlyList<BrowseFandom> Parse(string html)
    {
        var doc = HtmlDom.Parse(html);
        AO3PageCheck.RejectLoginPage(doc);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var results = new List<BrowseFandom>();

        foreach (var link in doc.Select("a[href^='/tags/']"))
        {
            if (!link.Attr("href").EndsWith("/works", StringComparison.Ordinal)) continue;
            var raw = link.Text().TrimSwiftWhitespaces();
            if (raw.Length == 0) continue;

            var canonical = CanonicalizeFandomName(raw);
            // AO3 renders the work count after the link, e.g.
            // `<a ...>Harry Potter - J. K. Rowling</a> (123456)`. Read it from the
            // enclosing element's text so "Popular" can rank by it.
            var containerText = link.ParentElement is { } parent ? parent.Text() : raw;
            var count = TrailingCount(containerText);
            if (seen.Add(canonical)) results.Add(new BrowseFandom(canonical, canonical, count));
        }
        if (results.Count == 0 && !IsFandomsPage(doc)) throw AO3Exception.ParseFailed("Not a fandoms page");
        return results.OrderBy(f => f.CanonicalName, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    /// <summary>The fandoms index shell, present even when a category has none: its
    /// <c>fandoms-index</c> main div, the alphabetised <c>&lt;ol&gt;</c>, or the "No
    /// fandoms found" heading it shows instead.</summary>
    private static bool IsFandomsPage(IDocument doc) =>
        AO3PageCheck.MainHasClass(doc, "fandoms-index")
        || doc.SelectFirst("ol.fandom.index") is not null
        || doc.Select("h3.heading").Any(h => h.Text().Contains("No fandoms found", StringComparison.Ordinal));

    /// <summary>The number inside the trailing <c>(…)</c> of a fandom line, e.g.
    /// "Harry Potter - J. K. Rowling (123,456)" → 123456. Null when absent.</summary>
    public static int? TrailingCount(string text)
    {
        var open = text.LastIndexOf('(');
        if (open < 0) return null;
        var close = text.IndexOf(')', open);
        if (close < 0) return null;
        var digits = new string(text[(open + 1)..close].Where(char.IsDigit).ToArray());
        return digits.Length == 0 ? null : HtmlDom.ParseSwiftInt(digits);
    }

    [GeneratedRegex(@"\s+")]
    private static partial Regex WhitespaceRun();

    private static string CanonicalizeFandomName(string s) =>
        WhitespaceRun().Replace(s.Replace(' ', ' '), " ").TrimSwiftWhitespaces();
}

/// <summary>Parses the faceted filter sidebar of a works listing
/// (<c>/tags/&lt;tag&gt;/works</c>): the most-used relationships, characters, fandoms,
/// and additional tags within that scope, each with a count. Drives the live
/// "Popular ships / characters" lists.</summary>
public static class WorkFiltersParser
{
    public static AO3WorkFilters Parse(string html)
    {
        var doc = HtmlDom.Parse(html);
        AO3PageCheck.RejectLoginPage(doc);
        var filters = new AO3WorkFilters(
            Facets(doc, "relationship"),
            Facets(doc, "character"),
            Facets(doc, "fandom"),
            Facets(doc, "freeform"));
        // No facets is genuine on a tag with no works (AO3 drops the filter form
        // but still renders the works index); anywhere else it's drift.
        if (filters.Relationships.Count == 0 && filters.Characters.Count == 0
            && filters.Fandoms.Count == 0 && filters.Freeforms.Count == 0 && !IsWorksIndex(doc))
            throw AO3Exception.ParseFailed("Not a works listing");
        return filters;
    }

    private static bool IsWorksIndex(IDocument doc) =>
        AO3PageCheck.MainHasClass(doc, "works-index")
        || doc.SelectFirst("form#work-filters, ol.work.index") is not null;

    /// <summary>Each facet is a checkbox label in the sidebar's "Include" half. Live
    /// AO3 ids are <c>include_work_search_&lt;kind&gt;_ids_&lt;tag id&gt;</c> with the name and
    /// count together in a plain span — <c>&lt;span&gt;Sherlock Holmes/John Watson
    /// (57746)&lt;/span&gt;</c> — while older markup used <c>include_&lt;kind&gt;_ids_&lt;n&gt;</c>
    /// with the count in <c>span.count</c>; match both. Must stay anchored on
    /// <c>include_</c>: the "Exclude" half repeats every tag under
    /// <c>exclude_work_search_…</c> ids, and a bare contains-match would return each
    /// facet twice.</summary>
    private static List<AO3TagFacet> Facets(IDocument doc, string kind)
    {
        var result = new List<AO3TagFacet>();
        foreach (var label in doc.Select($"label[for^='include_'][for*='_{kind}_ids_']"))
        {
            var full = label.Text().Trim();
            var name = full;
            var count = 0;
            // Trailing "(N)" is the work count; only strip it when it parses as a
            // number, since tag names themselves can end in parentheses
            // ("Sherlock (BBC TV 2010)" has a count, "Ocean's (Movies)" may not).
            var open = full.LastIndexOf('(');
            if (open >= 0 && MediaCategoryParser.TrailingCount(full) is { } parsed)
            {
                count = parsed;
                name = full[..open].Trim();
            }
            if (name.Length == 0) continue;
            result.Add(new AO3TagFacet(name, count));
        }
        return result;
    }
}
