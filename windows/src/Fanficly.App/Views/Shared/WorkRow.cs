using System.Globalization;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Shared;

/// <summary>
/// One search / browse / author result (SearchView's WorkRow): title, author,
/// rating · words · reading time · chapters · kudos, a three-line summary, and an inline
/// bookmark button that saves the work to the Library without opening it.
/// Clicking the row opens the work.
/// </summary>
public static class WorkRow
{
    public static FrameworkElement Build(AO3WorkSummary work, Action? onOpen = null)
    {
        // Wraps onto a second line in a narrow window instead of clipping.
        var stats = new FlowPanel { Spacing = 8, LineSpacing = 2 };
        void Stat(string text) => stats.Children.Add(UI.UI.Caption(text));
        if (work.Rating.Length > 0) Stat(work.Rating);
        if (work.WordCount > 0) Stat($"{work.WordCount.ToString("N0", CultureInfo.CurrentCulture)} words");
        var wordsPerMinute = ReadingSpeed.WordsPerMinute(AppHost.Library);
        if (ReadingSpeed.Estimate(work.WordCount, wordsPerMinute) is { } estimate)
        {
            var caption = UI.UI.Caption(estimate);
            AutomationProperties.SetName(caption, ReadingSpeed.SpokenEstimate(work.WordCount, wordsPerMinute) ?? estimate);
            stats.Children.Add(caption);
        }
        if (work.TotalChapters is { } total) Stat($"{work.ChapterCount}/{total}");
        else if (work.ChapterCount > 0) Stat($"{work.ChapterCount}/?");
        if (work.Kudos > 0)
        {
            var kudos = UI.UI.HStack(4, UI.UI.Icon("heart", 11, Theme.TextSecondary).Also(i => i.VerticalAlignment = VerticalAlignment.Center),
                UI.UI.Caption(work.Kudos.ToString("N0", CultureInfo.CurrentCulture)));
            stats.Children.Add(kudos);
        }

        var text = UI.UI.VStack(4,
            UI.UI.Text(work.Title, Theme.Style.Headline),
            UI.UI.Secondary($"by {work.Author}"),
            stats,
            work.Summary.Length == 0 ? null : RichText.Html(work.Summary, Theme.Style.Callout, maxLines: 3));

        var bookmark = new Button
        {
            Background = Theme.Transparent,
            BorderBrush = Theme.Transparent,
            Padding = new Thickness(8, 6, 8, 6),
            VerticalAlignment = VerticalAlignment.Top,
            MinWidth = 0,
        };
        void Refresh()
        {
            var followed = WorkPersistence.IsFollowed(work.Id, AppHost.Library);
            bookmark.Content = UI.UI.Icon(followed ? "bookmark.fill" : "bookmark", 16, followed ? Theme.Accent : Theme.TextSecondary);
            var label = followed ? $"Remove {work.Title} from Library" : $"Save {work.Title} to Library";
            AutomationProperties.SetName(bookmark, label);
            ToolTipService.SetToolTip(bookmark, followed ? "Remove from Library" : "Save to Library");
        }
        Refresh();
        bookmark.Click += (_, _) =>
        {
            var saved = WorkPersistence.ToggleFollow(work, AppHost.Library);
            Refresh();
            Shell.MainWindow.Current?.Announce(saved ? "Saved to Library" : "Removed from Library");
        };

        var grid = UI.UI.Grid("*,Auto", columnSpacing: 8);
        grid.Children.Add(text.Col(0));
        grid.Children.Add(bookmark.Col(1));

        var row = new Button
        {
            Content = grid,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = Theme.Transparent,
            BorderBrush = Theme.Transparent,
            Padding = new Thickness(14, 10, 8, 10),
            CornerRadius = new CornerRadius(6),
        };
        AutomationProperties.SetName(row, $"{work.Title}, by {work.Author}");
        AutomationProperties.SetAutomationId(row, $"work.{work.Id}");
        row.Click += (_, _) => { if (onOpen is not null) onOpen(); else Views.Routes.OpenWork(work.Id, work); };
        row.Loaded += (_, _) => Refresh(); // follow state may change elsewhere
        return row;
    }
}
