using System.Globalization;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Fanficly.App.Views.Library;

/// <summary>
/// One saved story in the Library or a folder (LibraryRow): title with
/// pinned / starred / downloaded badges, author, first fandom, metadata pills
/// (rating, words, chapters, folders) and — for any started work — a
/// reading-progress bar with "% read · Ch n" or "Finished" and when it was
/// last read. Narrator reads the row as one element.
/// </summary>
public static class LibraryRow
{
    /// <summary>"library.showReadingProgress" (Settings → Library), default on.</summary>
    public const string ShowReadingProgressKey = "library.showReadingProgress";

    public static bool IsFinished(double progress, bool isComplete) => progress >= 0.99 || (isComplete && progress >= 0.95);

    /// <summary>The row's content and its Narrator label.</summary>
    public static (FrameworkElement Content, string AccessibleName) Build(Work work, bool downloaded)
    {
        var spoken = new List<string> { work.Title, $"by {work.AuthorName}" };

        // Title + status badges.
        var titleRow = UI.UI.Grid("*,Auto", columnSpacing: 8);
        // Line limits lift at large text sizes, so nothing ends in "…".
        titleRow.Children.Add(UI.UI.Text(work.Title, Theme.Style.Headline, maxLines: UI.UI.LineLimit(2)).Col(0));
        var badges = UI.UI.HStack(5);
        badges.VerticalAlignment = VerticalAlignment.Top;
        badges.Margin = new Thickness(0, 3, 0, 0);
        if (work.IsPinned) { badges.Children.Add(UI.UI.Icon("pin.fill", 11, Theme.Accent)); spoken.Add("Pinned"); }
        if (work.IsStarred) { badges.Children.Add(UI.UI.Icon("star.fill", 11, Theme.Warning)); spoken.Add("Starred"); }
        if (downloaded) { badges.Children.Add(UI.UI.Icon("arrow.down.circle.fill", 11, Theme.Success)); spoken.Add("Downloaded"); }
        titleRow.Children.Add(badges.Col(1));

        var stack = UI.UI.VStack(6, titleRow, UI.UI.Secondary($"by {work.AuthorName}", maxLines: UI.UI.LineLimit(1)));

        if (work.Fandoms.Count > 0)
        {
            var label = FandomLabel(work.Fandoms);
            var fandom = UI.UI.Grid("Auto,*", columnSpacing: 4);
            fandom.Children.Add(UI.UI.Icon(FandomCatalog.Symbol(work.Fandoms[0]), 10, Theme.TextSecondary)
                .Also(i => { i.VerticalAlignment = VerticalAlignment.Top; i.Margin = new Thickness(0, 2, 0, 0); }).Col(0));
            fandom.Children.Add(UI.UI.Text(label, Theme.Style.Caption, Theme.TextSecondary, maxLines: UI.UI.LineLimit(1)).Col(1));
            stack.Children.Add(fandom);
            spoken.Add(label);
        }

        var pills = UI.UI.Flow(6, 5);
        foreach (var (text, isFolder) in MetadataItems(work))
        {
            pills.Children.Add(Pill(text, isFolder));
            spoken.Add(isFolder ? $"in folder {text}" : text);
        }
        stack.Children.Add(pills);

        if (KeyValueStores.Default.GetBool(ShowReadingProgressKey, true) && ReadingProgress(work) is { } progress)
        {
            stack.Children.Add(progress.Element);
            spoken.Add(progress.Label);
        }

        stack.Padding = new Thickness(0, 6, 0, 6);
        return (stack, string.Join(", ", spoken));
    }

    /// <summary>"Harry Potter - J. K. Rowling" → "Harry Potter", plus "+n" when
    /// the work spans more than one fandom.</summary>
    public static string FandomLabel(IReadOnlyList<string> fandoms)
    {
        if (fandoms.Count == 0) return "";
        var first = fandoms[0];
        var idx = first.IndexOf(" - ", StringComparison.Ordinal);
        var shortName = idx >= 0 ? first[..idx] : first;
        var extra = fandoms.Count - 1;
        return extra > 0 ? $"{shortName}  +{extra}" : shortName;
    }

    public static IReadOnlyList<(string Text, bool IsFolder)> MetadataItems(Work work)
    {
        var items = new List<(string, bool)> { (work.Rating, false) };
        if (work.WordCount > 0) items.Add(($"{work.WordCount.ToString("N0", CultureInfo.CurrentCulture)} words", false));
        if (work.TotalChapters is { } total)
            items.Add((work.ChapterCount == total ? $"{total} ch complete" : $"{work.ChapterCount}/{total} WIP", false));
        else if (work.ChapterCount > 0)
            // A WIP whose author hasn't declared a final count (AO3 shows "12/?").
            items.Add(($"{work.ChapterCount}/? WIP", false));
        foreach (var folder in work.Folders.OrderBy(f => f.Name, StringComparer.Ordinal))
            items.Add((folder.Name, true));
        return items;
    }

    private static Border Pill(string text, bool isFolder)
    {
        var row = UI.UI.HStack(4);
        var fg = isFolder ? Theme.Accent : Theme.TextSecondary;
        if (isFolder) row.Children.Add(UI.UI.Icon("folder", 10, fg).Also(i => i.VerticalAlignment = VerticalAlignment.Center));
        row.Children.Add(UI.UI.Text(text, Theme.Style.Caption2, fg, wrap: false));
        // A rounded rectangle, not a capsule, so the pills line up with the
        // flush title/author text.
        return new Border
        {
            Child = row,
            Background = isFolder ? Theme.AccentSubtle : Theme.SubtleFill,
            CornerRadius = new CornerRadius(5),
            Padding = new Thickness(7, 3, 7, 3),
        }.A11yHidden();
    }

    /// <summary>The progress strip, shown for any work the user has started.</summary>
    private static (FrameworkElement Element, string Label)? ReadingProgress(Work work)
    {
        if (work.LastReadProgress is not { } raw || raw <= 0) return null;
        var progress = Math.Clamp(raw, 0, 1);
        var finished = IsFinished(progress, work.IsComplete);

        var bar = new ProgressBar
        {
            Minimum = 0,
            Maximum = 1,
            Value = progress,
            Foreground = finished ? Theme.Success : Theme.Accent,
            MinHeight = 3,
        }.A11yHidden();

        // At large text sizes the last-read date goes under the percentage
        // rather than running into it.
        var large = UI.UI.IsLargeText;
        var line = large ? UI.UI.Grid("*", "Auto,Auto", rowSpacing: 2) : UI.UI.Grid("*,Auto", columnSpacing: 6);
        var left = UI.UI.HStack(6);
        if (finished)
        {
            left.Children.Add(UI.UI.HStack(4,
                UI.UI.Icon("checkmark.circle.fill", 10, Theme.Success).Also(i => i.VerticalAlignment = VerticalAlignment.Center),
                UI.UI.Text("Finished", Theme.Style.Caption2, Theme.Success, wrap: false)));
        }
        else
        {
            left.Children.Add(UI.UI.Text($"{(int)(progress * 100)}% read", Theme.Style.Caption2, Theme.TextSecondary, wrap: false));
            if (work.LastReadChapter is { } chapter && (work.TotalChapters ?? 0) > 1)
                left.Children.Add(UI.UI.Text($"· Ch {chapter}", Theme.Style.Caption2, Theme.TextSecondary, wrap: false));
        }
        line.Children.Add(left.Col(0));
        if (work.LastReadAt is { } lastRead)
            line.Children.Add(UI.UI.Text(RelativeDate.Named(lastRead), Theme.Style.Caption2, Theme.TextSecondary, wrap: false)
                .Col(large ? 0 : 1).Row(large ? 1 : 0));

        var element = UI.UI.VStack(3, bar, line).Also(s => s.Margin = new Thickness(0, 2, 0, 0)).A11yHidden();
        return (element, ProgressLabel(work, progress, finished));
    }

    /// <summary>Mirrors the visible strip: percent (or Finished), chapter reached, last-read date.</summary>
    private static string ProgressLabel(Work work, double progress, bool finished)
    {
        var parts = new List<string> { finished ? "Finished reading" : $"{(int)(progress * 100)} percent read" };
        if (!finished && work.LastReadChapter is { } chapter && (work.TotalChapters ?? 0) > 1)
            parts.Add($"chapter {chapter}");
        if (work.LastReadAt is { } lastRead) parts.Add($"last read {RelativeDate.Named(lastRead)}");
        return string.Join(", ", parts);
    }
}

/// <summary>
/// The compact reading-stats summary atop the Library list (stories finished,
/// time, streak); it switches to the Stats tab.
/// </summary>
public static class LibraryStatsStrip
{
    public static Button Build(ReadingStatsSummary summary, int streak)
    {
        var grid = UI.UI.Grid("*,Auto,*,Auto,*,Auto", columnSpacing: 0);
        grid.Children.Add(Metric(summary.StoriesRead.ToString(CultureInfo.CurrentCulture), "Finished", "checkmark.circle").Col(0));
        grid.Children.Add(Divider().Col(1));
        grid.Children.Add(Metric(StatsFormat.FormatDuration(summary.TotalSeconds), "Time", "clock").Col(2));
        grid.Children.Add(Divider().Col(3));
        grid.Children.Add(Metric(streak.ToString(CultureInfo.CurrentCulture), "Streak", "flame").Col(4));
        grid.Children.Add(UI.UI.Icon("chevron.right", 11, Theme.TextTertiary)
            .Also(i => { i.VerticalAlignment = VerticalAlignment.Center; i.Margin = new Thickness(8, 0, 0, 0); }).Col(5));

        var button = new Button
        {
            Content = grid,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(16, 12, 16, 12),
            Background = Theme.CardBackground,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
        };
        AutomationProperties.SetName(button,
            $"Reading stats: {summary.StoriesRead} finished, {StatsFormat.FormatDuration(summary.TotalSeconds)} read, {streak} day streak");
        AutomationProperties.SetHelpText(button, "Opens the Stats tab");
        AutomationProperties.SetAutomationId(button, "library.statsStrip");
        ToolTipService.SetToolTip(button, "Open Stats");
        button.Click += (_, _) => MainWindow.Current?.Select(SidebarItem.Stats);
        return button;
    }

    private static FrameworkElement Metric(string value, string label, string symbol)
    {
        var top = UI.UI.HStack(4,
            UI.UI.Icon(symbol, 11, Theme.Accent).Also(i => i.VerticalAlignment = VerticalAlignment.Center),
            UI.UI.Text(value, Theme.Style.Headline, wrap: false));
        top.HorizontalAlignment = HorizontalAlignment.Center;
        var caption = UI.UI.Text(label, Theme.Style.Caption2, Theme.TextSecondary, wrap: false);
        caption.HorizontalAlignment = HorizontalAlignment.Center;
        // Shrinks to fit its third of the strip rather than being clipped
        // (SwiftUI's minimumScaleFactor), as at large text sizes "12h 30m" can
        // be wider than a narrow window's third.
        return new Viewbox
        {
            Child = UI.UI.VStack(2, top, caption),
            Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform,
            StretchDirection = StretchDirection.DownOnly,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
    }

    private static Border Divider() => new()
    {
        Width = 1,
        // As tall as the metrics beside it, however their Viewbox scaled them.
        Background = Theme.Divider,
        VerticalAlignment = VerticalAlignment.Stretch,
        Margin = new Thickness(0, 4, 0, 4),
    };
}
