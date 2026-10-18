using System.Runtime.CompilerServices;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Import;

/// <summary>
/// The import overlay (RootView's ImportOverlay): fanficly://import?url=… links,
/// Share → Fanficly from a browser, and pasted / dropped AO3 links land here. A
/// modal progress dialog fetches the work (metadata and every chapter), saves
/// it to the Library as followed, downloads its EPUB for offline reading, then
/// opens the saved reader. Cancel (or Esc) stops it; a failure is shown with a
/// Close button.
/// </summary>
public static class ImportOverlay
{
    private static CancellationTokenSource? _currentCts;
    private static ContentDialog? _currentDialog;

    [ModuleInitializer]
    internal static void Register()
    {
        Routes.Import = Show;
    }

    /// <summary>Starts importing <paramref name="workId"/>; a newer import replaces one in progress.</summary>
    public static void Show(int workId) => _ = RunAsync(workId);

    private static async Task RunAsync(int workId)
    {
        _currentCts?.Cancel();
        _currentDialog?.Hide();
        var cts = _currentCts = new CancellationTokenSource();

        var status = UI.UI.Secondary("Connecting to AO3...", Theme.Style.Subheadline);
        status.TextAlignment = TextAlignment.Center;
        status.HorizontalAlignment = HorizontalAlignment.Center;
        AutomationProperties.SetLiveSetting(status, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        var ring = new ProgressRing { IsActive = true, Width = 36, Height = 36, HorizontalAlignment = HorizontalAlignment.Center }.A11yHidden();
        var body = UI.UI.VStack(20, ring, status);
        body.Width = 280;
        body.Padding = new Thickness(0, 8, 0, 4);
        AutomationProperties.SetAutomationId(body, "import.overlay");
        AutomationProperties.SetName(body, "Importing Work");

        var dialog = new ContentDialog
        {
            Title = "Importing Work",
            Content = body,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.None,
        };
        AutomationProperties.SetAutomationId(dialog, "import.dialog");
        _currentDialog = dialog;

        var finished = false;
        var opened = false;
        Work? saved = null;
        string? epubError = null;

        void SetStatus(string text) => status.Text = text;

        void ShowError(string message)
        {
            body.Children.Clear();
            body.Children.Add(UI.UI.Icon("exclamationmark.triangle", 40, Theme.Danger).Also(i => i.HorizontalAlignment = HorizontalAlignment.Center));
            body.Children.Add(UI.UI.Text(message, Theme.Style.Subheadline, selectable: true).Also(t =>
            {
                t.TextAlignment = TextAlignment.Center;
                t.HorizontalAlignment = HorizontalAlignment.Center;
            }));
            dialog.CloseButtonText = "Close";
            dialog.DefaultButton = ContentDialogButton.Close;
            MainWindow.Current.Announce($"Import failed. {message}");
        }

        async Task ImportAsync()
        {
            var ct = cts.Token;
            try
            {
                SetStatus("Fetching metadata...");
                var payload = await AppHost.Client.FetchWorkAsync(workId, ct);
                ct.ThrowIfCancellationRequested();

                SetStatus("Saving to library...");
                var library = AppHost.Library;
                var work = WorkPersistence.Upsert(payload, library); // metadata + every chapter, for offline reading
                var now = DateTimeOffset.Now;
                if (!work.IsFollowed) work.LastSeenChapterCount = payload.Summary.ChapterCount;
                work.IsFollowed = true;
                work.FollowedAt = now;
                work.SavedAt = now;
                WorkPersistence.IndexWork(work);
                library.TrySave();
                LibrarySyncManager.QueueBackupShared(library);
                saved = work;

                SetStatus("Downloading for offline reading...");
                try
                {
                    await AppHost.Client.DownloadEpubAsync(workId, ct);
                }
                catch (Exception e) when (!ct.IsCancellationRequested)
                {
                    // The chapters are saved, so the story still reads offline.
                    epubError = e.Message;
                }
                ct.ThrowIfCancellationRequested();

                SetStatus("Done!");
                // Announce completion only; the mid-import steps are too chatty.
                MainWindow.Current.Announce("Done!");
                await Task.Delay(TimeSpan.FromSeconds(1), ct);
                finished = true;
                dialog.Hide();
            }
            catch (Exception) when (ct.IsCancellationRequested)
            {
                // Cancelled: the dialog is closing (or a newer import replaced it).
            }
            catch (Exception e)
            {
                ShowError(e.Message);
            }
        }

        dialog.Opened += (_, _) =>
        {
            if (opened) return;
            opened = true;
            // Replaced by a newer import while this one waited its turn.
            if (cts.IsCancellationRequested) { dialog.Hide(); return; }
            MainWindow.Current.Announce(status.Text);
            _ = ImportAsync();
        };
        dialog.Closing += (_, _) =>
        {
            if (!finished) cts.Cancel();
        };

        await Dialogs.ShowAsync(dialog);
        if (_currentDialog == dialog) _currentDialog = null;

        if (!finished || saved is null)
        {
            if (cts.IsCancellationRequested && _currentCts == cts && opened && saved is null)
                MainWindow.Current.Announce("Import cancelled");
            return;
        }

        // Open the saved reader on top of the Library.
        var window = MainWindow.Current;
        window.Select(SidebarItem.Library);
        Routes.OpenSavedWork(workId);
        if (epubError is not null)
            window.ShowMessage("Saved to Library, but the EPUB download failed", epubError, InfoBarSeverity.Warning, seconds: 6);
    }
}
