using Fanficly.Core;
using Xunit.Abstractions;

namespace Fanficly.Core.Tests;

/// <summary>The reading column: phone settings cap line length on wide layouts (a Pro
/// Max in landscape, iPhone Duo unfolded); iPad, Mac and Windows keep the plain
/// percentage the user chose.</summary>
public class ReaderMetricsTests
{
    [Fact]
    public void NarrowPhone_UsesThePercentage()
    {
        // 402 × 90%, in whole points
        Assert.Equal(361, ReaderMetrics.TextColumnWidth(402, 90, 18, limitLineLength: true));
    }

    [Fact]
    public void WidePhoneLayout_CapsAtAbout80Characters()
    {
        Assert.Equal(18 * ReaderMetrics.MaxLineLengthEm, ReaderMetrics.TextColumnWidth(951, 90, 18, limitLineLength: true));
    }

    [Fact]
    public void CapScalesWithTextSize()
    {
        var big = ReaderMetrics.TextColumnWidth(951, 100, 24, limitLineLength: true);
        Assert.Equal(Math.Min(951, 24 * ReaderMetrics.MaxLineLengthEm), big);
    }

    [Fact]
    public void IpadAndMac_KeepThePercentage()
    {
        // 1366 × 70%, in whole points
        Assert.Equal(956, ReaderMetrics.TextColumnWidth(1366, 70, 18, limitLineLength: false));
    }
}

/// <summary>Page-by-page's two-page spread: when it kicks in, where the gutter goes,
/// and how pages pair up.</summary>
public class ReaderSpreadTests
{
    private static ChapterPage Page(int chapter, int index) =>
        new($"c{chapter}-p{index}", chapter, index, new IndexRange(0, 1));

    [Fact]
    public void PortraitPhone_StaysOnePage()
    {
        Assert.Null(ReaderSpread.LayoutFor(new ReaderSize(402, 800), null));
    }

    [Fact]
    public void IPadPortrait_StaysOnePage()
    {
        // Wide enough, but taller than it is wide.
        Assert.Null(ReaderSpread.LayoutFor(new ReaderSize(1032, 1300), null));
    }

    [Fact]
    public void Landscape_SplitsAroundTheCenter()
    {
        var layout = ReaderSpread.LayoutFor(new ReaderSize(1000, 700), null);
        Assert.NotNull(layout);
        Assert.Equal(500, (layout.GutterStart + layout.GutterEnd) / 2);
        Assert.Equal(ReaderSpread.MinimumGutter, layout.GutterEnd - layout.GutterStart);
        Assert.Equal(layout.GutterStart, layout.LeftX + layout.PageWidth);
        Assert.True(layout.GutterEnd + layout.PageWidth <= 1000);
    }

    [Fact]
    public void DuoFold_BecomesTheGutter()
    {
        // A fold slightly off center: the gutter follows it, and both pages
        // keep the same width (they paginate identically).
        var fold = new ReaderRect(470, 0, 20, 700);
        var layout = ReaderSpread.LayoutFor(new ReaderSize(1000, 700), fold);
        Assert.NotNull(layout);
        Assert.Equal(fold.MidX, (layout.GutterStart + layout.GutterEnd) / 2);
        Assert.Equal(Math.Floor(Math.Min(layout.GutterStart, 1000 - layout.GutterEnd)), layout.PageWidth);
    }

    [Fact]
    public void HorizontalOrEdgeRegion_IsNotTreatedAsTheFold()
    {
        var sideways = new ReaderRect(0, 340, 1000, 20);
        var edge = new ReaderRect(960, 0, 40, 700);
        foreach (var region in new[] { sideways, edge })
        {
            var layout = ReaderSpread.LayoutFor(new ReaderSize(1000, 700), region);
            Assert.NotNull(layout);
            Assert.Equal(500, (layout.GutterStart + layout.GutterEnd) / 2);
        }
    }

    [Fact]
    public void PagesPairWithinEachChapter()
    {
        var spreads = ReaderSpread.Spreads([Page(1, 0), Page(1, 1), Page(1, 2), Page(2, 0), Page(2, 1)]);
        Assert.Equal(["c1-p0", "c1-p2", "c2-p0"], spreads.Select(s => s.Left.Id));
        Assert.Equal(["c1-p1", null, "c2-p1"], spreads.Select(s => s.Right?.Id));
    }

    [Fact]
    public void AKeptPageOpensASpread()
    {
        // Re-paginating keeps the page on screen in place; in a spread it has
        // to stay on the left, so the page before it may stand alone.
        var kept = Page(1, 3) with { StartsSpread = true };
        var spreads = ReaderSpread.Spreads([Page(1, 0), Page(1, 1), Page(1, 2), kept, Page(1, 4)]);
        Assert.Equal(["c1-p0", "c1-p2", "c1-p3"], spreads.Select(s => s.Left.Id));
        Assert.Equal(["c1-p1", null, "c1-p4"], spreads.Select(s => s.Right?.Id));
    }

    [Fact]
    public void SpreadFindsEitherOfItsPages()
    {
        var spread = ReaderSpread.Spreads([Page(1, 0), Page(1, 1)])[0];
        Assert.True(spread.Contains("c1-p0"));
        Assert.True(spread.Contains("c1-p1"));
        Assert.False(spread.Contains("c1-p2"));
        Assert.Equal("c1-p0", spread.Id);
    }
}

/// <summary>Page-by-page's page height: pages fill the page area on screen, shrink at
/// once and grow only once the area settles. The heights are an iPhone's page area:
/// 700 with the controls up, 784 with them hidden.</summary>
public class PageAreaTrackerTests
{
    [Fact]
    public void ShrinksAtOnce()
    {
        var tracker = new PageAreaTracker();
        tracker.Reset(700, controlsUp: true);
        tracker.Observe(650, controlsUp: true);
        Assert.Equal(650, tracker.PageHeight);
    }

    [Fact]
    public void AMomentsSmallerArea_GrowsBackOnceSettled()
    {
        // A short first layout (a transition) used to stick for good, leaving
        // blank space at the foot of every page.
        var tracker = new PageAreaTracker();
        tracker.Reset(530, controlsUp: true);
        tracker.Observe(700, controlsUp: true);
        Assert.Equal(530, tracker.PageHeight); // growing waits for the area to settle
        tracker.Settle(700);
        Assert.Equal(700, tracker.PageHeight);
    }

    [Fact]
    public void HidingTheControls_GrowsPagesToFillTheScreen()
    {
        // Pages used to stay at the controls-up height, leaving the controls'
        // room blank at the foot of every page while they were hidden.
        var tracker = new PageAreaTracker();
        tracker.Reset(700, controlsUp: true);
        tracker.Observe(784, controlsUp: false);
        Assert.Equal(700, tracker.PageHeight); // growing waits for the bars to finish animating
        tracker.Settle(784);
        Assert.Equal(784, tracker.PageHeight);
    }

    [Fact]
    public void ShowingTheControls_ShrinksPagesAtOnce()
    {
        // Or the page's last lines would sit under the page footer.
        var tracker = new PageAreaTracker();
        tracker.Reset(784, controlsUp: false);
        tracker.Observe(700, controlsUp: true);
        Assert.Equal(700, tracker.PageHeight);
        tracker.Settle(700);
        Assert.Equal(700, tracker.PageHeight);
    }

    [Fact]
    public void NarrationBar_ShrinksPagesUntilItCloses()
    {
        var tracker = new PageAreaTracker();
        tracker.Reset(700, controlsUp: true);
        tracker.Observe(660, controlsUp: true);
        tracker.Settle(660);
        Assert.Equal(660, tracker.PageHeight);
        tracker.Observe(700, controlsUp: true);
        tracker.Settle(700);
        Assert.Equal(700, tracker.PageHeight);
    }

    [Fact]
    public void FullScreen_KeepsOnePageOrTwo()
    {
        // An iPad in landscape beside the sidebar: a two-page spread with the
        // controls up, but full screen's extra height made the area too square
        // for two pages, so hiding the controls switched to one page.
        const double width = 1056;
        var tracker = new PageAreaTracker();
        tracker.Reset(910, controlsUp: true);
        Assert.NotNull(ReaderSpread.LayoutFor(new ReaderSize(width, tracker.SpreadDecisionHeight), null));
        tracker.Observe(988, controlsUp: false);
        tracker.Settle(988);
        Assert.Equal(988, tracker.PageHeight); // full screen fills the screen
        // The full-screen area alone would mean one page.
        Assert.Null(ReaderSpread.LayoutFor(new ReaderSize(width, 988), null));
        Assert.Equal(910, tracker.SpreadDecisionHeight);
        // Still two pages in full screen.
        Assert.NotNull(ReaderSpread.LayoutFor(new ReaderSize(width, tracker.SpreadDecisionHeight), null));
    }

    [Fact]
    public void NewWindowSize_StartsOver()
    {
        var tracker = new PageAreaTracker();
        tracker.Reset(700, controlsUp: true);
        tracker.Reset(330, controlsUp: true);
        Assert.Equal(330, tracker.PageHeight);
        tracker.Observe(300, controlsUp: true);
        Assert.Equal(300, tracker.PageHeight);
        tracker.Settle(330);
        Assert.Equal(330, tracker.PageHeight);
    }
}

/// <summary>A deterministic stand-in for the platform's text layout: fixed-advance
/// glyphs (a per-family em fraction, wider when bold, plus tracking) wrapped greedily
/// at word boundaries, and a line height derived from the font size.
///
/// The quick estimate (<see cref="MeasureHeight"/>) and the "as drawn" layout
/// (<see cref="MeasureDrawnPage"/>) deliberately disagree a little, as boundingRect
/// and SwiftUI do on Apple platforms: the drawn layout fits slightly more on a line
/// (a long paragraph can wrap to one line fewer, as on iOS) and draws each line a
/// quarter point taller (as New York did on the Mac). That exercises both of
/// fitPage's corrections: growing a page the estimate left short and shrinking one
/// that would run past its area.</summary>
internal sealed class FakeTextMeasurer : IReaderTextMeasurer
{
    public const double DrawnWidthSlack = 1.03;
    public const double DrawnLineExtra = 0.25;

    private static double EmAdvance(ReaderFontFamily family) => family switch
    {
        ReaderFontFamily.NewYork => 0.53,
        ReaderFontFamily.Serif => 0.52,
        ReaderFontFamily.Sans => 0.50,
        ReaderFontFamily.Rounded => 0.51,
        _ => 0.60,
    };

    private static double LineFactor(ReaderFontFamily family) => family switch
    {
        ReaderFontFamily.NewYork => 1.26,
        ReaderFontFamily.Serif => 1.22,
        ReaderFontFamily.Sans => 1.19,
        ReaderFontFamily.Rounded => 1.19,
        _ => 1.18,
    };

    public double LineHeight(ReaderFontFamily family, double fontSize) => fontSize * LineFactor(family);

    public double MeasureHeight(ReaderRichText text, double width, ReaderTypography typography) =>
        Height(text, width, typography, drawn: false);

    public double MeasureDrawnPage(IReadOnlyList<ReaderRichText> blocks, double width, ReaderTypography typography)
    {
        if (blocks.Count == 0) return 0;
        return blocks.Sum(b => b.ImageUrl is not null ? ReaderInlineImage.SlotHeight : Height(b, width, typography, drawn: true))
               + typography.ParagraphSpacing * (blocks.Count - 1);
    }

    private double Height(ReaderRichText text, double width, ReaderTypography t, bool drawn)
    {
        var lines = CountLines(text, drawn ? width * DrawnWidthSlack : width, t);
        if (lines == 0) return 0;
        var lineHeight = LineHeight(t.Family, t.FontSize) + (drawn ? DrawnLineExtra : 0);
        return lines * lineHeight + (lines - 1) * t.LineSpacing;
    }

    private static int CountLines(ReaderRichText text, double width, ReaderTypography t)
    {
        if (text.IsEmpty) return 0;
        var advances = new double[text.Length];
        foreach (var (start, run) in text.RunsWithOffsets())
        {
            var bold = t.BoldText || run.IsBold;
            var advance = t.FontSize * EmAdvance(t.Family) * (bold ? 1.08 : 1) + t.Kerning;
            for (var i = 0; i < run.Text.Length; i++) advances[start + i] = advance;
        }

        var s = text.Text;
        var lines = 0;
        var lineStart = 0;
        while (lineStart <= s.Length)
        {
            var hardEnd = s.IndexOf('\n', lineStart);
            if (hardEnd < 0) hardEnd = s.Length;
            lines += WrapLines(s, advances, lineStart, hardEnd, width);
            if (hardEnd == s.Length) break;
            lineStart = hardEnd + 1;
        }
        return lines;
    }

    /// <summary>Greedy word wrap of s[from, to): spaces at a line end don't count.</summary>
    private static int WrapLines(string s, double[] advances, int from, int to, double width)
    {
        var lines = 1;
        double lineWidth = 0; // width up to the last word's end
        double pendingSpaces = 0;
        var i = from;
        while (i < to)
        {
            if (s[i] == ' ')
            {
                pendingSpaces += advances[i];
                i++;
                continue;
            }
            var wordEnd = i;
            double word = 0;
            while (wordEnd < to && s[wordEnd] != ' ') word += advances[wordEnd++];
            if (lineWidth > 0 && lineWidth + pendingSpaces + word > width)
            {
                lines++;
                lineWidth = 0;
            }
            else
            {
                lineWidth += lineWidth > 0 ? pendingSpaces : 0;
            }
            pendingSpaces = 0;
            // A word wider than the line breaks between characters.
            for (var c = i; c < wordEnd; c++)
            {
                if (lineWidth > 0 && lineWidth + advances[c] > width)
                {
                    lines++;
                    lineWidth = 0;
                }
                lineWidth += advances[c];
            }
            i = wordEnd;
        }
        return lines;
    }
}

/// <summary>Page-by-page pagination on every screen the app runs on, so a layout change
/// made for one (a spread, a desktop window) can't quietly break the others: every
/// sentence lands on exactly one page, and each page, as drawn, neither runs past its
/// page area nor (but a chapter's last) leaves a band of blank space. On Windows the
/// text is laid out by <see cref="FakeTextMeasurer"/>, so the algorithm is checked on
/// any machine; the WinUI app's real measurer plugs into the same code.</summary>
public class ReaderPaginationTests(ITestOutputHelper output)
{
    public sealed record Device(string Name, ReaderSize PageArea, bool IsPhone, ReaderRect? Fold = null);

    /// <summary>The page container: its width × its height with the reader controls
    /// (nav bar, page footer) up. Phone settings cap line length; the fold is in the
    /// page container's space.</summary>
    public static readonly Device[] Devices =
    [
        new("iPhone SE", new ReaderSize(375, 570), true),
        new("iPhone 17", new ReaderSize(402, 694), true),
        new("iPhone 17 Pro Max", new ReaderSize(440, 776), true),
        new("iPhone 17 Pro Max landscape", new ReaderSize(832, 357), true),
        new("iPhone Duo folded", new ReaderSize(466, 520), true),
        new("iPhone Duo unfolded", new ReaderSize(880, 600), true, new ReaderRect(465, 0, 20, 600)),
        new("iPad mini", new ReaderSize(744, 1009), false),
        new("iPad Pro 13-inch", new ReaderSize(1032, 1252), false),
        new("iPad Pro 13-inch landscape", new ReaderSize(1376, 908), false),
        new("Mac window", new ReaderSize(1280, 718), false),
    ];

    /// <param name="WidthPercent">One-page margins (two-page spreads use their own default).</param>
    public sealed record Typography(string Name, ReaderFontFamily Family, double FontSize, double LineSpacing,
                                    double ParagraphSpacing, double Kerning, bool Bold, double WidthPercent)
    {
        public ReaderTypography Reader => new(Family, FontSize, LineSpacing, ParagraphSpacing, Kerning, Bold);
    }

    public static readonly Typography[] Typographies =
    [
        new("default", ReaderFontFamily.NewYork, ReaderMetrics.DefaultFontSize, ReaderMetrics.DefaultLineSpacing,
            ReaderMetrics.DefaultParagraphSpacing, 0, false, 70),
        new("small sans", ReaderFontFamily.Sans, 13, 2, 8, 0, false, 90),
        new("huge bold serif", ReaderFontFamily.Serif, 27, 12, 30, 1.5, true, 100),
    ];

    /// <summary>~3,000 words of plain prose: paragraphs of one to twelve sentences,
    /// dialogue, a little emphasis. Several pages on any screen. (The same seeded
    /// generator as the Swift fixture, so the text is identical.)</summary>
    public static readonly string ChapterHtml = MakeChapterHtml();

    private static string MakeChapterHtml()
    {
        string[] words =
        [
            "the", "rain", "had", "not", "stopped", "since", "morning", "and", "she", "walked",
            "along", "river", "with", "her", "hands", "deep", "in", "pockets", "of", "an", "old",
            "coat", "that", "smelled", "faintly", "woodsmoke", "library", "dust", "quiet",
            "because", "remembered", "everything", "he", "said", "about", "staying", "still",
            "when", "world", "goes", "sideways", "understanding", "a", "to", "was",
        ];
        ulong seed = 42;
        int Next(int n)
        {
            seed = unchecked(seed * 6364136223846793005UL + 1442695040888963407UL);
            return (int)((seed >> 33) % (ulong)n);
        }
        string Sentence()
        {
            var count = 4 + Next(22);
            var picked = new List<string>();
            for (var i = 0; i < count; i++) picked.Add(words[Next(words.Length)]);
            var text = string.Join(' ', picked);
            string[] ends = [".", ".", ".", "?", "!"];
            return text[..1].ToUpperInvariant() + text[1..] + ends[Next(5)];
        }
        var paragraphs = new List<string>();
        for (var i = 0; i < 70; i++)
        {
            var count = i % 9 == 0 ? 12 : 1 + Next(5);
            var sentences = new List<string>();
            for (var k = 0; k < count; k++) sentences.Add(Sentence());
            var text = string.Join(' ', sentences);
            if (i % 6 == 3) text = $"“{Sentence()}” he said.";
            if (i % 11 == 5) text = $"<em>{text}</em>";
            paragraphs.Add($"<p>{text}</p>");
        }
        return string.Concat(paragraphs);
    }

    private static readonly FakeTextMeasurer Measurer = new();

    /// <param name="ViewportHeight">The page's height for content, inside its top and bottom margins.</param>
    private sealed record Layout(double ColumnWidth, double ViewportHeight, int PagesOnScreen);

    private static Layout LayoutFor(Device device, Typography type)
    {
        // As the reader does: a two-page spread when the window is wide enough,
        // both pages paginated at the spread's page width.
        var spread = ReaderSpread.LayoutFor(device.PageArea, device.Fold);
        var percent = spread is null ? type.WidthPercent : ReaderSpread.DefaultWidthPercent;
        var width = ReaderMetrics.TextColumnWidth(spread?.PageWidth ?? device.PageArea.Width, percent, type.FontSize,
                                                  device.IsPhone);
        return new Layout(width, device.PageArea.Height - 2 * ReaderPaginator.PageVerticalMargin, spread is null ? 1 : 2);
    }

    private sealed record Pagination(IReadOnlyList<ChapterPage> Pages, List<ParagraphAtom> Atoms, double ChapterHeaderHeight);

    /// <summary>A chapter after the first (chapter 1 adds the work's title page).
    /// <paramref name="checked"/> false paginates as unchecked adjacent chapters are:
    /// by the quick estimate alone.</summary>
    private static Pagination Paginate(Typography type, Layout layout, bool isFirstChapter = false,
                                       PageStart? start = null, bool @checked = true)
    {
        var atoms = ReaderPaginator.Atoms(ChapterHtml, includeImages: false);
        var header = ReaderPaginator.EstimateChapterHeaderHeight("The Long Way Round", layout.ColumnWidth, type.FontSize,
                                                                 type.Family, Measurer);
        var titleHeader = ReaderPaginator.EstimateTitleHeaderHeight("A Fixture Work", "tester", "tester", null,
                                                                    layout.ColumnWidth, type.FontSize, type.Family, Measurer);
        var pages = ReaderPaginator.PaginateChapter(
            isFirstChapter ? 1 : 2, atoms, layout.ColumnWidth, layout.ViewportHeight, titleHeader, header,
            isFirstChapter, showChapterHeader: true, type.Reader, Measurer,
            // As the reader does for the chapter being read: check every page
            // against the drawn layout.
            drawnHeight: @checked ? Drawn(type, layout) : null,
            startingAt: start);
        return new Pagination(pages, atoms, header);
    }

    private static DrawnHeight Drawn(Typography type, Layout layout) =>
        ReaderPaginator.DrawnHeightMeasure(Measurer, layout.ColumnWidth, type.Reader);

    /// <summary>The page's height as drawn, with the chapter heading's (estimated)
    /// height on the chapter's first page.</summary>
    private static double DrawnHeightOf(ChapterPage page, Pagination result, DrawnHeight measure) =>
        measure(result.Atoms, page.ParagraphIndices) + (page.PageIndex == 0 ? result.ChapterHeaderHeight : 0);

    /// <summary>The most blank space a full page may leave: the paginator's rounding
    /// margin, plus a paragraph gap and a line that didn't fit (a paragraph may start
    /// with a single line at the foot of a page, so nothing more).</summary>
    private static double FillTolerance(Typography type, Layout layout)
    {
        var oneLine = ReaderPaginator.Atoms("<p>Ag</p>", includeImages: false);
        var line = Drawn(type, layout)(oneLine, new IndexRange(0, oneLine.Count)) + type.LineSpacing;
        return ReaderPaginator.Reserve + type.ParagraphSpacing + line + 1;
    }

    private static void AssertEverySentenceOnOnePage(Pagination result, string label)
    {
        var next = 0;
        foreach (var page in result.Pages)
        {
            Assert.True(page.ParagraphIndices.Start == next, $"{label}: gap or overlap before page {page.PageIndex}");
            Assert.False(page.ParagraphIndices.IsEmpty, $"{label}: empty page {page.PageIndex}");
            next = page.ParagraphIndices.End;
        }
        Assert.True(next == result.Atoms.Count, $"{label}: sentences missing from the last page");
    }

    private static void AssertPagesFit(Pagination result, Typography type, Layout layout, string label)
    {
        var measure = Drawn(type, layout);
        foreach (var page in result.Pages)
        {
            var height = DrawnHeightOf(page, result, measure);
            Assert.True(height <= layout.ViewportHeight,
                        $"{label}: page {page.PageIndex} draws {height - layout.ViewportHeight} pt past its area");
        }
    }

    private static void AssertPagesFull(IEnumerable<ChapterPage> pages, Pagination result, Typography type, Layout layout,
                                        string label)
    {
        var measure = Drawn(type, layout);
        var tolerance = FillTolerance(type, layout);
        foreach (var page in pages)
        {
            var blank = layout.ViewportHeight - DrawnHeightOf(page, result, measure);
            Assert.True(blank <= tolerance, $"{label}: page {page.PageIndex} leaves {blank} pt blank (allowed {tolerance})");
        }
    }

    private static void ForEachLayout(Action<Device, Typography, Layout, string> body)
    {
        foreach (var device in Devices)
            foreach (var type in Typographies)
                body(device, type, LayoutFor(device, type), $"{device.Name}, {type.Name}");
    }

    [Fact]
    public void TwoPageSpread_OnlyOnWideWindows()
    {
        var spreads = Devices.Where(d => LayoutFor(d, Typographies[0]).PagesOnScreen == 2).Select(d => d.Name);
        Assert.Equal(["iPhone 17 Pro Max landscape", "iPhone Duo unfolded", "iPad Pro 13-inch landscape", "Mac window"],
                     spreads);
    }

    [Fact]
    public void EverySentenceLandsOnExactlyOnePage()
    {
        ForEachLayout((_, type, layout, label) =>
        {
            var result = Paginate(type, layout);
            Assert.True(result.Pages.Count >= 3, $"{label}: the fixture should span several pages");
            AssertEverySentenceOnOnePage(result, label);
        });
    }

    [Fact]
    public void FirstChapter_OpensOnTheTitlePage()
    {
        ForEachLayout((_, type, layout, label) =>
        {
            var pages = Paginate(type, layout, isFirstChapter: true).Pages;
            Assert.True(pages[0].ParagraphIndices == new IndexRange(0, 0), $"{label}: page 0 is the title page");
            Assert.True(pages[1].ParagraphIndices.Start == 0, $"{label}: text starts on page 1");
        });
    }

    [Fact]
    public void PagesFitTheirPageArea()
    {
        // Runs past it and the page's last lines sit under the footer.
        ForEachLayout((_, type, layout, label) => AssertPagesFit(Paginate(type, layout), type, layout, label));
    }

    [Fact]
    public void UncheckedPages_StillFitTheirPageArea()
    {
        // The chapters either side of the one being read may skip the check against
        // the drawn layout (they're re-paginated, checked, once reached); the
        // estimate's headroom must keep them on screen meanwhile. (The Swift test
        // skips on the Mac, which checks every chapter; here the fake measurer's
        // estimate is conservative like iOS's, so it always runs.)
        ForEachLayout((_, type, layout, label) =>
            AssertPagesFit(Paginate(type, layout, @checked: false), type, layout, $"{label}, unchecked"));
    }

    [Fact]
    public void PagesFillTheirPageArea()
    {
        // The blank-band regression: every page but a chapter's last is full.
        ForEachLayout((_, type, layout, label) =>
        {
            var result = Paginate(type, layout);
            AssertPagesFull(result.Pages.SkipLast(1), result, type, layout, label);
        });
    }

    [Fact]
    public void RepaginatingFromOneOfItsOwnPageBreaks_ChangesNothing()
    {
        // Re-opening on a page, or a re-pagination that doesn't change the page
        // area: the same pages, paired into spreads as before (a kept page only
        // opens a spread of its own when pairing would put it on the right).
        ForEachLayout((_, type, layout, label) =>
        {
            var before = Paginate(type, layout, isFirstChapter: true);
            var lefts = before.Pages.Where(p => p.PageIndex % 2 == 0 && !p.ParagraphIndices.IsEmpty).ToList();
            var start = ReaderPaginator.Start(lefts[lefts.Count / 2], before.Atoms);
            Assert.True(start is not null, $"{label}: no text on a mid-chapter page");
            var after = Paginate(type, layout, isFirstChapter: true, start: start);
            Assert.True(after.Pages.Select(p => p.ParagraphIndices).SequenceEqual(before.Pages.Select(p => p.ParagraphIndices)),
                        label);
            Assert.False(after.Pages.Any(p => p.StartsSpread), $"{label}: a spread re-paired");
        });
    }

    /// <summary>The nav bar and page footer on an iPhone: what the page area gains when
    /// the controls hide, and loses when they show.</summary>
    public const double ControlsHeight = 84;

    [Fact]
    public void ShowingOrHidingTheControls_KeepsThePageInPlace()
    {
        // Pages fill the area on screen either way: hiding the controls used to
        // leave their room blank at the foot of every page. Re-paginating starts a
        // page where the one on screen did, so it keeps its first line.
        ForEachLayout((_, type, layout, label) =>
        {
            var before = Paginate(type, layout);
            var page = before.Pages[before.Pages.Count / 2];
            var pageStart = ReaderPaginator.Start(page, before.Atoms);
            Assert.NotNull(pageStart);
            var firstWords = before.Atoms[page.ParagraphIndices.Start].Text.Text;
            foreach (var change in new[] { ControlsHeight, -ControlsHeight })
            {
                var context = $"{label}, {(change > 0 ? "controls hidden" : "controls shown")}";
                var resized = layout with { ViewportHeight = layout.ViewportHeight + change };
                var after = Paginate(type, resized, start: pageStart);
                // The page kept in place starts where it did.
                var keptPage = after.Pages.FirstOrDefault(p => ReaderPaginator.Start(p, after.Atoms) == pageStart);
                Assert.True(keptPage is not null, $"{context}: no page starts where the one on screen did");
                var keptWords = after.Atoms[keptPage.ParagraphIndices.Start].Text.Text;
                var n = Math.Min(firstWords.Length, keptWords.Length);
                Assert.True(keptWords[..n] == firstWords[..n], $"{context}: the kept page opens with the same words");
                AssertEverySentenceOnOnePage(after, context);
                AssertPagesFit(after, type, resized, context);
                // From the kept page on, pages fill the new area (the one before it may be short).
                AssertPagesFull(after.Pages.SkipWhile(p => p.Id != keptPage.Id).SkipLast(1), after, type, resized, context);
                if (layout.PagesOnScreen == 2)
                    Assert.True(ReaderSpread.Spreads(after.Pages).Any(s => s.Left.Id == keptPage.Id),
                                $"{context}: the kept page stays on the left of its spread");
            }
        });
    }

    // MARK: - Windows port additions

    [Fact]
    public void ImageSlotsAreBudgetedAtTheirFixedHeight()
    {
        var atoms = ReaderPaginator.Atoms("<p>Before.</p><img src=\"https://example.com/a.png\"><p>After.</p>", includeImages: true);
        Assert.Equal(3, atoms.Count);
        Assert.Equal(ReaderInlineImage.SlotHeight,
                     ReaderPaginator.CalculateHeight(atoms[1].Text, 300, Typographies[0].Reader, Measurer));
        var pages = ReaderPaginator.PaginateChapter(2, atoms, 300, 600, 0, 0, false, false, Typographies[0].Reader, Measurer,
                                                    ReaderPaginator.DrawnHeightMeasure(Measurer, 300, Typographies[0].Reader));
        Assert.Single(pages);
        Assert.Equal(new IndexRange(0, 3), pages[0].ParagraphIndices);
    }

    [Fact]
    public void PerformPagination_PaginatesTheChapterAndItsNeighboursAndFindsTheKeptPage()
    {
        AO3ChapterPayload[] chapters = [new(1, "One", ChapterHtml), new(2, "Two", ChapterHtml), new(3, "Three", ChapterHtml), new(4, "Four", ChapterHtml)];
        var trigger = new PaginationTrigger(2, 18, "newYork", 70, 6, 16, 0, false, false, new ReaderSize(402, 694));
        var result = ReaderPaginator.PerformPagination(trigger, null, chapters, "A Work", "tester", "tester", null,
                                                       limitLineLength: true, Measurer);
        Assert.Equal([1, 2, 3], result.Pages.Select(p => p.ChapterIndex).Distinct());
        Assert.Equal([1, 2, 3], result.Atoms.Keys.Order());
        Assert.Null(result.KeptPageId);
        // Chapter 1 opens on the title page.
        Assert.Equal(new IndexRange(0, 0), result.Pages.First(p => p.ChapterIndex == 1).ParagraphIndices);

        var page = result.Pages.Where(p => p.ChapterIndex == 2).ElementAt(3);
        var start = ReaderPaginator.Start(page, result.Atoms[2]);
        var again = ReaderPaginator.PerformPagination(trigger with { Size = new ReaderSize(402, 778) }, start, chapters,
                                                      "A Work", "tester", "tester", null, true, Measurer);
        Assert.NotNull(again.KeptPageId);
        var kept = again.Pages.Single(p => p.Id == again.KeptPageId);
        Assert.Equal(start, ReaderPaginator.Start(kept, again.Atoms[2]));

        // Too small to paginate: nothing.
        Assert.Empty(ReaderPaginator.PerformPagination(trigger with { Size = new ReaderSize(40, 694) }, null, chapters,
                                                       "A Work", "", "", null, true, Measurer).Pages);
        output.WriteLine($"{result.Pages.Count} pages across three chapters");
    }
}
