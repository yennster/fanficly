using System.Globalization;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Settings;

/// <summary>Settings → About → What's New (#422; the Swift WhatsNewHistoryView):
/// every release's highlights, newest first, from the changelog both apps share,
/// headed by date rather than the Apple app's version numbers.</summary>
public sealed class WhatsNewScreen : Screen
{
    public WhatsNewScreen() => Title = "What's New";

    protected override FrameworkElement Build()
    {
        var page = UI.UI.VStack(18);
        var releases = WhatsNew.Releases;
        if (releases.Count == 0)
            page.Children.Add(UI.UI.EmptyState("sparkles", "No updates listed"));
        foreach (var release in releases)
        {
            // By date: the changelog's versions are the Apple app's, and this
            // app's own version numbers (Settings → About) differ.
            var header = release.Date is { } date ? LongDate(date) : "Coming soon";
            page.Children.Add(UI.UI.Section(header,
                release.Themes.Select(t => (UIElement)ThemeRow(t, large: false).Margin(14, 10, 14, 10))));
        }
        return SettingsKit.Page(page, "settings.whatsNew.page");
    }

    internal static string LongDate(DateOnly date) => date.ToString("D", CultureInfo.CurrentCulture);

    /// <summary>One theme: its icon, title and line, read as one item.</summary>
    internal static FrameworkElement ThemeRow(WhatsNewTheme theme, bool large)
    {
        var row = UI.UI.Grid("Auto,*", columnSpacing: large ? 16 : 12);
        row.Children.Add(UI.UI.Icon(theme.Icon, large ? 24 : 16, Theme.Accent)
            .Also(i => { i.VerticalAlignment = VerticalAlignment.Top; i.Margin = new Thickness(0, 2, 0, 0); })
            .A11yHidden().Col(0));
        row.Children.Add(UI.UI.VStack(2,
            UI.UI.Text(theme.Title, Theme.Style.Headline),
            UI.UI.Secondary(theme.Detail, Theme.Style.Body)).Col(1));
        AutomationProperties.SetName(row, $"{theme.Title}. {theme.Detail}");
        return row;
    }
}

/// <summary>The dialog the first launch after an update shows (#422; the Swift
/// WhatsNewSheet): the newest release's themes, Continue, and See All Updates,
/// which opens Settings → What's New.</summary>
public static class WhatsNewDialog
{
    /// <summary>Called once from OnLaunched. <paramref name="isExistingUser"/>: the
    /// 17+ confirmation was given before this launch (an update, not a fresh
    /// install). <paramref name="openedIntoContent"/>: the launch opened a link,
    /// a story, a file or a share, so the dialog waits for the next plain launch.</summary>
    public static void CheckAtLaunch(bool isExistingUser, bool openedIntoContent)
    {
        if (AppHost.IsDemoWhatsNew && WhatsNew.AllReleases.FirstOrDefault() is { } preview)
        {
            _ = ShowAsync(preview);
            return;
        }
        if (AppHost.IsDemoMode || AppHost.IsIconGallery) return;
        var newest = WhatsNew.Releases.FirstOrDefault();
        var store = KeyValueStores.Default;
        switch (WhatsNew.LaunchDecision(newest, store.GetString(WhatsNew.LastSeenKey), isExistingUser, openedIntoContent))
        {
            case WhatsNew.Action.Record:
                store.SetString(WhatsNew.LastSeenKey, newest!.Version);
                break;
            case WhatsNew.Action.Show:
                _ = ShowAsync(newest!);
                break;
        }
    }

    private static async Task ShowAsync(WhatsNewRelease release)
    {
        // Let the window settle (and a restore prompt ask first) before it shows.
        await Task.Delay(TimeSpan.FromSeconds(1.5));
        var themes = UI.UI.VStack(18, release.Themes.Select(t => (UIElement)WhatsNewScreen.ThemeRow(t, large: true)).ToArray());
        var dialog = new ContentDialog
        {
            Title = "What's New in Fanficly",
            Content = new ScrollViewer { Content = themes, MaxWidth = 520, Padding = new Thickness(0, 4, 12, 4) },
            PrimaryButtonText = "See All Updates",
            CloseButtonText = "Continue",
            DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(dialog, "whatsNew.dialog");
        // Seen once it's on screen: a dialog still queued when the app closes
        // shows next launch.
        dialog.Opened += (_, _) =>
        {
            if (!AppHost.IsDemoMode) KeyValueStores.Default.SetString(WhatsNew.LastSeenKey, release.Version);
        };
        if (await Dialogs.ShowAsync(dialog) != ContentDialogResult.Primary) return;
        var window = MainWindow.Current;
        window.Select(SidebarItem.Settings);
        window.Navigator.Push(new WhatsNewScreen());
    }
}
