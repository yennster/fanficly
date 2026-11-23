using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;

namespace Fanficly.App.Views.Reader;

/// <summary>AO3 has chapters the downloaded copy doesn't (#180; Swift's
/// <c>NewChaptersNotice</c>). The Library reader hands one to the reader, which
/// shows it after the last saved chapter.</summary>
internal sealed class NewChaptersNotice(int count, Action update)
{
    private bool _isUpdating;

    /// <summary>How many chapters AO3 has beyond the saved ones.</summary>
    public int Count { get; } = count;

    /// <summary>Fetches the work once and saves it over the old copy.</summary>
    public Action Update { get; } = update;

    /// <summary>An update is running: the button gives way to a spinner.</summary>
    public bool IsUpdating
    {
        get => _isUpdating;
        set
        {
            if (_isUpdating == value) return;
            _isUpdating = value;
            Changed?.Invoke();
        }
    }

    public event Action? Changed;

    public string Text => DownloadUpdate.BannerText(Count);
}

/// <summary>The quiet note at the end of the last saved chapter: "3 new chapters
/// on AO3 · Update" (Swift's <c>NewChaptersBanner</c>). Continuous scroll and
/// "Swipe by chapter" show it under the last chapter; page-by-page puts it in the
/// last page's footer, in the chapter label's place, so the page area never changes.</summary>
internal sealed partial class ReaderView
{
    /// <summary>Set by the Library reader before the reader is shown; null for a
    /// live work or an up-to-date download.</summary>
    public NewChaptersNotice? NewChapters { get; set; }

    private TextBlock? _footerUpdate;

    private FrameworkElement NewChaptersBanner(NewChaptersNotice notice)
    {
        var icon = Symbols.Icon("sparkles", 14).A11yHidden();
        icon.Foreground = _brushes.Fg60;
        icon.VerticalAlignment = VerticalAlignment.Center;
        var text = new TextBlock
        {
            Text = notice.Text,
            FontSize = 14,
            Foreground = _brushes.Fg85,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var button = UI.UI.Button("Update", () => notice.Update());
        button.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(button, "Update download");
        AutomationProperties.SetHelpText(button, "Saves the new chapters on this device. You stay where you are.");
        AutomationProperties.SetAutomationId(button, "reader.newChapters.update");
        var ring = new ProgressRing { IsActive = true, Width = 16, Height = 16, Foreground = _brushes.Fg50, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(ring, "Updating download");

        void Sync()
        {
            button.Visibility = notice.IsUpdating ? Visibility.Collapsed : Visibility.Visible;
            ring.Visibility = notice.IsUpdating ? Visibility.Visible : Visibility.Collapsed;
        }
        Sync();

        var grid = UI.UI.Grid("Auto,*,Auto,Auto", "Auto", columnSpacing: 10);
        grid.Children.Add(icon.Col(0));
        grid.Children.Add(text.Col(1));
        grid.Children.Add(button.Col(2));
        grid.Children.Add(ring.Col(3));
        var banner = new Border
        {
            Background = _brushes.Fg06,
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12),
            Margin = new Thickness(0, 8, 0, 8),
            Child = grid,
        };
        AutomationProperties.SetAutomationId(banner, "reader.newChapters");
        banner.Loaded += (_, _) => notice.Changed += Sync;
        banner.Unloaded += (_, _) => notice.Changed -= Sync;
        return banner;
    }

    /// <summary>The page footer's update link: the work's last page while AO3 is
    /// ahead. A text block like the chapter label it replaces, so the footer keeps
    /// its height.</summary>
    private TextBlock FooterUpdate()
    {
        if (_footerUpdate is not null) return _footerUpdate;
        var link = new Hyperlink { UnderlineStyle = UnderlineStyle.None };
        link.Inlines.Add(new Run { Text = "Update" });
        link.Click += (_, _) => NewChapters?.Update();
        AutomationProperties.SetName(link, "Update download");
        AutomationProperties.SetAutomationId(link, "reader.newChapters.update");
        _footerUpdate = new TextBlock
        {
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            Foreground = _brushes.Fg85,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        // The link first, so a narrow footer trims the count, never the action.
        _footerUpdate.Inlines.Add(link);
        _footerUpdate.Inlines.Add(new Run());
        return _footerUpdate;
    }

    /// <summary>Shows the footer's update link in the chapter label's place on the
    /// work's last page, or the label everywhere else. True when the link shows.</summary>
    private bool UpdateFooterNotice(ChapterPage current, ChapterPage lastOnScreen)
    {
        if (_footerLabel is null) return false;
        var footerUpdate = FooterUpdate();
        var show = NewChapters is { IsUpdating: false } notice
            && current.ChapterIndex == _chapterOrder[^1]
            && _pages.LastOrDefault(p => p.ChapterIndex == current.ChapterIndex)?.Id == lastOnScreen.Id;
        if (show) ((Run)footerUpdate.Inlines[1]).Text = $" · {NewChapters!.Text}";
        footerUpdate.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        _footerLabel.Visibility = show ? Visibility.Collapsed : Visibility.Visible;
        return show;
    }
}
