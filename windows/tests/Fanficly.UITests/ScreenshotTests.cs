using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;
using Xunit.Abstractions;

namespace Fanficly.UITests;

/// <summary>
/// Walks the demo app through the same screens as the Apple app's
/// <c>ScreenshotTests.runCaptureFlow</c> and saves each as a PNG, with the
/// same names (01-home … 12-bookmarks), at three window sizes. Output goes to
/// <c>FANFICLY_SCREENSHOTS</c>, else <c>windows/artifacts/screenshots</c>, one
/// folder per size. A screen that can't be reached is reported, and the test
/// fails if any are missing, so a stale picture can't go unnoticed.
/// </summary>
public sealed class ScreenshotTests(ITestOutputHelper output)
{
    private static string OutputRoot =>
        Environment.GetEnvironmentVariable("FANFICLY_SCREENSHOTS") is { Length: > 0 } dir
            ? dir
            : Path.Combine(AppSession.WindowsRoot, "artifacts", "screenshots");

    /// <summary>Every icon the app uses, a page at a time, into <c>icons/</c>, and
    /// fails naming any icon this PC's icon font can't draw (it would show as
    /// an empty box).</summary>
    [Fact]
    public void CaptureIconGallery()
    {
        using var s = AppSession.Launch(FormFactor.Desktop, "-iconGallery");
        Assert.True(s.WaitForHeader("Icons", 10), "The icon gallery didn't open.");
        var folder = Path.Combine(OutputRoot, "icons");
        var scroller = s.Window.FindAllDescendants()
            .FirstOrDefault(e => e.Patterns.Scroll.PatternOrDefault?.VerticallyScrollable.ValueOrDefault == true);
        var scroll = scroller?.Patterns.Scroll.PatternOrDefault;
        var viewSize = Math.Max(5, scroll?.VerticalViewSize.ValueOrDefault ?? 100);
        for (var page = 0; page < 20; page++)
        {
            var percent = Math.Min(100, page * viewSize * 0.95);
            scroll?.SetScrollPercent(-1, percent);
            s.Settle(500);
            s.Snap(folder, $"icons-{page + 1}");
            if (scroll is null || percent >= 100) break;
        }

        var missing = new List<string>();
        var checkedCount = 0;
        foreach (var text in s.Window.FindAllDescendants(cf => cf.ByControlType(FlaUI.Core.Definitions.ControlType.Text)))
        {
            var m = System.Text.RegularExpressions.Regex.Match(text.Properties.Name.ValueOrDefault ?? "", @"^(\S+)\s+U\+([0-9A-F]{4,5})$");
            if (!m.Success) continue;
            checkedCount++;
            var cp = Convert.ToInt32(m.Groups[2].Value, 16);
            if (!IconFont.CanDraw(cp, out var family)) missing.Add($"{m.Groups[1].Value} U+{cp:X4} ({family})");
        }
        output.WriteLine($"Checked {checkedCount} icons.");
        foreach (var m in missing) output.WriteLine($"MISSING-ICON {m}");
        Assert.True(checkedCount > 0, "No icons found in the gallery.");
        Assert.True(missing.Count == 0, $"Icons the font can't draw: {string.Join(", ", missing)}");
    }

    [Theory]
    [InlineData("desktop")]
    [InlineData("tablet")]
    [InlineData("compact")]
    [InlineData("store")]
    public void CaptureMainScreens(string size)
    {
        var folder = Path.Combine(OutputRoot, size);
        var missing = new List<string>();
        var taken = new List<string>();

        void Snap(AppSession s, string name)
        {
            taken.Add(s.Snap(folder, name));
            output.WriteLine($"saved {name}");
        }

        void Step(string name, Func<bool> reach, AppSession s, int settle = 900)
        {
            bool ok;
            try { ok = reach(); }
            catch (Exception e) { output.WriteLine($"{name}: {e.Message}"); ok = false; }
            if (!ok) { missing.Add(name); return; }
            s.Settle(settle);
            Snap(s, name);
        }

        using (var s = AppSession.Launch(FormFactor.Named(size)))
        {
            s.Settle(900);
            Snap(s, "01-home");

            Step("04-library", () => s.OpenTab("library"), s);
            Step("05-browse", () => s.OpenTab("browse"), s);
            Step("05-browse-fandoms", () => s.Tap(6, "TV Shows") && s.ByIdPrefix("browse.fandom.", 8) is not null || s.HeaderTitle == "TV Shows", s);
            s.GoBack();
            Step("10-popular", () => s.OpenTab("popular"), s);
            Step("06-recently-viewed", () => s.OpenTab("recentlyViewed"), s);
            Step("12-bookmarks", () => s.OpenTab("bookmarks") && s.ByIdPrefix("work.", 8) is not null, s);
            Step("07-reader-settings", () => s.OpenTab("settings") && s.Tap(6, "settings.reader", "Theme & typography"), s);
            s.GoBack();
            Step("08-privacy", () => s.WaitForHeader("Settings", 4) && s.Tap(6, "settings.privacy", "What this app sees and stores"), s);
        }

        // Search, the reader, comments and narration last, from a fresh launch,
        // as on Apple platforms: a reader left open would sit under the other tabs.
        using (var s = AppSession.Launch(FormFactor.Named(size)))
        {
            Step("02-search-results", () =>
            {
                if (!s.OpenTab("search")) return false;
                var box = s.Find(6, "search.box");
                if (box is null) return false;
                box.Focus();
                s.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_A);
                // The end state of tapping the "Slow Burn" suggestion and typing
                // "complete": two chips over a page of results.
                s.Type("tag:\"Slow Burn\" complete");
                s.Keys(VirtualKeyShort.ENTER);
                return s.ByIdPrefix("work.", 10) is not null;
            }, s);

            Step("03-reader", () =>
            {
                if (s.ByIdPrefix("work.", 4) is not { } row) return false;
                var before = s.HeaderTitle;
                s.Activate(row);
                return s.Find(10, "reader.content", "reader.page") is not null
                       || Retry.WhileFalse(() => s.HeaderTitle != before, TimeSpan.FromSeconds(8)).Result;
            }, s, settle: 1500);

            Step("11-comments", () =>
            {
                if (!s.Tap(4, "work.options", "Work options")) return false;
                if (!s.Tap(4, "work.options.comments", "Comments")) return false;
                return s.Find(8, "comments.list", "comment.composer", "comments.composer") is not null;
            }, s, settle: 1200);
            // Close the comments (a sheet closes with Esc; a page goes back).
            s.Keys(VirtualKeyShort.ESCAPE);
            if (s.Find(1, "comments.list") is not null) s.GoBack();

            Step("09-tts", () =>
            {
                if (s.Tap(3, "reader.listen", "Listen to chapter", "Listen")) return true;
                return s.Tap(3, "reader.aa", "Reader settings")
                       && s.Tap(4, "reader.listen", "Listen to chapter", "Listen");
            }, s, settle: 1500);
            s.Tap(1, "speech.stop", "Stop");
        }

        output.WriteLine($"{taken.Count} screenshots in {folder}");
        Assert.True(missing.Count == 0, $"Couldn't reach: {string.Join(", ", missing)}");
    }

    /// <summary>The reader page by page, a page into the chapter: a two-page
    /// spread on a wide window, one page on an upright one. "store" and
    /// "store-tablet" feed the Store art (windows/scripts/make_store_art.py).</summary>
    [Theory]
    [InlineData("desktop")]
    [InlineData("tablet")]
    [InlineData("store")]
    [InlineData("store-tablet")]
    public void CaptureReaderPages(string size)
    {
        var folder = Path.Combine(OutputRoot, size);
        using var s = AppSession.Launch(FormFactor.Named(size),
            "-demoLongChapters", "-set", "reader.mode.windows=pageByPage", "fanficly://resume/90001");
        var footer = s.ById("reader.pageFooter", 25);
        Assert.True(footer is not null, "The page-by-page reader didn't open.");
        Retry.WhileTrue(() => s.ById("reader.pageFooter", 1)?.Name == "Laying out pages", TimeSpan.FromSeconds(10));
        s.Settle(800);
        // Past the chapter's title page, by keyboard: in a capture-scale window
        // most of the page is off the screen, where a click can't reach.
        var before = s.ById("reader.pageFooter", 2)?.Name;
        s.Keys(VirtualKeyShort.NEXT);
        Retry.WhileTrue(() => s.ById("reader.pageFooter", 1)?.Name == before, TimeSpan.FromSeconds(4));
        s.Settle(1200);
        output.WriteLine($"{size}: {s.ById("reader.pageFooter", 2)?.Name}");
        s.Snap(folder, "13-reader-spread");
    }
}
