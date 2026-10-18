using System.Drawing;
using System.Text.RegularExpressions;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;
using Xunit.Abstractions;

namespace Fanficly.UITests;

/// <summary>
/// The page-by-page reader's layout as drawn, like the Apple app's
/// <c>ReaderLayoutTests</c>: the page footer sits on the bottom edge, each page's
/// text ends just above it (never under it, never far short of it), and
/// minimizing the window, a dialog, or hiding the controls doesn't move the
/// page. A wide window shows a two-page spread exactly when
/// <c>ReaderSpread</c>'s rule says so. Demo mode with long chapters, so a page
/// mid-chapter is always full. Each step saves a picture to
/// <c>reader-layout/</c> before its checks, so a failure still leaves one.
/// </summary>
public sealed partial class ReaderLayoutTests(ITestOutputHelper output)
{
    /// <summary>The most blank space a full page may leave under its last line:
    /// the bottom margin, a paragraph gap and a line that didn't fit.</summary>
    private const double MaxBlankBelowText = 75;

    private static readonly string[] LaunchArgs =
    [
        "-demoLongChapters",
        "-set", "reader.mode.windows=pageByPage",
        "-set", "reader.fontSizePt.windows=18",
        "-set", "reader.lineSpacingPt.windows=6",
        "-set", "reader.paragraphSpacingPt.windows=16",
        "fanficly://resume/90001",
    ];

    private static readonly FormFactor Laptop = new("laptop", 1280, 860);
    private static readonly FormFactor Narrow = new("narrow", 760, 1000);

    private static string Folder =>
        Path.Combine(Environment.GetEnvironmentVariable("FANFICLY_SCREENSHOTS") is { Length: > 0 } dir
            ? dir : Path.Combine(AppSession.WindowsRoot, "artifacts", "screenshots"), "reader-layout");

    [Fact]
    public void PagesFillTheScreen()
    {
        using var s = AppSession.Launch(Narrow, LaunchArgs);
        var footer = OpenReader(s);
        TurnToMiddlePage(s, footer);
        s.Snap(Folder, "01-page");
        AssertPageLayout(s, footer, "on opening");
    }

    [Fact]
    public void MinimizingKeepsThePageLayout()
    {
        using var s = AppSession.Launch(Narrow, LaunchArgs);
        var footer = OpenReader(s);
        TurnToMiddlePage(s, footer);
        var before = footer.Name;
        s.Window.Patterns.Window.Pattern.SetWindowVisualState(WindowVisualState.Minimized);
        s.Settle(2000);
        s.Window.Patterns.Window.Pattern.SetWindowVisualState(WindowVisualState.Normal);
        s.Settle(1500);
        footer = s.ById("reader.pageFooter", 8)!;
        Assert.NotNull(footer);
        s.Snap(Folder, "02-after-minimizing");
        Assert.Equal(before, footer.Name);
        AssertPageLayout(s, footer, "after minimizing");
    }

    [Fact]
    public void TogglingTheControlsFillsThePageAndKeepsItInPlace()
    {
        using var s = AppSession.Launch(Narrow, LaunchArgs);
        var footer = OpenReader(s);
        TurnToMiddlePage(s, footer);
        AssertFullScreenFillsThePage(s, footer, "one page", ("03-full-screen", "04-controls-back"));
    }

    /// <summary>The reader's only text box: naming a new settings profile. A
    /// dialog over the page mustn't repaginate it.</summary>
    [Fact]
    public void ADialogLeavesTheFooterAndPagesAlone()
    {
        using var s = AppSession.Launch(Narrow, LaunchArgs);
        var footer = OpenReader(s);
        TurnToMiddlePage(s, footer);
        var before = footer.Name;
        Assert.True(s.Tap(4, "reader.aa", "Reader settings"), "the Aa menu");
        // Menus open in their own popup windows; search every window of the app.
        AutomationElement? Item(Func<string, bool> match) =>
            s.App.GetAllTopLevelWindows(s.Automation).Prepend(s.Window)
                .SelectMany(w => w.FindAllDescendants())
                .FirstOrDefault(e => match(e.Properties.Name.ValueOrDefault ?? ""));
        var newProfile = Item(n => n.StartsWith("Save Current as New Profile", StringComparison.Ordinal));
        if (newProfile is null)
        {
            if (Item(n => n.StartsWith("Profile", StringComparison.Ordinal)) is { } profile) s.Activate(profile);
            newProfile = Retry.WhileNull(() => Item(n => n.StartsWith("Save Current as New Profile", StringComparison.Ordinal)),
                TimeSpan.FromSeconds(3)).Result;
        }
        Assert.NotNull(newProfile);
        s.Activate(newProfile!);
        var box = Retry.WhileNull(() => s.App.GetAllTopLevelWindows(s.Automation).Prepend(s.Window)
            .Select(w => w.FindFirstDescendant(cf => cf.ByControlType(ControlType.Edit))).FirstOrDefault(e => e is not null),
            TimeSpan.FromSeconds(4)).Result;
        Assert.NotNull(box);
        box!.Focus();
        s.Type("Test");
        s.Snap(Folder, "05-dialog-up");
        s.Keys(VirtualKeyShort.ESCAPE);
        s.Settle(1000);
        footer = s.ById("reader.pageFooter", 6)!;
        s.Snap(Folder, "06-after-dialog");
        Assert.Equal(before, footer.Name);
        AssertPageLayout(s, footer, "after the dialog");
    }

    [Fact]
    public void WideWindowShowsTwoFullPages()
    {
        using var s = AppSession.Launch(Narrow, LaunchArgs);
        var footer = OpenReader(s);
        TurnToMiddlePage(s, footer);
        s.Resize(Laptop);
        s.Settle(2000);
        footer = s.ById("reader.pageFooter", 8)!;
        Assert.NotNull(footer);
        // Same rule as ReaderSpread.Layout: at least 700 wide, 1.15× wider than
        // tall, and two pages of at least 280 with a 56 gutter.
        var bar = footer.BoundingRectangle;
        var pageHeight = bar.Top - ReaderTop(s);
        var expectSpread = bar.Width >= 700 && bar.Width >= pageHeight * 1.15 && (bar.Width - 56) / 2.0 >= 280;
        Assert.True(Page(footer)?.IsSpread == expectSpread, $"{bar.Width}×{pageHeight} window shows {footer.Name}");
        TurnToMiddlePage(s, footer);
        s.Snap(Folder, "07-wide-window");
        AssertPageLayout(s, footer, "in a wide window");
        AssertFullScreenFillsThePage(s, footer, "in a wide window", ("08-wide-full-screen", "09-wide-controls-back"));
    }

    // MARK: - Navigation

    private AutomationElement OpenReader(AppSession s)
    {
        var footer = s.ById("reader.pageFooter", 25);
        Assert.True(footer is not null, "the page-by-page footer");
        Retry.WhileTrue(() => s.ById("reader.pageFooter", 1)?.Name == "Laying out pages", TimeSpan.FromSeconds(10));
        s.Settle(800);
        return s.ById("reader.pageFooter")!;
    }

    /// <summary>Turns forward until what's on screen is a full page in the
    /// middle of a chapter: not its first page nor its last (which may be short).</summary>
    private void TurnToMiddlePage(AppSession s, AutomationElement footer)
    {
        for (var i = 0; i < 12; i++)
        {
            footer = s.ById("reader.pageFooter", 3) ?? footer;
            if (Page(footer) is { } page && page.First >= 3 && page.Last < page.Total) return;
            var before = footer.Name;
            var bar = footer.BoundingRectangle;
            Mouse.Click(new Point(bar.Left + (int)(bar.Width * 0.9), bar.Top - 120)); // the turn-forward third
            Retry.WhileTrue(() => s.ById("reader.pageFooter", 1)?.Name == before, TimeSpan.FromSeconds(3));
        }
        Assert.Fail($"never reached a page mid-chapter: {footer.Name}");
    }

    private sealed record PageInfo(int First, int Last, int Total)
    {
        public bool IsSpread => Last > First;
    }

    /// <summary>"Chapter 1: Landfall, page 3 of 12" / "…, pages 3–4 of 12".</summary>
    private static PageInfo? Page(AutomationElement footer)
    {
        var m = PageLabel().Match(footer.Name);
        if (!m.Success) return null;
        var first = int.Parse(m.Groups[1].Value);
        var last = m.Groups[2].Success ? int.Parse(m.Groups[2].Value) : first;
        return new PageInfo(first, last, int.Parse(m.Groups[3].Value));
    }

    [GeneratedRegex(@"pages? (\d+)(?:[–-](\d+))? of (\d+)", RegexOptions.IgnoreCase)]
    private static partial Regex PageLabel();

    // MARK: - Layout checks

    private void AssertFullScreenFillsThePage(AppSession s, AutomationElement footer, string context, (string Hidden, string Shown) shots)
    {
        var bar = footer.BoundingRectangle;
        var shown = StoryTexts(s, bar.Top, bar);
        var firstWords = OpeningWords(shown);
        Assert.True(firstWords is not null, $"{context}: text on the page");
        // The middle third of the page shows or hides the controls.
        var middle = new Point(bar.Left + bar.Width / 2, bar.Top - 200);
        Mouse.Click(middle);
        Assert.True(Retry.WhileFalse(() => s.Window.FindFirstDescendant(cf => cf.ByAutomationId("reader.pageFooter")) is null,
            TimeSpan.FromSeconds(5)).Result, $"{context}: the controls hid");
        s.Settle(1200);
        s.Snap(Folder, shots.Hidden);
        // The footer's bottom edge is the page area's.
        var hidden = StoryTexts(s, bar.Bottom, bar);
        Assert.Equal(firstWords, OpeningWords(hidden));
        bool TwoPages(List<(Rectangle Frame, string Text)> texts) =>
            texts.Any(t => t.Frame.Left > bar.Left + bar.Width / 2) && texts.Any(t => t.Frame.Right < bar.Left + bar.Width / 2);
        Assert.True(TwoPages(hidden) == TwoPages(shown), $"{context}: full screen switched between one page and two");
        AssertPagesFull(hidden, bar.Bottom, TwoPages(shown), bar, $"{context}, full screen");
        int Top(List<(Rectangle Frame, string Text)> texts) => texts.Count == 0 ? 0 : texts.Min(t => t.Frame.Top);
        int Chars(List<(Rectangle Frame, string Text)> texts) => texts.Sum(t => t.Text.Length);
        var gained = bar.Height + Top(shown) - Top(hidden);
        if (gained >= 60)
            Assert.True(Chars(hidden) > Chars(shown), $"{context}: full screen gained {gained} px but the page holds no more text");
        else
            Assert.True(Chars(hidden) >= Chars(shown), $"{context}: full screen lost text");
        Mouse.Click(middle);
        var back = s.ById("reader.pageFooter", 5);
        Assert.True(back is not null, $"{context}: the controls came back");
        s.Settle(1200);
        s.Snap(Folder, shots.Shown);
        Assert.Equal(firstWords, OpeningWords(StoryTexts(s, back!.BoundingRectangle.Top, back.BoundingRectangle)));
        AssertPageLayout(s, back, $"{context}, after toggling the controls");
    }

    /// <summary>The footer sits on the bottom edge, and each page on screen is
    /// full: its text ends just above the footer, not short of it and not under it.</summary>
    private void AssertPageLayout(AppSession s, AutomationElement footer, string context)
    {
        var window = s.Window.BoundingRectangle;
        var bar = footer.BoundingRectangle;
        output.WriteLine($"{context}: footer {bar}, window {window}, {footer.Name}");
        Assert.True(bar.Height < 60, $"{context}: the footer is {bar.Height} px tall");
        Assert.True(bar.Bottom >= window.Bottom - 50, $"{context}: the footer ends {window.Bottom - bar.Bottom} px above the bottom");
        AssertPagesFull(StoryTexts(s, bar.Top, bar), bar.Top, Page(footer)?.IsSpread == true, bar, $"{context} ({footer.Name})");
    }

    private void AssertPagesFull(List<(Rectangle Frame, string Text)> texts, int edge, bool spread, Rectangle bar, string context)
    {
        var mid = bar.Left + bar.Width / 2;
        var pages = spread ? new[] { (bar.Left, mid), (mid, bar.Right) } : new[] { (bar.Left, bar.Right) };
        foreach (var (minX, maxX) in pages)
        {
            var which = pages.Length > 1 ? (minX == bar.Left ? "left page" : "right page") : "page";
            var onPage = texts.Where(t => t.Frame.Left + t.Frame.Width / 2 >= minX && t.Frame.Left + t.Frame.Width / 2 < maxX).ToList();
            Assert.True(onPage.Count > 0, $"{context}: no text on the {which}");
            var bottom = onPage.Max(t => t.Frame.Bottom);
            Assert.True(bottom <= edge + 1, $"{context}: the {which}'s text runs {bottom - edge} px past the page area");
            Assert.True(bottom >= edge - MaxBlankBelowText, $"{context}: {edge - bottom} px blank under the {which}'s text");
        }
    }

    /// <summary>The story text on the page(s) on screen, above <paramref name="bottom"/>
    /// and within the footer's width.</summary>
    private static List<(Rectangle Frame, string Text)> StoryTexts(AppSession s, int bottom, Rectangle bar)
    {
        var root = s.Window.FindFirstDescendant(cf => cf.ByAutomationId("reader.content")) ?? s.Window;
        var pages = root.FindAllDescendants(cf => cf.ByAutomationId("reader.page.left").Or(cf.ByAutomationId("reader.page.right")));
        var scope = pages.Length > 0 ? pages : [root];
        return scope.SelectMany(p => p.FindAllDescendants(cf => cf.ByControlType(ControlType.Text)))
            .Where(e => !e.IsOffscreen)
            .Select(e => (Frame: e.BoundingRectangle, Text: e.Name ?? ""))
            .Where(t => t.Frame.Height > 0 && t.Text.Length > 0 && t.Frame.Top < bottom
                        && t.Frame.Left >= bar.Left - 1 && t.Frame.Right <= bar.Right + 1)
            .ToList();
    }

    /// <summary>The first words of the topmost (then leftmost) text on screen.</summary>
    private static string? OpeningWords(List<(Rectangle Frame, string Text)> texts) =>
        texts.OrderBy(t => t.Frame.Left > texts.Min(x => x.Frame.Left) + 40 ? 1 : 0).ThenBy(t => t.Frame.Top)
            .Select(t => string.Join(' ', t.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(6)))
            .FirstOrDefault();

    /// <summary>The top of the reader's page area (below the header).</summary>
    private static int ReaderTop(AppSession s) =>
        (s.Window.FindFirstDescendant(cf => cf.ByAutomationId("reader.content")) ?? s.Window).BoundingRectangle.Top;
}
