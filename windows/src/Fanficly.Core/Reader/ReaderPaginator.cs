using System.Text.RegularExpressions;

namespace Fanficly.Core;

/// <summary>A page in page-by-page mode (one chapter's slice of sentence atoms).</summary>
/// <param name="Id"><c>c&lt;chapter&gt;-p&lt;page&gt;</c>.</param>
/// <param name="ParagraphIndices">The range of the chapter's atoms on this page
/// (atom indices, despite the Swift name).</param>
/// <param name="StartsSpread">A two-page spread opens on this page: the page a
/// re-pagination kept in place (see <see cref="PageStart"/>), when pairing from the
/// chapter's start would put it on the right.</param>
public sealed record ChapterPage(string Id, int ChapterIndex, int PageIndex, IndexRange ParagraphIndices,
                                 bool StartsSpread = false);

/// <summary>A half-open integer range <c>[Start, End)</c> (Swift <c>Range&lt;Int&gt;</c>).</summary>
public readonly record struct IndexRange(int Start, int End)
{
    public int Count => End - Start;
    public bool IsEmpty => End <= Start;
    public bool Contains(int i) => i >= Start && i < End;
    public IEnumerable<int> Indices() => Enumerable.Range(Start, Math.Max(0, Count));
    public override string ToString() => $"{Start}..<{End}";
}

/// <summary>Where a page's text begins, in terms that survive re-paginating: the
/// paragraph, the sentence in it, and the character offset into that sentence (a
/// page can start mid-sentence). Re-paginating breaks a page exactly here, so the
/// page on screen keeps its first line.</summary>
public readonly record struct PageStart(int Chapter, int Paragraph, int Sentence, int Offset);

/// <summary>A sentence (or part of one) — the unit pages are packed in. Identity is
/// <see cref="Id"/>, as in Swift: two atoms with the same text are different atoms.</summary>
public sealed class ParagraphAtom(int originalParagraphIndex, ReaderRichText text, bool isContinuation,
                                  int sentenceIndex = 0, int sentenceOffset = 0) : IEquatable<ParagraphAtom>
{
    public Guid Id { get; } = Guid.NewGuid();
    /// <summary>The rendered paragraph (<see cref="HTMLToAttributed.ConvertParagraphs"/> index) it comes from.</summary>
    public int OriginalParagraphIndex { get; } = originalParagraphIndex;
    public ReaderRichText Text { get; } = text;
    /// <summary>Not the paragraph's first atom.</summary>
    public bool IsContinuation { get; } = isContinuation;
    /// <summary>The sentence this atom comes from, and where in it the atom starts (the
    /// rest of a sentence split across pages starts past 0). See <see cref="PageStart"/>.</summary>
    public int SentenceIndex { get; } = sentenceIndex;
    public int SentenceOffset { get; } = sentenceOffset;

    public bool Equals(ParagraphAtom? other) => other is not null && Id == other.Id;
    public override bool Equals(object? obj) => obj is ParagraphAtom other && Equals(other);
    public override int GetHashCode() => Id.GetHashCode();
    public override string ToString() => $"p{OriginalParagraphIndex}s{SentenceIndex}+{SentenceOffset}: {Text.Text}";
}

/// <summary>The reader's text settings, as page-by-page lays text out (already
/// divided by any UI zoom). Values are DIPs.</summary>
public sealed record ReaderTypography(
    ReaderFontFamily Family,
    double FontSize,
    double LineSpacing = 0,
    double ParagraphSpacing = 0,
    double Kerning = 0,
    bool BoldText = false);

/// <summary>Text measurement, which only the platform can do. The WinUI app
/// implements it with its real text layout (DirectWrite / XAML); tests use a
/// deterministic fake. Heights are DIPs.</summary>
public interface IReaderTextMeasurer
{
    /// <summary>A quick estimate of <paramref name="text"/>'s height wrapped at
    /// <paramref name="width"/> — the Swift paginator used
    /// <c>NSAttributedString.boundingRect</c>. Lay it out in
    /// <see cref="ReaderTypography.Family"/> at <see cref="ReaderTypography.FontSize"/>,
    /// each run bold/italic as its style says (every run bold when
    /// <see cref="ReaderTypography.BoldText"/>: bold glyphs are wider, so pages
    /// would overflow), <see cref="ReaderTypography.LineSpacing"/> extra between
    /// lines and <see cref="ReaderTypography.Kerning"/> extra letter spacing (wider
    /// tracking wraps sooner). Never called for image slots.</summary>
    double MeasureHeight(ReaderRichText text, double width, ReaderTypography typography);

    /// <summary>One line of body text: the font's line height at the size, no spacing.</summary>
    double LineHeight(ReaderFontFamily family, double fontSize);

    /// <summary>A page's text exactly as the reader draws it: the
    /// <paramref name="blocks"/> stacked with <see cref="ReaderTypography.ParagraphSpacing"/>
    /// between them, each text block in the reader's own text element at
    /// <paramref name="width"/>, each image block (<see cref="ReaderRichText.ImageUrl"/>
    /// set) at <see cref="ReaderInlineImage.SlotHeight"/>. Pages are checked against
    /// it, so it must match what's on screen (Swift: <c>ReaderPageCell.pageContent</c>
    /// in a hosting controller).</summary>
    double MeasureDrawnPage(IReadOnlyList<ReaderRichText> blocks, double width, ReaderTypography typography);
}

/// <summary>A page's text as the reader draws it: the height of
/// <c>atoms[range]</c> laid out as a page.</summary>
public delegate double DrawnHeight(IReadOnlyList<ParagraphAtom> atoms, IndexRange range);

/// <summary>Embedded story images (the opt-in "Show images in stories" setting).</summary>
public static class ReaderInlineImage
{
    /// <summary>Every image slot occupies exactly this height, in every reading mode.
    /// Page-by-page measures page layouts up front, and the flowing modes restore a
    /// saved scroll position right away — if a slot grew when its image finished
    /// loading, everything below would shift, shoving the restored paragraph
    /// off-screen and letting the anchor sampler silently regress saved progress. A
    /// fixed slot makes loading layout-neutral.</summary>
    public const double SlotHeight = 240;
}

/// <summary>What re-paginates page-by-page: any change means new pages.</summary>
public sealed record PaginationTrigger(
    int Chapter,
    double FontSize,
    string FontFamily,
    double WidthPercent,
    double LineSpacing,
    double ParagraphSpacing,
    double Kerning,
    bool BoldText,
    bool ShowImages,
    ReaderSize Size);

/// <param name="Atoms">Each paginated chapter's atoms, after pagination split
/// sentences at line ends — pages index into these lists.</param>
/// <param name="KeptPageId">The page kept in place, when pagination started from a <see cref="PageStart"/>.</param>
public sealed record PaginationResult(
    IReadOnlyList<ChapterPage> Pages,
    IReadOnlyDictionary<int, List<ParagraphAtom>> Atoms,
    string? KeptPageId = null);

/// <summary>A page's content as drawn: the page's atoms regrouped into their paragraphs
/// (Swift: <c>ReaderPageCell.renderedBlocks</c> / <c>concatenateAtoms</c>).</summary>
public static class ReaderPageContent
{
    /// <summary>One paragraph (or the part of it on this page).</summary>
    public sealed record RenderedBlock(int OriginalParagraphIndex, ReaderRichText Text)
    {
        public int Id => OriginalParagraphIndex;
    }

    /// <summary>The page's atoms joined into paragraph blocks, in order.</summary>
    public static IReadOnlyList<RenderedBlock> RenderedBlocks(IReadOnlyList<ParagraphAtom> atoms, IndexRange range)
    {
        var blocks = new List<RenderedBlock>();
        if (range.IsEmpty) return blocks;
        var currentIndex = atoms[range.Start].OriginalParagraphIndex;
        var current = new List<ParagraphAtom> { atoms[range.Start] };
        for (var index = range.Start + 1; index < range.End; index++)
        {
            if (index >= atoms.Count) continue;
            var atom = atoms[index];
            if (atom.OriginalParagraphIndex == currentIndex)
            {
                current.Add(atom);
            }
            else
            {
                blocks.Add(new RenderedBlock(currentIndex, ConcatenateAtoms(current)));
                currentIndex = atom.OriginalParagraphIndex;
                current = [atom];
            }
        }
        if (current.Count > 0) blocks.Add(new RenderedBlock(currentIndex, ConcatenateAtoms(current)));
        return blocks;
    }

    /// <summary>Joins atoms of one paragraph, adding a space between two when
    /// neither already has whitespace at the join.</summary>
    public static ReaderRichText ConcatenateAtoms(IReadOnlyList<ParagraphAtom> atoms)
    {
        var parts = new List<ReaderRichText>(atoms.Count * 2);
        var previous = "";
        for (var i = 0; i < atoms.Count; i++)
        {
            var next = atoms[i].Text.Text;
            if (i > 0)
            {
                var needsSpace = previous.Length > 0 && next.Length > 0
                                 && !previous.EndsWith(' ') && !previous.EndsWith('\n')
                                 && !next.StartsWith(' ') && !next.StartsWith('\n');
                if (needsSpace) parts.Add(new ReaderRichText(" "));
            }
            parts.Add(atoms[i].Text);
            if (next.Length > 0) previous = next;
            else if (i == 0) previous = "";
        }
        return ReaderRichText.Concat(parts);
    }
}

/// <summary>Page-by-page's pagination: splits chapters into pages that fit a page
/// area. Pure (measurement goes through <see cref="IReaderTextMeasurer"/>), so it's
/// unit-tested across device sizes and reader settings.</summary>
public static partial class ReaderPaginator
{
    /// <summary>A page's top and bottom margin, inside the area between the reader's
    /// bars. Pagination subtracts exactly this, so measured pages match drawn ones
    /// (Swift: <c>ReaderView.pageVerticalMargin</c>).</summary>
    public const double PageVerticalMargin = 12;

    /// <summary>What pages checked against the drawn layout (<see cref="DrawnHeight"/>)
    /// are packed short of their area by: nothing. The check measures the page
    /// exactly as it's drawn, and even a 2 pt margin cost the page a last line now
    /// and then.</summary>
    public const double Reserve = 0;

    /// <summary>Pages not checked against the drawn layout keep headroom for the quick
    /// estimate measuring differently (2% of the page, 8–24 pt).</summary>
    public static double UncheckedReserve(double pageHeight) => Math.Min(24, Math.Max(8, pageHeight * 0.02));

    /// <summary>Whether the chapters either side of the one being read are checked
    /// against the drawn layout too. They're paginated so page turns run on into
    /// them, and re-paginated, checked, as soon as one is reached. On iOS checking
    /// them up front cost ~1.5 ms a page and they skip it; the Mac checks them all
    /// (its estimate ran short of the drawn layout, so an unchecked page could put
    /// a line under the footer while you turn into it, and Macs are quick).
    /// Windows PCs are desktops like the Mac, so on by default; the app may turn it
    /// off when its estimate is known to be conservative.</summary>
    public static bool ChecksAdjacentChapters { get; set; } = true;

    /// <summary>A chapter's paragraphs as sentence atoms, the unit pages are packed in.
    /// <paramref name="includeImages"/> must match the reader's images setting, or
    /// paragraph indices drift between modes.</summary>
    public static List<ParagraphAtom> Atoms(string chapterHtml, bool includeImages)
    {
        var paragraphs = HTMLToAttributed.ConvertParagraphs(chapterHtml, includeImages);
        var atoms = new List<ParagraphAtom>();
        for (var p = 0; p < paragraphs.Count; p++)
        {
            var sentences = HTMLToAttributed.SplitIntoSentences(paragraphs[p]);
            for (var s = 0; s < sentences.Count; s++)
                atoms.Add(new ParagraphAtom(p, sentences[s], isContinuation: s > 0, sentenceIndex: s));
        }
        return atoms;
    }

    /// <summary>Where <paramref name="page"/>'s text begins, given its chapter's atoms
    /// (null for the work's title page).</summary>
    public static PageStart? Start(ChapterPage page, IReadOnlyList<ParagraphAtom> atoms)
    {
        if (page.ParagraphIndices.IsEmpty || page.ParagraphIndices.Start >= atoms.Count) return null;
        var atom = atoms[page.ParagraphIndices.Start];
        return new PageStart(page.ChapterIndex, atom.OriginalParagraphIndex, atom.SentenceIndex, atom.SentenceOffset);
    }

    /// <summary>Splits <paramref name="atom"/> (a sentence) so its first part, laid out
    /// after <paramref name="leading"/> (atoms of the same paragraph already on the
    /// page), fits in <paramref name="budget"/>. It keeps the longest run of whole
    /// words that fits, which is exactly where a line ends, so the page fills to its
    /// last line and the sentence carries on at the top of the next one, like a
    /// printed book. Null when not even one word fits, or for an image slot.</summary>
    public static (ParagraphAtom Head, ParagraphAtom Tail)? SplitAtomToFit(
        ParagraphAtom atom, IReadOnlyList<ParagraphAtom> leading, double budget, Func<ReaderRichText, double> measure)
    {
        if (HTMLToAttributed.ImageAttachmentUrl(atom.Text) is not null) return null;
        var chars = atom.Text.Text;
        // Candidate break points: just before each space (the space is dropped).
        var breaks = new List<int>();
        for (var i = 1; i < chars.Length; i++)
            if (chars[i] == ' ') breaks.Add(i);
        if (breaks.Count == 0) return null;

        bool Fits(int k)
        {
            var part = new ParagraphAtom(atom.OriginalParagraphIndex, atom.Text.Slice(0, breaks[k]), atom.IsContinuation);
            return measure(ReaderPageContent.ConcatenateAtoms([.. leading, part])) <= budget;
        }

        if (!Fits(0)) return null;
        int lo = 0, hi = breaks.Count - 1;
        while (lo < hi)
        {
            var mid = (lo + hi + 1) / 2;
            if (Fits(mid)) lo = mid; else hi = mid - 1;
        }
        return SplitAtom(atom, breaks[lo] + 1);
    }

    /// <summary>Splits <paramref name="atom"/> so its second part starts at character
    /// <paramref name="k"/>; a space just before <paramref name="k"/> is dropped, as at
    /// a line end. Null when either part would be empty.</summary>
    public static (ParagraphAtom Head, ParagraphAtom Tail)? SplitAtom(ParagraphAtom atom, int k)
    {
        var chars = atom.Text.Text;
        if (k <= 0 || k >= chars.Length) return null;
        var headEnd = chars[k - 1] == ' ' ? k - 1 : k;
        if (headEnd <= 0) return null;
        var head = new ParagraphAtom(atom.OriginalParagraphIndex, atom.Text.Slice(0, headEnd), atom.IsContinuation,
                                     atom.SentenceIndex, atom.SentenceOffset);
        var tail = new ParagraphAtom(atom.OriginalParagraphIndex, atom.Text.Slice(k), isContinuation: true,
                                     atom.SentenceIndex, atom.SentenceOffset + k);
        return (head, tail);
    }

    /// <summary>The quick height estimate of one block. An image slot renders as a
    /// fixed-height image cell, not text, so its height is that fixed height — text
    /// measurement of the placeholder character would badly under-count it.</summary>
    public static double CalculateHeight(ReaderRichText text, double width, ReaderTypography typography,
                                         IReaderTextMeasurer measurer)
    {
        if (HTMLToAttributed.ImageAttachmentUrl(text) is not null) return ReaderInlineImage.SlotHeight;
        return Math.Ceiling(measurer.MeasureHeight(text, width, typography));
    }

    public static double EstimateChapterHeaderHeight(string title, double width, double fontSize,
                                                     ReaderFontFamily fontFamily, IReaderTextMeasurer measurer)
    {
        double height = 42 + 15;
        if (title.Length > 0)
        {
            var titleHeight = measurer.MeasureHeight(new ReaderRichText(title), width,
                                                     new ReaderTypography(fontFamily, fontSize + 5));
            height += Math.Ceiling(titleHeight) + 10;
        }
        return height;
    }

    public static double EstimateTitleHeaderHeight(string title, string author, string authorUsername,
                                                   AO3WorkSummary? summary, double width, double fontSize,
                                                   ReaderFontFamily fontFamily, IReaderTextMeasurer measurer)
    {
        double height = 0;
        var titleHeight = measurer.MeasureHeight(new ReaderRichText(title), width,
                                                 new ReaderTypography(fontFamily, fontSize + 14));
        height += Math.Ceiling(titleHeight) + 14;

        if (author.Length > 0)
        {
            var authorHeight = measurer.MeasureHeight(new ReaderRichText($"by {author}"), width,
                                                      new ReaderTypography(ReaderFontFamily.Sans, fontSize));
            height += Math.Ceiling(authorHeight) + 14;
        }

        height += 80;

        if (summary is not null && summary.Summary.Length > 0)
        {
            height += 15 + 4;
            var plainSummary = TagRegex().Replace(summary.Summary, "");
            var summaryHeight = measurer.MeasureHeight(new ReaderRichText(plainSummary), width,
                                                       new ReaderTypography(fontFamily, fontSize - 1));
            height += Math.Ceiling(summaryHeight) + 14;
        }

        height += 10;
        return height;
    }

    /// <summary>Measures pages with the reader's own drawn layout (Swift:
    /// <c>drawnHeightMeasure</c>).</summary>
    public static DrawnHeight DrawnHeightMeasure(IReaderTextMeasurer measurer, double width, ReaderTypography typography) =>
        (atoms, range) => measurer.MeasureDrawnPage(
            ReaderPageContent.RenderedBlocks(atoms, range).Select(b => b.Text).ToArray(), width, typography);

    /// <summary>Splits one chapter's <paramref name="atoms"/> into pages of
    /// <paramref name="viewportHeight"/>. May split sentences at line ends: the list
    /// is updated in place and pages index into it.
    /// <para>With <paramref name="drawnHeight"/> (the chapter being read), every page is
    /// checked against the drawn layout and re-packed to fill it (<c>fitPage</c>);
    /// without it, pages are packed by the quick estimate with
    /// <see cref="UncheckedReserve"/> headroom.</para>
    /// <para>With <paramref name="startingAt"/> (re-paginating with a page on screen: the
    /// controls shown or hidden, the narration bar, a resize), a page starts exactly
    /// where that one did, so its first line stays put and the new room shows at its
    /// foot. The page before it may come out short.</para>
    /// The first chapter opens on a dedicated title page with no story text.</summary>
    public static IReadOnlyList<ChapterPage> PaginateChapter(
        int chapterIndex,
        List<ParagraphAtom> atoms,
        double width,
        double viewportHeight,
        double titleHeaderHeight,
        double chapterHeaderHeight,
        bool isFirstChapter,
        bool showChapterHeader,
        ReaderTypography typography,
        IReaderTextMeasurer measurer,
        DrawnHeight? drawnHeight = null,
        PageStart? startingAt = null)
    {
        _ = titleHeaderHeight; // the title page is a page of its own; kept for parity with the Swift signature
        var pages = new List<ChapterPage>();
        var startIndex = 0;
        var pageIndex = 0;

        Guid? keptId = null;
        if (startingAt is { } start)
        {
            var i = atoms.FindIndex(a =>
                a.OriginalParagraphIndex == start.Paragraph && a.SentenceIndex == start.Sentence
                && start.Offset >= a.SentenceOffset && start.Offset < a.SentenceOffset + a.Text.Length);
            if (i >= 0)
            {
                var k = start.Offset - atoms[i].SentenceOffset;
                if (k > 0 && SplitAtom(atoms[i], k) is (var head, var tail))
                {
                    atoms[i] = head;
                    atoms.Insert(i + 1, tail);
                    keptId = tail.Id;
                }
                else
                {
                    keptId = atoms[i].Id;
                }
            }
        }
        var reachedKept = keptId is null;

        double Measure(ReaderRichText text) => CalculateHeight(text, width, typography, measurer);
        // One line of body text.
        var oneLine = measurer.LineHeight(typography.Family, typography.FontSize);

        if (isFirstChapter)
        {
            // Page 0 is a dedicated cover/metadata page with no story text.
            pages.Add(new ChapterPage($"c{chapterIndex}-p0", chapterIndex, 0, new IndexRange(0, 0)));
            pageIndex = 1;
        }

        while (startIndex < atoms.Count)
        {
            var pageMaxHeight = viewportHeight;
            // Whether this page shows the chapter header.
            var displaysChapterHeader = showChapterHeader && (isFirstChapter ? pageIndex == 1 : pageIndex == 0);
            if (displaysChapterHeader) pageMaxHeight = Math.Max(0, viewportHeight - chapterHeaderHeight);

            var reserve = drawnHeight is null ? UncheckedReserve(pageMaxHeight) : Reserve;
            var isKept = atoms[startIndex].Id == keptId;
            if (isKept) reachedKept = true;
            // Pages before the kept one stop short of it.
            var stop = reachedKept ? null : keptId;
            var endIndex = startIndex;
            var includedAny = false;
            if (pageMaxHeight > 40 && drawnHeight is not null)
            {
                endIndex = FitPage(atoms, startIndex, pageMaxHeight, reserve, typography.ParagraphSpacing, oneLine,
                                   Measure, drawnHeight, stop);
                includedAny = true;
            }
            else if (pageMaxHeight > 40)
            {
                endIndex = PackPage(atoms, startIndex, pageMaxHeight - reserve, typography.ParagraphSpacing, oneLine,
                                    Measure, stop);
                includedAny = true;
            }

            IndexRange range;
            if (includedAny)
            {
                range = new IndexRange(startIndex, endIndex + 1);
                startIndex = endIndex + 1;
            }
            else
            {
                range = new IndexRange(startIndex, startIndex);
            }

            pages.Add(new ChapterPage($"c{chapterIndex}-p{pageIndex}", chapterIndex, pageIndex, range,
                // Spreads pair pages from the chapter's first: an odd page sits on
                // the right, so the kept page opens a spread of its own.
                StartsSpread: isKept && includedAny && pageIndex % 2 == 1));
            pageIndex += 1;
            // A page area too short for any text (≤ 40) would loop forever; the Swift
            // only ever gets here with a chapter header taller than the page.
            if (!includedAny && pageIndex > atoms.Count + 2) break;
        }

        if (pages.Count == 0)
            pages.Add(new ChapterPage($"c{chapterIndex}-p0", chapterIndex, 0, new IndexRange(0, 0)));
        return pages;
    }

    /// <summary>Packs a page by the quick estimate, then checks it against the drawn
    /// layout, and when the two disagree packs it again with a corrected budget until
    /// the page is as full as it can be without running past it. The estimate is
    /// close but not exact (on the Mac New York lines drew a point taller and small
    /// text fit more words a line; on iOS a long paragraph could wrap to one line
    /// fewer), so unchecked pages came out a line or more short, or ran a line past
    /// the footer. Most pages need one drawn measurement; a misjudged one bisects the
    /// budget between the fullest packing that fit and the smallest that ran past.
    /// Returns the page's last atom.</summary>
    private static int FitPage(List<ParagraphAtom> atoms, int start, double pageHeight, double reserve,
                               double paragraphSpacing, double oneLine, Func<ReaderRichText, double> measure,
                               DrawnHeight drawnHeight, Guid? stop)
    {
        var unpacked = atoms.ToList();
        var limit = pageHeight - reserve;
        var budget = limit;
        (List<ParagraphAtom> Atoms, int End, double Budget)? fullest = null;
        double? overflowing = null;
        (List<ParagraphAtom> Atoms, int End) latest = (unpacked, start);
        for (var attempt = 0; attempt < 8; attempt++)
        {
            var trial = unpacked.ToList();
            var end = PackPage(trial, start, budget, paragraphSpacing, oneLine, measure, stop);
            latest = (trial, end);
            var drawn = drawnHeight(trial, new IndexRange(start, end + 1));
            if (drawn > limit)
            {
                // Any budget down to what the estimate measured this packing at packs
                // the very same lines (it left them slack under the budget), so that's
                // the bound to go below, not the budget.
                var packed = PackedHeight(trial, start, end, paragraphSpacing, measure);
                overflowing = Math.Min(overflowing ?? budget, Math.Min(budget, packed));
            }
            else
            {
                if (budget >= (fullest?.Budget ?? -1)) fullest = (trial, end, budget);
                // Done when there's nothing left to add or no room for a line.
                if (end + 1 >= trial.Count || trial[end + 1].Id == stop || limit - drawn < oneLine) break;
            }

            if (fullest is { } fit && overflowing is { } over)
            {
                if (over - fit.Budget > 1)
                {
                    budget = (fit.Budget + over) / 2;
                    continue;
                }
            }
            else if (fullest is { } onlyFit)
            {
                budget = onlyFit.Budget + (limit - drawn);
                continue;
            }
            else if (overflowing is { } onlyOver)
            {
                budget = onlyOver - (drawn - limit) - 1;
                continue;
            }
            break;
        }
        // Nothing fit (a page of one unbreakable sentence): take the last try.
        var chosen = fullest is { } best ? (best.Atoms, best.End) : latest;
        atoms.Clear();
        atoms.AddRange(chosen.Atoms);
        return chosen.End;
    }

    /// <summary>The height the quick estimate gives <c>atoms[first...last]</c> laid out
    /// as a page: each paragraph's sentences joined, paragraphs spaced apart.</summary>
    private static double PackedHeight(List<ParagraphAtom> atoms, int first, int last, double paragraphSpacing,
                                       Func<ReaderRichText, double> measure)
    {
        var blocks = new List<List<ParagraphAtom>>();
        for (var i = first; i <= last; i++)
        {
            var atom = atoms[i];
            if (blocks.Count > 0 && blocks[^1][^1].OriginalParagraphIndex == atom.OriginalParagraphIndex)
                blocks[^1].Add(atom);
            else
                blocks.Add([atom]);
        }
        return blocks.Sum(b => measure(ReaderPageContent.ConcatenateAtoms(b)))
               + paragraphSpacing * Math.Max(0, blocks.Count - 1);
    }

    /// <summary>Fills a page from <paramref name="startIndex"/> with as much as
    /// <paramref name="packingBudget"/> holds, by the quick estimate, never taking the
    /// atom <paramref name="stop"/> (where a kept page starts). May split a sentence
    /// at a line end (the rest becomes a new atom right after it). Returns the page's
    /// last atom.</summary>
    private static int PackPage(List<ParagraphAtom> atoms, int startIndex, double packingBudget, double paragraphSpacing,
                                double oneLine, Func<ReaderRichText, double> measure, Guid? stop)
    {
        var endIndex = startIndex;
        var currentBlockParaIndex = atoms[startIndex].OriginalParagraphIndex;
        List<ParagraphAtom> currentBlockAtoms = [atoms[startIndex]];
        var currentBlockHeight = measure(ReaderPageContent.ConcatenateAtoms(currentBlockAtoms));
        // A single sentence taller than the page: break it at a line end rather
        // than letting the page overflow.
        if (currentBlockHeight > packingBudget
            && SplitAtomToFit(atoms[startIndex], [], packingBudget, measure) is (var firstHead, var firstTail))
        {
            atoms[startIndex] = firstHead;
            atoms.Insert(startIndex + 1, firstTail);
            currentBlockAtoms = [firstHead];
            currentBlockHeight = measure(firstHead.Text);
        }

        var currentHeight = currentBlockHeight;
        double completedBlocksHeight = 0;

        while (endIndex + 1 < atoms.Count && atoms[endIndex + 1].Id != stop)
        {
            var nextAtom = atoms[endIndex + 1];

            if (nextAtom.OriginalParagraphIndex == currentBlockParaIndex)
            {
                List<ParagraphAtom> proposedBlockAtoms = [.. currentBlockAtoms, nextAtom];
                var proposedBlockHeight = measure(ReaderPageContent.ConcatenateAtoms(proposedBlockAtoms));
                var potentialHeight = completedBlocksHeight + proposedBlockHeight;
                if (potentialHeight <= packingBudget)
                {
                    endIndex += 1;
                    currentBlockAtoms = proposedBlockAtoms;
                    currentBlockHeight = proposedBlockHeight;
                    currentHeight = potentialHeight;
                }
                else
                {
                    // Fill the page to its last line, like a printed book: the
                    // sentence continues on the next page.
                    if (SplitAtomToFit(nextAtom, currentBlockAtoms, packingBudget - completedBlocksHeight, measure)
                        is (var head, var tail))
                    {
                        atoms[endIndex + 1] = head;
                        atoms.Insert(endIndex + 2, tail);
                        endIndex += 1;
                    }
                    break;
                }
            }
            else
            {
                List<ParagraphAtom> proposedBlockAtoms = [nextAtom];
                var proposedBlockHeight = measure(ReaderPageContent.ConcatenateAtoms(proposedBlockAtoms));
                var potentialHeight = currentHeight + paragraphSpacing + proposedBlockHeight;
                if (potentialHeight <= packingBudget)
                {
                    endIndex += 1;
                    completedBlocksHeight += currentBlockHeight + paragraphSpacing;
                    currentBlockParaIndex = nextAtom.OriginalParagraphIndex;
                    currentBlockAtoms = proposedBlockAtoms;
                    currentBlockHeight = proposedBlockHeight;
                    currentHeight = potentialHeight;
                }
                else
                {
                    // Start the paragraph here with as many lines as fit, even one, so
                    // the page fills to its last line. (Holding back a lone opening
                    // line, as books do, left up to two lines blank at the foot of a page.)
                    var room = packingBudget - currentHeight - paragraphSpacing;
                    if (room >= oneLine && SplitAtomToFit(nextAtom, [], room, measure) is (var head, var tail))
                    {
                        atoms[endIndex + 1] = head;
                        atoms.Insert(endIndex + 2, tail);
                        endIndex += 1;
                    }
                    break;
                }
            }
        }
        return endIndex;
    }

    /// <summary>Paginates the chapter being read plus the chapters either side of it
    /// (so page turns run on into them) — Swift's <c>ReaderView.performPagination</c>.
    /// The chapter being read is checked page by page against the drawn layout; see
    /// <see cref="ChecksAdjacentChapters"/> for the others.</summary>
    /// <param name="limitLineLength">The phone profile's line-length cap (see
    /// <see cref="ReaderMetrics.TextColumnWidth"/>); false on Windows.</param>
    public static PaginationResult PerformPagination(
        PaginationTrigger trigger,
        PageStart? start,
        IReadOnlyList<AO3ChapterPayload> chapters,
        string title,
        string author,
        string authorUsername,
        AO3WorkSummary? summary,
        bool limitLineLength,
        IReaderTextMeasurer measurer)
    {
        // Must match the drawn page's column, or pages are measured at one width
        // and drawn at another.
        var w = ReaderMetrics.TextColumnWidth(trigger.Size.Width, trigger.WidthPercent, trigger.FontSize, limitLineLength);
        var h = trigger.Size.Height - 2 * PageVerticalMargin;
        if (!(w > 50 && h > 100)) return new PaginationResult([], new Dictionary<int, List<ParagraphAtom>>());

        var fontFamily = ReaderFontFamilyExtensions.FromRawValue(trigger.FontFamily) ?? ReaderFontFamily.NewYork;
        var typography = new ReaderTypography(fontFamily, trigger.FontSize, trigger.LineSpacing,
                                              trigger.ParagraphSpacing, trigger.Kerning, trigger.BoldText);
        var order = chapters.Select(c => c.Index).ToArray();
        var targetChapters = new List<int> { trigger.Chapter };
        if (ChapterTracking.AdjacentChapter(order, trigger.Chapter, forward: false) is { } prev) targetChapters.Add(prev);
        if (ChapterTracking.AdjacentChapter(order, trigger.Chapter, forward: true) is { } next) targetChapters.Add(next);

        var allPages = new List<ChapterPage>();
        var allAtoms = new Dictionary<int, List<ParagraphAtom>>();
        var drawnHeight = DrawnHeightMeasure(measurer, w, typography);

        foreach (var chIndex in targetChapters.Order())
        {
            var chapter = chapters.FirstOrDefault(c => c.Index == chIndex);
            if (chapter is null) continue;

            var atoms = Atoms(chapter.BodyHtml, trigger.ShowImages);
            var titleHeaderHeight = EstimateTitleHeaderHeight(title, author, authorUsername, summary, w,
                                                              trigger.FontSize, fontFamily, measurer);
            var chapterHeaderHeight = EstimateChapterHeaderHeight(chapter.Title, w, trigger.FontSize, fontFamily, measurer);
            var isFirstChapter = chapters.Count > 0 && chIndex == chapters[0].Index;
            var showChapterHeader = chapters.Count > 1;

            // Pagination may split a sentence at a line end (see SplitAtomToFit), so
            // the atoms are stored after it — pages index into the split list.
            var chPages = PaginateChapter(chIndex, atoms, w, h, titleHeaderHeight, chapterHeaderHeight,
                                          isFirstChapter, showChapterHeader, typography, measurer,
                                          chIndex == trigger.Chapter || ChecksAdjacentChapters ? drawnHeight : null,
                                          start?.Chapter == chIndex ? start : null);
            allAtoms[chIndex] = atoms;
            allPages.AddRange(chPages);
        }

        string? kept = null;
        if (start is { } s)
            kept = allPages.FirstOrDefault(page =>
                page.ChapterIndex == s.Chapter
                && allAtoms.TryGetValue(page.ChapterIndex, out var chapterAtoms)
                && Start(page, chapterAtoms) == s)?.Id;
        return new PaginationResult(allPages, allAtoms, kept);
    }

    [GeneratedRegex("<[^>]+>")]
    private static partial Regex TagRegex();
}
