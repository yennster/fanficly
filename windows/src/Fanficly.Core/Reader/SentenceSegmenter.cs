using System.Globalization;

namespace Fanficly.Core;

/// <summary>Unicode sentence boundaries (UAX #29, the rules ICU and Foundation's
/// <c>enumerateSubstrings(options: .bySentences)</c> follow), for splitting a
/// paragraph into the sentence atoms page-by-page packs. .NET has no public
/// sentence break iterator, so this implements the default rules:
/// a sentence ends after a terminator, any closing punctuation and spaces, and
/// one paragraph separator \u2014 except "e.g. lower", "3.5", "U.S.A" and a
/// terminator followed by a comma or another terminator (SB6\u2013SB8a). Each
/// sentence keeps its trailing spaces.</summary>
internal static class SentenceSegmenter
{
    private enum Kind { Other, ParaSep, Sp, Lower, Upper, OLetter, Numeric, ATerm, STerm, Close, SContinue, Extend }

    /// <summary>The <c>[start, end)</c> ranges of each sentence, covering the whole string.</summary>
    public static IEnumerable<(int Start, int End)> Sentences(string text)
    {
        var start = 0;
        foreach (var boundary in Boundaries(text))
        {
            yield return (start, boundary);
            start = boundary;
        }
    }

    private static List<int> Boundaries(string s)
    {
        var result = new List<int>();
        var n = s.Length;
        var i = 0;
        while (i < n)
        {
            var k = KindAt(s, i);
            if (k == Kind.ParaSep)
            {
                // SB3: CR \u00D7 LF; SB4: break after a paragraph separator.
                var end = s[i] == '\r' && i + 1 < n && s[i + 1] == '\n' ? i + 2 : i + 1;
                result.Add(end);
                i = end;
                continue;
            }
            if (k is not (Kind.ATerm or Kind.STerm))
            {
                i = SkipExtend(s, i + 1);
                continue;
            }

            var term = i;
            var j = SkipExtend(s, i + 1);
            // SB6 / SB7: "3.5", "U.S.A" \u2014 an ATerm directly followed by a digit,
            // or between an upper/lowercase letter and an uppercase one.
            if (k == Kind.ATerm && j < n)
            {
                var after = KindAt(s, j);
                if (after == Kind.Numeric) { i = j; continue; }
                if (after == Kind.Upper && PreviousKind(s, term) is Kind.Upper or Kind.Lower) { i = j; continue; }
            }
            // SB9 / SB10: SATerm Close* Sp* stay with the sentence.
            while (j < n && KindAt(s, j) == Kind.Close) j = SkipExtend(s, j + 1);
            while (j < n && KindAt(s, j) == Kind.Sp) j = SkipExtend(s, j + 1);
            if (j >= n) break; // end of text closes the last sentence anyway

            var nextKind = KindAt(s, j);
            // SB8: ATerm Close* Sp* \u00D7 (\u00AC(OLetter | Upper | Lower | ParaSep | SATerm))* Lower
            if (k == Kind.ATerm)
            {
                var m = j;
                while (m < n && KindAt(s, m) is not (Kind.OLetter or Kind.Upper or Kind.Lower or Kind.ParaSep
                                                     or Kind.ATerm or Kind.STerm)) m++;
                if (m < n && KindAt(s, m) == Kind.Lower) { i = j; continue; }
            }
            // SB8a: SATerm Close* Sp* \u00D7 (SContinue | SATerm)
            if (nextKind is Kind.SContinue or Kind.ATerm or Kind.STerm) { i = j; continue; }
            // SB11: SATerm Close* Sp* ParaSep? \u00F7
            if (nextKind == Kind.ParaSep)
                j = s[j] == '\r' && j + 1 < n && s[j + 1] == '\n' ? j + 2 : j + 1;
            result.Add(j);
            i = j;
        }
        if (result.Count == 0 || result[^1] != n)
        {
            if (n > 0) result.Add(n);
        }
        return result;
    }

    private static int SkipExtend(string s, int i)
    {
        while (i < s.Length && KindAt(s, i) == Kind.Extend) i++;
        return i;
    }

    private static Kind PreviousKind(string s, int i)
    {
        for (var p = i - 1; p >= 0; p--)
        {
            var k = KindAt(s, p);
            if (k != Kind.Extend) return k;
        }
        return Kind.Other;
    }

    private static Kind KindAt(string s, int i)
    {
        var c = s[i];
        switch (c)
        {
            case '\n' or '\r' or '\u0085' or '\u2028' or '\u2029':
                return Kind.ParaSep;
            case '.' or '\u2024' or '\uFE52' or '\uFF0E':
                return Kind.ATerm;
            case '!' or '?' or '\u0589' or '\u061F' or '\u06D4' or '\u0700' or '\u0701' or '\u0702' or '\u0964'
                or '\u0965' or '\u203C' or '\u203D' or '\u2047' or '\u2048' or '\u2049' or '\u3002' or '\uFE56'
                or '\uFE57' or '\uFF01' or '\uFF1F' or '\uFF61':
                return Kind.STerm;
            case ',' or '-' or ':' or ';' or '\u055D' or '\u060C' or '\u060D' or '\u07F8' or '\u1802' or '\u1808'
                or '\u2013' or '\u2014' or '\u3001' or '\uFE10' or '\uFE11' or '\uFE13' or '\uFE31' or '\uFE32'
                or '\uFE50' or '\uFE51' or '\uFE55' or '\uFE58' or '\uFE63' or '\uFF0C' or '\uFF0D' or '\uFF1A'
                or '\uFF1B' or '\uFF64':
                return Kind.SContinue;
            case '"' or '\'' or '\u00AB' or '\u00BB':
                return Kind.Close;
            case '\u200D' or '\u200C':
                return Kind.Extend;
        }
        if (char.IsWhiteSpace(c)) return Kind.Sp;
        if (char.IsDigit(c)) return Kind.Numeric;
        switch (char.GetUnicodeCategory(c))
        {
            case UnicodeCategory.LowercaseLetter:
                return Kind.Lower;
            case UnicodeCategory.UppercaseLetter or UnicodeCategory.TitlecaseLetter:
                return Kind.Upper;
            case UnicodeCategory.OtherLetter or UnicodeCategory.ModifierLetter or UnicodeCategory.LetterNumber:
                return Kind.OLetter;
            case UnicodeCategory.OpenPunctuation or UnicodeCategory.ClosePunctuation
                or UnicodeCategory.InitialQuotePunctuation or UnicodeCategory.FinalQuotePunctuation:
                return Kind.Close;
            case UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark
                or UnicodeCategory.EnclosingMark or UnicodeCategory.Format:
                return Kind.Extend;
            case UnicodeCategory.Surrogate:
                return char.IsLetter(s, i) ? Kind.OLetter : Kind.Other;
            default:
                return Kind.Other;
        }
    }
}
