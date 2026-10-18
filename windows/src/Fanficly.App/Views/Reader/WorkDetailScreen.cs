using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// A work live from AO3 (WorkDetailView): the reader, plus two toolbar items —
/// save to Library, and the work options menu (comments, share &amp; export,
/// download for offline reading, subscribe on AO3, report, hide).
/// </summary>
internal sealed class WorkDetailScreen : ReaderHostScreen
{
    private const string ReportUrl = "https://archiveofourown.org/abuse_reports/new";

    private readonly int _workId;
    private AO3WorkPayload? _payload;
    /// <summary><see cref="_payload"/> holds every chapter (not just the one the
    /// reader opened on), so it's safe to save.</summary>
    private bool _isWholeWork;
    private string? _epubPath;
    private bool _followed;
    private bool _isSavingOffline;
    private bool _isSubscribing;
    private int _currentChapter = 1;
    private readonly WorkExporter _exporter = new();
    private Button? _saveButton;
    private Button? _optionsButton;

    public WorkDetailScreen(int workId, AO3WorkSummary? summary)
    {
        _workId = workId;
        Title = summary?.Title is { Length: > 0 } title ? title : "Work";
        _exporter.Changed += UpdateOptionsButton;
    }

    protected override void Start() => _ = LoadAsync();

    private async Task LoadAsync()
    {
        _epubPath = WorkPersistence.EpubPath(_workId);
        _followed = WorkPersistence.IsFollowed(_workId, AppHost.Library);
        ShowLoading("Loading…");
        try
        {
            // One chapter first (the saved one, else the first): AO3's
            // whole-work page is its slowest, so the rest loads behind it.
            var chapter = ReadingProgressStore.Load(_workId, AppHost.Library)?.Chapter ?? 1;
            var page = await AppHost.Client.FetchWorkChapterAsync(_workId, chapter);
            if (IsRemoved) return;
            _payload = page.Payload;
            _isWholeWork = page.IsWholeWork;
            Title = page.Payload.Summary.Title;
            try { WorkPersistence.RecordView(page.Payload.Summary, AppHost.Library); }
            catch (Exception e) { AppHost.Log($"Recording the view failed: {e.Message}"); }

            ShowReader(MakeReader(ReaderView.FromChapterPage(page)));
            if (!page.IsWholeWork) _ = LoadRestAsync();
        }
        catch (Exception e)
        {
            if (IsRemoved) return;
            AppHost.Log($"Loading work {_workId} failed: {e.Message}");
            ShowError("exclamationmark.triangle", "Couldn't load work", e.Message, () => _ = LoadAsync());
        }
    }

    private async Task LoadRestAsync()
    {
        if (await FetchRestAsync(_workId) is not { } full || IsRemoved) return;
        _payload = full;
        _isWholeWork = true;
        SwapReader(MakeReader(ReaderView.FromPayload(full)));
    }

    /// <summary>The whole work, fetching it if the reader opened on one chapter.</summary>
    private async Task<AO3WorkPayload> WholeWorkAsync()
    {
        if (_isWholeWork && _payload is { } payload) return payload;
        var full = await AppHost.Client.FetchWorkAsync(_workId);
        if (!_isWholeWork) { _payload = full; _isWholeWork = true; }
        return full;
    }

    private ReaderView MakeReader(ReaderView reader)
    {
        _currentChapter = reader.EffectiveChapter;
        reader.ChapterChanged += chapter => _currentChapter = chapter;
        _saveButton = reader.ToolbarButton("bookmark", "Save to Library", ToggleFollow);
        AutomationProperties.SetAutomationId(_saveButton, "work.save");
        _optionsButton = reader.ToolbarButton("ellipsis.circle", "Work options");
        AutomationProperties.SetAutomationId(_optionsButton, "work.options");
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        menu.Opening += (_, _) => FillOptions(menu);
        _optionsButton.Flyout = menu;
        reader.SetTrailingItems(_saveButton, _optionsButton);
        UpdateSaveButton();
        UpdateOptionsButton();
        return reader;
    }

    // MARK: - Save to Library (local follow)

    private void ToggleFollow()
    {
        if (_payload is null) return;
        try
        {
            _followed = WorkPersistence.ToggleFollow(_payload.Summary, AppHost.Library);
            MainWindow.Current.Announce(_followed ? "Saved to Library" : "Removed from Library");
        }
        catch (Exception e)
        {
            AppHost.Log($"Saving to Library failed: {e.Message}");
        }
        UpdateSaveButton();
    }

    private void UpdateSaveButton()
    {
        if (_saveButton is null) return;
        var label = _followed ? "Remove from Library" : "Save to Library";
        _saveButton.Content = Symbols.Icon(_followed ? "bookmark.fill" : "bookmark", 16).A11yHidden();
        AutomationProperties.SetName(_saveButton, label);
        ToolTipService.SetToolTip(_saveButton, label);
    }

    // MARK: - Options menu

    private void UpdateOptionsButton()
    {
        if (_optionsButton is null) return;
        var busy = _exporter.IsExporting || _isSavingOffline || _isSubscribing;
        _optionsButton.Content = busy
            ? new ProgressRing { IsActive = true, Width = 16, Height = 16 }
            : Symbols.Icon("ellipsis.circle", 16).A11yHidden();
    }

    /// <summary>Overflow menu: comments, export, offline download, subscribe, plus
    /// the UGC safeguards — report the work to AO3 and hide it locally. Anything
    /// it presents is presented by the screen after the menu closes.</summary>
    private void FillOptions(MenuFlyout menu)
    {
        menu.Items.Clear();
        if (_payload is not { } payload) return;
        var title = payload.Summary.Title;

        var comments = UI.UI.MenuItem("Comments", OpenComments, "bubble.left.and.bubble.right");
        AutomationProperties.SetAutomationId(comments, "work.options.comments");
        menu.Items.Add(comments);
        menu.Items.Add(new MenuFlyoutSeparator());

        menu.Items.Add(_exporter.Menu(_workId, () => title));

        var downloaded = _epubPath is not null;
        var download = UI.UI.MenuItem(
            _isSavingOffline ? "Downloading…" : downloaded ? "Downloaded" : "Download",
            () => Later(SaveOfflineAsync),
            downloaded && !_isSavingOffline ? "checkmark.circle.fill" : "arrow.down.circle");
        download.IsEnabled = !_isSavingOffline && !downloaded;
        AutomationProperties.SetAutomationId(download, "work.options.download");
        menu.Items.Add(download);

        var subscribed = AppHost.Library.GetSubscription($"work:{_workId}") is not null;
        MenuFlyoutItem subscribe;
        if (subscribed)
        {
            subscribe = UI.UI.MenuItem("Subscribed on AO3", () => { }, "bell.fill");
            subscribe.IsEnabled = false;
        }
        else if (!AppHost.Auth.IsLoggedIn)
        {
            subscribe = UI.UI.MenuItem("Subscribe on AO3 (sign in)…", Routes.OpenLogin, "bell");
        }
        else
        {
            subscribe = UI.UI.MenuItem(_isSubscribing ? "Subscribing…" : "Subscribe on AO3", () => Later(SubscribeAsync), "bell");
            subscribe.IsEnabled = !_isSubscribing;
        }
        AutomationProperties.SetAutomationId(subscribe, "work.options.subscribe");
        menu.Items.Add(subscribe);
        menu.Items.Add(new MenuFlyoutSeparator());

        var report = UI.UI.MenuItem("Report this work", () => Later(ReportAsync), "flag");
        AutomationProperties.SetAutomationId(report, "work.options.report");
        menu.Items.Add(report);
        var hide = UI.UI.MenuItem("Hide this work", HideWork, "eye.slash", isDestructive: true);
        AutomationProperties.SetAutomationId(hide, "work.options.hide");
        menu.Items.Add(hide);
    }

    /// <summary>Runs an action once the menu has closed.</summary>
    private static void Later(Func<Task> action) =>
        MainWindow.Current.DispatcherQueue.TryEnqueue(() => _ = action());

    private void OpenComments()
    {
        if (_payload is not { } payload) return;
        var chapterId = payload.Chapters.FirstOrDefault(c => c.Index == _currentChapter)?.AoId;
        Routes.OpenComments(_workId, chapterId, payload.Summary.Title);
    }

    private async Task SaveOfflineAsync()
    {
        if (_payload is null || _isSavingOffline) return;
        _isSavingOffline = true;
        UpdateOptionsButton();
        MainWindow.Current.Announce("Downloading for offline reading");
        try
        {
            // Saving replaces the stored chapters, so never with just one of them.
            var payload = await WholeWorkAsync();
            WorkPersistence.Upsert(payload, AppHost.Library);
            _epubPath = await AppHost.Client.DownloadEpubAsync(payload.Summary.Id);
            _followed = WorkPersistence.IsFollowed(_workId, AppHost.Library);
            UpdateSaveButton();
            MainWindow.Current.ShowMessage("Downloaded", "This work is available offline.");
        }
        catch (Exception e)
        {
            AppHost.Log($"Download failed: {e}");
            await Dialogs.AlertAsync("Download failed", $"Saved metadata but EPUB download failed: {e.Message}");
        }
        finally
        {
            _isSavingOffline = false;
            UpdateOptionsButton();
        }
    }

    /// <summary>Subscribes on AO3 (needs a session) and mirrors it into the local
    /// subscription list, so the poller's baseline starts at today's chapters.</summary>
    private async Task SubscribeAsync()
    {
        if (_payload is not { } payload || _isSubscribing) return;
        _isSubscribing = true;
        UpdateOptionsButton();
        try
        {
            await AppHost.Client.SubscribeToWorkAsync(_workId);
            var key = $"work:{_workId}";
            if (AppHost.Library.GetSubscription(key) is null)
            {
                AppHost.Library.Insert(new SubscriptionRecord(key, "work", payload.Summary.Title, payload.Summary.Author)
                {
                    LastSeenChapterCount = payload.Summary.ChapterCount,
                });
                AppHost.Library.TrySave();
            }
            MainWindow.Current.ShowMessage("Subscribed on AO3", "AO3 will email you when this work updates.");
        }
        catch (AO3Exception e) when (e.Kind == AO3ErrorKind.Unauthorized)
        {
            if (await Dialogs.ConfirmAsync("Sign in to AO3", "Your AO3 session has expired. Sign in again to subscribe.", "Sign In"))
                Routes.OpenLogin();
        }
        catch (Exception e)
        {
            AppHost.Log($"Subscribe failed: {e}");
            await Dialogs.AlertAsync("Couldn't subscribe", e.Message);
        }
        finally
        {
            _isSubscribing = false;
            UpdateOptionsButton();
        }
    }

    private static async Task ReportAsync()
    {
        try { await Windows.System.Launcher.LaunchUriAsync(new Uri(ReportUrl)); }
        catch (Exception e) { AppHost.Log($"Opening the report page failed: {e.Message}"); }
    }

    /// <summary>Hides the work so it never shows in results again, and leaves it.</summary>
    private void HideWork()
    {
        if (_payload is not { } payload) return;
        HiddenWorkStore.Hide(payload.Summary.Id, payload.Summary.Title, AppHost.Library);
        MainWindow.Current.Announce("Work hidden");
        Navigator.Remove(this);
    }
}
