using System.ComponentModel;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Library;

/// <summary>
/// The post-restore re-download UI (Swift's <c>.restoreRedownloadUI()</c>):
/// a "Re-download offline stories?" prompt whenever a restore proposes it
/// (installed once, app-wide, so it shows wherever the user is) and a progress
/// card — spinner, "x of y" bar, Cancel — that any screen can host with
/// <see cref="Attach"/>. Progress is announced to Narrator.
/// </summary>
public static class RestoreBanner
{
    private static bool _installed;
    private static bool _prompting;

    private static RestoreDownloadCenter Center => RestoreDownloadCenter.Shared;

    /// <summary>Installs the app-wide prompt and Narrator announcements (once).</summary>
    public static void Install()
    {
        if (_installed) return;
        _installed = true;
        Center.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(RestoreDownloadCenter.ProposedIds)) Post(() => _ = PromptAsync());
        };
        Center.Announcement += text => Post(() => MainWindow.Current?.Announce(text));
    }

    /// <summary>Adds a progress card to <paramref name="host"/> (hidden until
    /// downloads run) and returns it, so the caller can place it (Grid.Row…).</summary>
    public static FrameworkElement Attach(Panel host)
    {
        var banner = Create();
        host.Children.Add(banner);
        return banner;
    }

    private static void Post(Action action)
    {
        var window = MainWindow.Current;
        if (window is null) return;
        if (window.DispatcherQueue.HasThreadAccess) action();
        else window.DispatcherQueue.TryEnqueue(() => action());
    }

    private static async Task PromptAsync()
    {
        if (_prompting || Center.ProposedIds is not { Count: > 0 } ids) return;
        var window = MainWindow.Current;
        if (window is null) return;
        if (window.RootElement.XamlRoot is null)
        {
            // Launch: wait for the window's content before showing a dialog.
            void OnLoaded(object s, RoutedEventArgs e)
            {
                window.RootElement.Loaded -= OnLoaded;
                _ = PromptAsync();
            }
            window.RootElement.Loaded += OnLoaded;
            return;
        }
        _prompting = true;
        try
        {
            var n = ids.Count;
            var message = $"{n} {(n == 1 ? "story" : "stories")} in your restored library {(n == 1 ? "was" : "were")} saved for offline reading. " +
                          $"Download {(n == 1 ? "it" : "them")} again on this device? Everything else is already restored.";
            var dialog = new ContentDialog
            {
                Title = "Re-download offline stories?",
                Content = UI.UI.Text(message),
                PrimaryButtonText = "Download",
                CloseButtonText = "Not Now",
                DefaultButton = ContentDialogButton.Primary,
            };
            AutomationProperties.SetAutomationId(dialog, "restore.prompt");
            var result = await Dialogs.ShowAsync(dialog);
            if (result == ContentDialogResult.Primary) _ = Center.StartDownloads(AppHost.Client);
            else Center.DismissProposal();
        }
        finally
        {
            _prompting = false;
        }
    }

    /// <summary>The floating progress card: spinner while running (a check or
    /// warning when done), "Downloading stories… x of y" over a bar, Cancel.</summary>
    public static FrameworkElement Create()
    {
        var container = new Border
        {
            Padding = new Thickness(14),
            CornerRadius = new CornerRadius(8),
            Background = Theme.CardBackground,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
            MaxWidth = 420,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(16, 8, 16, 4),
            Visibility = Visibility.Collapsed,
            Shadow = new Microsoft.UI.Xaml.Media.ThemeShadow(),
        };
        AutomationProperties.SetAutomationId(container, "restore.banner");
        AutomationProperties.SetLandmarkType(container, AutomationLandmarkType.Custom);
        AutomationProperties.SetLocalizedLandmarkType(container, "Downloads");

        var spinner = new ProgressRing { IsActive = true, Width = 20, Height = 20 }.A11yHidden();
        var doneIcon = (FontIcon)UI.UI.Icon("checkmark.circle.fill", 20);
        var title = UI.UI.Text("", Theme.Style.Footnote, maxLines: UI.UI.LineLimit(1));
        title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        var bar = new ProgressBar { Minimum = 0, Maximum = 1, MinHeight = 4 };
        var group = new AccessibleGroup("", UI.UI.VStack(4, title, bar));
        var cancel = UI.UI.Button("Cancel", () => Center.Cancel());
        cancel.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        AutomationProperties.SetAutomationId(cancel, "restore.cancel");

        var grid = UI.UI.Grid("Auto,*,Auto", columnSpacing: 12);
        var status = new Grid { VerticalAlignment = VerticalAlignment.Center };
        status.Children.Add(spinner);
        status.Children.Add(doneIcon);
        grid.Children.Add(status.Col(0));
        grid.Children.Add(group.Col(1));
        grid.Children.Add(cancel.Also(c => c.VerticalAlignment = VerticalAlignment.Center).Col(2));
        container.Child = grid;

        void Update()
        {
            if (Center.Progress is not { } p)
            {
                container.Visibility = Visibility.Collapsed;
                return;
            }
            container.Visibility = Visibility.Visible;
            spinner.Visibility = p.Finished ? Visibility.Collapsed : Visibility.Visible;
            spinner.IsActive = !p.Finished;
            doneIcon.Visibility = p.Finished ? Visibility.Visible : Visibility.Collapsed;
            doneIcon.Glyph = Symbols.Glyph(p.Failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill");
            doneIcon.Foreground = p.Failed == 0 ? Theme.Success : Theme.Warning;
            title.Text = p.Finished
                ? (p.Failed == 0 ? $"Downloaded {p.Done} stories" : $"Downloaded {p.Done} of {p.Total} stories")
                : $"Downloading stories… {p.Done} of {p.Total}";
            bar.Maximum = Math.Max(p.Total, 1);
            bar.Value = p.Done + p.Failed;
            group.AccessibleName = p.Finished
                ? $"Downloaded {p.Done} of {p.Total} stories"
                : $"Downloading stories, {p.Done} of {p.Total} done";
            cancel.Visibility = p.Finished ? Visibility.Collapsed : Visibility.Visible;
            AutomationProperties.SetHelpText(cancel, Center.Kind == RestoreDownloadCenter.DownloadKind.Restore
                ? "Stops the downloads. Everything else stays restored."
                : "Stops the downloads. Stories already downloaded stay.");
        }

        void OnChanged(object? sender, PropertyChangedEventArgs e)
        {
            if (e.PropertyName == nameof(RestoreDownloadCenter.Progress)) Post(Update);
        }
        container.Loaded += (_, _) =>
        {
            Center.PropertyChanged -= OnChanged;
            Center.PropertyChanged += OnChanged;
            Update();
        };
        container.Unloaded += (_, _) => Center.PropertyChanged -= OnChanged;
        Update();
        return container;
    }
}
