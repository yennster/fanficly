using System.Globalization;
using System.Text;

namespace Fanficly.Core;

/// <summary>
/// Find in this work (#183; Swift: <c>WorkFind</c>): searches the loaded chapters'
/// text on the PC (nothing goes to AO3) and lists the paragraphs that hold the
/// words, with their chapter. Paragraph indices are the reader's own
/// (<see cref="HTMLToAttributed.SpeechParagraphs"/> is index-aligned with the
/// rendered paragraphs), so a match is a <see cref="ReadingAnchor"/> every reading
/// mode can show.
/// </summary>
public static class WorkFind
{
    /// <summary>One chapter's text, a string per rendered paragraph (an image slot
    /// or scene break is "").</summary>
    public sealed record Chapter(int Index, string Title, IReadOnlyList<string> Paragraphs);

    /// <summary>One paragraph holding the words. Several matches in one paragraph
    /// are one result, since choosing either shows the same paragraph.</summary>
    /// <param name="Snippet">The paragraph's text around the first match, "…" where it's cut.</param>
    /// <param name="HighlightStart">Where the words start in <paramref name="Snippet"/> (UTF-16).</param>
    /// <param name="HighlightLength">Their length in <paramref name="Snippet"/>.</param>
    /// <param name="Count">How many times the words appear in this paragraph.</param>
    public sealed record Match(int Chapter, int Paragraph, string Snippet, int HighlightStart, int HighlightLength, int Count)
    {
        public ReadingAnchor Anchor => new(Chapter, Paragraph);
    }

    public sealed record Result(IReadOnlyList<Match> Matches, bool Truncated, int Total)
    {
        public static readonly Result Empty = new([], false, 0);
    }

    /// <summary>The most paragraphs listed: a one-letter search in a long work would
    /// otherwise list tens of thousands of rows.</summary>
    public const int Limit = 500;

    /// <summary>Characters of context kept before the match in a snippet.</summary>
    public const int LeadingContext = 40;

    /// <summary>The longest snippet, in characters.</summary>
    public const int SnippetLength = 140;

    /// <summary>The chapters' paragraphs as the reader renders them (the conversion
    /// is cached). Safe off the UI thread.</summary>
    public static IReadOnlyList<Chapter> Chapters(IEnumerable<AO3ChapterPayload> payloads, bool includeImages) =>
        payloads.Select(c => new Chapter(c.Index, c.Title, HTMLToAttributed.SpeechParagraphs(c.BodyHtml, includeImages))).ToList();

    /// <summary>Curly quotes match straight ones (fics use ’ where a keyboard types
    /// '), dashes match a hyphen and a no-break space a space. Every replacement
    /// swaps one UTF-16 unit for one, so offsets in the folded text are offsets in
    /// the original too.</summary>
    public static string Fold(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (var ch in text)
        {
            sb.Append(ch switch
            {
                '‘' or '’' or '‛' or '′' => '\'',
                '“' or '”' or '‟' or '″' => '"',
                '–' or '—' => '-',
                ' ' => ' ',
                _ => ch,
            });
        }
        return sb.ToString();
    }

    /// <summary>The query as searched: trimmed and folded; null when there's nothing to find.</summary>
    public static string? NormalizedQuery(string? query)
    {
        var trimmed = query?.Trim() ?? "";
        // Only marks the search ignores (a lone accent, a soft hyphen) would
        // match everywhere with nothing to show.
        var findable = trimmed.Any(c => CharUnicodeInfo.GetUnicodeCategory(c) is not
            (UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark or UnicodeCategory.Format));
        return findable ? Fold(trimmed) : null;
    }

    /// <summary>Case, accents and width don't matter (Swift's
    /// <c>.caseInsensitive, .diacriticInsensitive, .widthInsensitive</c>).</summary>
    private const CompareOptions Options =
        CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace | CompareOptions.IgnoreWidth | CompareOptions.IgnoreKanaType;

    private static readonly CompareInfo Compare = CultureInfo.InvariantCulture.CompareInfo;

    /// <summary>The first match of <paramref name="needle"/> in <paramref name="text"/>
    /// at or after <paramref name="from"/>: its start and length, or -1.</summary>
    private static (int Start, int Length) IndexOf(string text, string needle, int from)
    {
        if (from >= text.Length) return (-1, 0);
        var index = Compare.IndexOf(text.AsSpan(from), needle.AsSpan(), Options, out var length);
        return index < 0 ? (-1, 0) : (from + index, length);
    }

    /// <summary>Every paragraph holding <paramref name="query"/>, in reading order.</summary>
    public static Result Search(string? query, IEnumerable<Chapter> chapters, int limit = Limit)
    {
        if (NormalizedQuery(query) is not { } needle) return Result.Empty;
        var matches = new List<Match>();
        var truncated = false;
        var total = 0;
        foreach (var chapter in chapters.OrderBy(c => c.Index))
        {
            for (var p = 0; p < chapter.Paragraphs.Count; p++)
            {
                var paragraph = chapter.Paragraphs[p];
                if (paragraph.Length == 0) continue;
                var folded = Fold(paragraph);
                var (start, length) = IndexOf(folded, needle, 0);
                if (start < 0 || length == 0) continue;
                var count = 1;
                var next = start + Math.Max(length, 1);
                while (IndexOf(folded, needle, next) is { Start: >= 0 } more)
                {
                    count++;
                    next = more.Start + Math.Max(more.Length, 1);
                }
                total += count;
                if (matches.Count >= limit)
                {
                    truncated = true;
                    continue;
                }
                var (snippet, highlightStart) = Snippet(paragraph, start, length);
                matches.Add(new Match(chapter.Index, p, snippet, highlightStart, length, count));
            }
        }
        return new Result(matches, truncated, total);
    }

    /// <summary><paramref name="paragraph"/> cut to about <see cref="SnippetLength"/>
    /// characters around the match, starting at a word, with "…" where text was left
    /// out. Returns the snippet and where the match starts in it.</summary>
    public static (string Snippet, int HighlightStart) Snippet(string paragraph, int matchStart, int matchLength)
    {
        var from = Math.Max(0, matchStart - LeadingContext);
        // Start at a word, not mid-way through one.
        if (from > 0)
        {
            while (from < matchStart && !char.IsWhiteSpace(paragraph[from - 1])) from++;
            // Never split a surrogate pair.
            if (from < paragraph.Length && char.IsLowSurrogate(paragraph[from])) from++;
        }
        var to = Math.Min(paragraph.Length, Math.Max(matchStart + matchLength, from + SnippetLength));
        if (to < paragraph.Length && to > 0 && char.IsHighSurrogate(paragraph[to - 1])) to++;
        var slice = paragraph[from..to];
        var leading = slice.Length - slice.TrimStart().Length;
        var body = slice.Trim();
        var prefix = from > 0 ? "…" : "";
        var suffix = to < paragraph.Length ? "…" : "";
        return (prefix + body + suffix, prefix.Length + (matchStart - from) - leading);
    }

    /// <summary>A chapter's name as the reader's menus show it.</summary>
    public static string ChapterLabel(int index, string title) =>
        title.Length == 0 ? $"Chapter {index}" : $"Chapter {index}: {title}";
}
