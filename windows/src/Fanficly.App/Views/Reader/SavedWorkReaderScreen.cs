using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// A Library work's reader (SavedWorkReader). Downloaded works (chapters saved
/// on the device) read fully offline; bookmarked-only works have no saved text,
/// so it's fetched from AO3 on demand, and can be saved offline from here.
/// Toolbar: Comments, and a "More" menu with share &amp; export and Save Offline.
/// </summary>
internal sealed class SavedWorkReaderScreen : ReaderHostScreen
{
    private readonly Work _work;
    private AO3WorkPayload? _payload;
    /// <summary><see cref="_payload"/> holds every chapter, so it's safe to save.</summary>
    private bool _isWholeWork;
    private bool _isLoading;
    private bool _isSavingOffline;
    private bool _isDownloaded;
    private bool _isResolvingComments;
    private int _currentChapter = 1;
    private readonly WorkExporter _exporter = new();
    private Button? _commentsButton;
    private Button? _moreButton;

    private SavedWorkReaderScreen(Work work)
    {
        _work = work;
        Title = work.Title.Length > 0 ? work.Title : "Work";
        _exporter.Changed += UpdateMoreButton;
    }

    /// <summary>The saved reader for a Library work, or the live work page when it
    /// isn't in the Library (any more).</summary>
    public static Screen ForWork(int workId) =>
        AppHost.Library.GetWork(workId) is { } work ? new SavedWorkReaderScreen(work) : new WorkDetailScreen(workId, null);

    private IReadOnlyList<Chapter> OfflineChapters => AppHost.Library.ChaptersOf(_work);

    private bool HasOfflineText => OfflineChapters.Count > 0;

    /// <summary>AO3's id for the chapter on screen (per-chapter comments); null
    /// falls back to the work-level thread.</summary>
    private int? CurrentChapterAoId => HasOfflineText
        ? OfflineChapters.FirstOrDefault(c => c.Index == _currentChapter)?.AoId
        : _payload?.Chapters.FirstOrDefault(c => c.Index == _currentChapter)?.AoId;

    protected override void Start()
    {
        _isDownloaded = WorkPersistence.EpubPath(_work.Ao3Id) is not null;
        try { WorkPersistence.RecordView(_work, AppHost.Library); }
        catch (Exception e) { AppHost.Log($"Recording the view failed: {e.Message}"); }

        if (HasOfflineText) ShowReader(MakeReader(ReaderView.FromWork(_work, OfflineChapters)));
        else _ = LoadAsync();
    }

    private ReaderView MakeReader(ReaderView reader)
    {
        _currentChapter = reader.EffectiveChapter;
        reader.ChapterChanged += chapter => _currentChapter = chapter;

        _commentsButton = reader.ToolbarButton("bubble.left.and.bubble.right", "Comments", () => _ = OpenCommentsAsync());
        AutomationProperties.SetAutomationId(_commentsButton, "work.comments");
        _moreButton = reader.ToolbarButton("ellipsis.circle", "More");
        AutomationProperties.SetAutomationId(_moreButton, "work.options");
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        menu.Opening += (_, _) => FillMore(menu);
        _moreButton.Flyout = menu;
        reader.SetTrailingItems(_commentsButton, _moreButton);
        UpdateMoreButton();
        return reader;
    }

    private async Task LoadAsync()
    {
        if (HasOfflineText || _payload is not null || _isLoading) return;
        _isLoading = true;
        ShowLoading("Loading from AO3…");
        try
        {
            // The chapter you were on first; AO3's whole-work page is its
            // slowest, so the rest loads behind it.
            var chapter = ReadingProgressStore.Load(_work.Ao3Id, AppHost.Library)?.Chapter ?? 1;
            var page = await AppHost.Client.FetchWorkChapterAsync(_work.Ao3Id, chapter);
            if (IsRemoved) return;
            _payload = page.Payload;
            _isWholeWork = page.IsWholeWork;
            ShowReader(MakeReader(ReaderView.FromChapterPage(page)));
            if (!page.IsWholeWork) _ = LoadRestAsync();
        }
        catch (Exception e)
        {
            if (IsRemoved) return;
            AppHost.Log($"Loading saved work {_work.Ao3Id} failed: {e.Message}");
            ShowError("wifi.exclamationmark", "Couldn't load",
                "This bookmarked work loads on demand. Connect to the internet to read it, or tap the download button to save it offline.",
                () => _ = LoadAsync());
        }
        finally
        {
            _isLoading = false;
        }
    }

    private async Task LoadRestAsync()
    {
        if (await FetchRestAsync(_work.Ao3Id) is not { } full || IsRemoved || HasOfflineText) return;
        _payload = full;
        _isWholeWork = true;
        SwapReader(MakeReader(ReaderView.FromPayload(full)));
    }

    // MARK: - Comments

    private async Task OpenCommentsAsync()
    {
        if (_isResolvingComments) return;
        _isResolvingComments = true;
        UpdateCommentsButton();
        try { await EnsureChapterIdsAsync(); }
        finally
        {
            _isResolvingComments = false;
            UpdateCommentsButton();
        }
        if (IsRemoved) return;
        Routes.OpenComments(_work.Ao3Id, CurrentChapterAoId, _work.Title);
    }

    /// <summary>Downloads saved before per-chapter comments have no chapter ids, so
    /// the reader can't tell which chapter's thread to load. Resolve them once from
    /// the first chapter's page (its chapter menu lists every id) and persist;
    /// silent on failure.</summary>
    private async Task EnsureChapterIdsAsync()
    {
        if (!HasOfflineText || CurrentChapterAoId is not null) return;
        try
        {
            var page = await AppHost.Client.FetchWorkChapterAsync(_work.Ao3Id);
            var known = page.ChapterIds.Count > 0
                ? page.ChapterIds.Select((id, i) => (Index: i + 1, AoId: (int?)id))
                : page.Payload.Chapters.Select(c => (c.Index, c.AoId));
            var local = OfflineChapters;
            var changed = false;
            foreach (var chapter in known)
            {
                if (chapter.AoId is not { } id) continue;
                if (local.FirstOrDefault(c => c.Index == chapter.Index) is { AoId: null } match)
                {
                    match.AoId = id;
                    changed = true;
                }
            }
            if (changed) AppHost.Library.TrySave();
        }
        catch (Exception e)
        {
            AppHost.Log($"Resolving chapter ids failed: {e.Message}");
        }
    }

    private void UpdateCommentsButton()
    {
        if (_commentsButton is null) return;
        _commentsButton.IsEnabled = !_isResolvingComments;
        _commentsButton.Content = _isResolvingComments
            ? new ProgressRing { IsActive = true, Width = 16, Height = 16 }
            : Symbols.Icon("bubble.left.and.bubble.right", 16).A11yHidden();
    }

    // MARK: - More menu

    private void UpdateMoreButton()
    {
        if (_moreButton is null) return;
        _moreButton.Content = _isSavingOffline || _exporter.IsExporting
            ? new ProgressRing { IsActive = true, Width = 16, Height = 16 }
            : Symbols.Icon("ellipsis.circle", 16).A11yHidden();
    }

    private void FillMore(MenuFlyout menu)
    {
        menu.Items.Clear();
        var title = _work.Title;
        menu.Items.Add(_exporter.Menu(_work.Ao3Id, () => title));
        var save = UI.UI.MenuItem(_isDownloaded ? "Downloaded" : _isSavingOffline ? "Saving Offline…" : "Save Offline",
            () => MainWindow.Current.DispatcherQueue.TryEnqueue(() => _ = SaveOfflineAsync()),
            _isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle");
        save.IsEnabled = !_isSavingOffline && !_isDownloaded;
        AutomationProperties.SetAutomationId(save, "work.options.download");
        menu.Items.Add(save);
    }

    private async Task SaveOfflineAsync()
    {
        if (_isSavingOffline) return;
        _isSavingOffline = true;
        UpdateMoreButton();
        MainWindow.Current.Announce("Saving for offline reading");
        try
        {
            // Make sure we have the whole work to keep its chapters (never
            // just the one the reader opened on: saving replaces them).
            AO3WorkPayload? toSave = _isWholeWork ? _payload : null;
            if (toSave is null)
            {
                try { toSave = await AppHost.Client.FetchWorkAsync(_work.Ao3Id); }
                catch (Exception e) when (AppHost.Library.ChaptersOf(_work).Count > 0)
                {
                    // The chapters saved earlier still read offline.
                    AppHost.Log($"Fetching the work to save failed: {e.Message}");
                }
            }
            if (toSave is not null)
            {
                WorkPersistence.Upsert(toSave, AppHost.Library);
                _payload = toSave;
                _isWholeWork = true;
            }
            await AppHost.Client.DownloadEpubAsync(_work.Ao3Id);
            _isDownloaded = true;
            MainWindow.Current.ShowMessage("Saved offline", "This work is available offline.");
        }
        catch (Exception e)
        {
            AppHost.Log($"Save offline failed: {e}");
            await Dialogs.AlertAsync("Couldn't download for offline", e.Message);
        }
        finally
        {
            _isSavingOffline = false;
            UpdateMoreButton();
        }
    }
}
