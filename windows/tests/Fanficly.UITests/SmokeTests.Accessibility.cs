using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace Fanficly.UITests;

/// <summary>Narrator names (RM-019): the icon-only buttons on Library, Stats,
/// Subscriptions and Settings say what they do. Part of <see cref="SmokeTests"/>,
/// so CI's smoke step runs it.</summary>
public sealed partial class SmokeTests
{
    [Fact]
    public void IconOnlyButtonsHaveNarratorNames()
    {
        using var s = AppSession.Launch(Laptop);
        var problems = new List<string>();

        void Expect(string id, string name, bool prefix = false)
        {
            if (s.ById(id, 6) is not { } element)
            {
                problems.Add($"{id}: not found");
                return;
            }
            var actual = element.Name ?? "";
            var ok = prefix ? actual.StartsWith(name, StringComparison.Ordinal) : actual == name;
            if (!ok) problems.Add($"{id}: named \"{actual}\", expected \"{name}\"{(prefix ? "…" : "")}");
        }

        // Library: the sort button (an arrow glyph) and the stats strip.
        Assert.True(s.OpenTab("library"), "Library didn't open.");
        Expect("library.sort", "Sort");
        Expect("library.statsStrip", "Reading stats: ", prefix: true);

        // Stats: Share, and the ‹ › pager, which a dated period shows.
        Assert.True(s.OpenTab("stats"), "Stats didn't open.");
        Expect("stats.share", "Share");
        Assert.True(s.Tap(4, "stats.period.week"), "No Week period on Stats.");
        Expect("stats.prev", "Previous week");
        Expect("stats.next", "Next week");

        // Subscriptions (demo mode is signed in as demo_reader): Refresh.
        Assert.True(s.OpenTab("subscriptions"), "Subscriptions didn't open.");
        Expect("subscriptions.refresh", "Refresh subscriptions");

        // Settings → Theme & typography: the − / + beside each slider.
        Assert.True(s.OpenTab("settings"), "Settings didn't open.");
        Assert.True(s.Tap(6, "settings.reader", "Theme & typography"), "Theme & typography didn't open.");
        Expect("settings.reader.fontSize.decrease", "Decrease Text size");
        Expect("settings.reader.fontSize.increase", "Increase Text size");
        Expect("settings.reader.margins.decrease", "Decrease Margins");
        Expect("settings.reader.margins.increase", "Increase Margins");

        Assert.True(s.IsRunning);
        Assert.True(problems.Count == 0, $"Icon-only buttons without the right Narrator name: {string.Join("; ", problems)}");
    }

    /// <summary>#178: opening a page with the keyboard moves focus into it, and Back
    /// puts focus on the row that opened it (the Library rebuilds its rows when it
    /// reappears, so this also covers a restore by index).</summary>
    [Fact]
    public void FocusMovesInOnOpenAndReturnsOnBack()
    {
        using var s = AppSession.Launch(Laptop);
        string FocusedId() => s.Automation.FocusedElement()?.Properties.AutomationId.ValueOrDefault ?? "";

        // Browse → TV Shows (a pushed screen) and back.
        Assert.True(s.OpenTab("browse"), "Browse didn't open.");
        var root = s.HeaderTitle;
        const string cardId = "browse.category.tv-shows";
        var card = s.ById(cardId, 6);
        Assert.NotNull(card);
        card!.Focus();
        s.Settle(300);
        s.Keys(VirtualKeyShort.RETURN);
        Assert.True(Retry.WhileFalse(() => s.HeaderTitle != root, TimeSpan.FromSeconds(6)).Result, "TV Shows didn't open.");
        Assert.True(Retry.WhileFalse(() => FocusedId().StartsWith("browse.fandom.", StringComparison.Ordinal),
            TimeSpan.FromSeconds(4)).Result, $"Focus didn't move to TV Shows' first fandom (it's on \"{FocusedId()}\").");
        s.GoBack();
        Assert.True(s.WaitForHeader(root), "Alt+Left didn't go back.");
        Assert.True(Retry.WhileFalse(() => FocusedId() == cardId, TimeSpan.FromSeconds(4)).Result,
            $"Back didn't return focus to {cardId} (it's on \"{FocusedId()}\").");

        // Library → a work in the reader and back.
        Assert.True(s.OpenTab("library"), "Library didn't open.");
        var row = s.ByIdPrefix("library.work.", 8);
        Assert.NotNull(row);
        var rowId = row!.Properties.AutomationId.ValueOrDefault ?? "";
        row.Focus();
        s.Settle(300);
        s.Keys(VirtualKeyShort.RETURN);
        Assert.NotNull(s.ById("reader.root", 15));
        s.Settle();
        s.GoBack();
        Assert.True(s.WaitForHeader("Library"), "Alt+Left didn't leave the reader.");
        Assert.True(Retry.WhileFalse(() => FocusedId() == rowId, TimeSpan.FromSeconds(4)).Result,
            $"Back didn't return focus to {rowId} (it's on \"{FocusedId()}\").");
    }
}
