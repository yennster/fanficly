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
/// Toolbar: Comments, and a "More" menu with Bookmark on AO3, share &amp; export
/// and Save Offline (Update Download once it's downloaded).
/// A download behind AO3 (a work in progress with new chapters the app knows of)
/// shows "3 new chapters on AO3 · Update" after its last saved chapter (#180):
/// one fetch, saved over the old copy, and the reader keeps its place.
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
    private bool _isUpdating;
    /// <summary>The banner's state while AO3 is known to be ahead; null otherwise.</summary>
    private NewChaptersNotice? _newChapters;
    private bool _isResolvingComments;
    private int _currentChapter = 1;
    private readonly WorkExporter _exporter = new();
    private readonly WorkKudos _kudos;
    private readonly WorkSubscribe _subscribe;
    private Button? _commentsButton;
    private Button? _moreButton;

    private SavedWorkReaderScreen(Work work)
    {
        _work = work;
        Title = work.Title.Length > 0 ? work.Title : "Work";
        _exporter.Changed += UpdateMoreButton;
        _kudos = new WorkKudos(work.Ao3Id);
        _kudos.Changed += UpdateMoreButton;
        _subscribe = new WorkSubscribe(work.Ao3Id);
        _subscribe.Changed += UpdateMoreButton;
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

        if (HasOfflineText) ShowReader(MakeReader(OfflineReader()));
        else _ = LoadAsync();
    }

    /// <summary>The reader of the saved chapters, with the new-chapters banner
    /// when AO3 is known to be ahead.</summary>
    private ReaderView OfflineReader(int? fetchedChapterCount = null)
    {
        var reader = ReaderView.FromWork(_work, OfflineChapters);
        // Just updated: AO3's own count now, so a higher baseline (chapters since
        // deleted on AO3) doesn't keep offering an update that brings nothing.
        var count = EpubImport.IsLocalWork(_work.Ao3Id) ? 0
            : fetchedChapterCount is { } fetched ? DownloadUpdate.NewChapterCount(OfflineChapters.Count, [fetched])
            : DownloadUpdate.NewChapterCount(_work, AppHost.Library);
        _newChapters = count > 0 ? new NewChaptersNotice(count, () => MainWindow.Current.DispatcherQueue.TryEnqueue(() => _ = UpdateDownloadAsync())) : null;
        reader.NewChapters = _newChapters;
        return reader;
    }

    private ReaderView MakeReader(ReaderView reader)
    {
        _currentChapter = reader.EffectiveChapter;
        reader.ChapterChanged += chapter => _currentChapter = chapter;

        _commentsButton = reader.ToolbarButton("bubble.left.and.bubble.right", "Comments", () => _ = OpenCommentsAsync());
        AutomationProperties.SetAutomationId(_commentsButton, "work.comments");
        _moreButton = reader.ToolbarButton("book.circle", "More");
        AutomationProperties.SetAutomationId(_moreButton, "work.options");
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        menu.Opening += (_, _) => FillMore(menu);
        _moreButton.Flyout = menu;
        // An imported book that isn't on AO3 has no comments, kudos or downloads.
        if (EpubImport.IsLocalWork(_work.Ao3Id)) reader.SetTrailingItems();
        else reader.SetTrailingItems(_commentsButton, _moreButton);
        UpdateMoreButton();
        return reader;
    }

    private async Task LoadAsync()
    {
        if (HasOfflineText || EpubImport.IsLocalWork(_work.Ao3Id) || _payload is not null || _isLoading) return;
        _isLoading = true;
        ShowLoading("Loading from AO3…");
        try
        {
            // The chapter you were on first; AO3's whole-work page is its
            // slowest, so the rest loads behind it.
            var chapter = ReaderModule.OpeningAnchor(_work.Ao3Id)?.Chapter ?? 1;
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
                "This bookmarked work loads on demand. Connect to the internet to read it, then choose Save Offline in the More menu to keep it on this device.",
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
        _moreButton.Content = _isSavingOffline || _isUpdating || _exporter.IsExporting || _kudos.IsSending || _subscribe.IsSending
            ? new ProgressRing { IsActive = true, Width = 16, Height = 16 }
            : Symbols.Icon("book.circle", 16).A11yHidden();
    }

    private void FillMore(MenuFlyout menu)
    {
        menu.Items.Clear();
        var title = _work.Title;
        menu.Items.Add(_kudos.MenuItem());
        var bookmark = AppHost.Auth.IsLoggedIn
            ? UI.UI.MenuItem("Bookmark on AO3", () => Routes.OpenBookmark(_work.Ao3Id, title), "bookmark.circle")
            : UI.UI.MenuItem("Bookmark on AO3 (sign in)…", Routes.OpenLogin, "bookmark.circle");
        AutomationProperties.SetAutomationId(bookmark, "work.options.bookmark");
        menu.Items.Add(bookmark);
        menu.Items.Add(_exporter.Menu(_work.Ao3Id, () => title));
        MenuFlyoutItem save;
        if (CanUpdate)
        {
            // Saved text: refresh it from AO3 rather than a disabled "Downloaded" (#180).
            var known = _newChapters?.Count ?? 0;
            save = UI.UI.MenuItem(_isUpdating ? "Updating Download…" : known > 0 ? $"Update Download ({known} new)" : "Update Download",
                () => MainWindow.Current.DispatcherQueue.TryEnqueue(() => _ = UpdateDownloadAsync()),
                "arrow.clockwise");
            save.IsEnabled = !_isUpdating;
        }
        else
        {
            // Downloaded with a live payload: AO3's current copy, nothing to update.
            save = UI.UI.MenuItem(_isDownloaded ? "Downloaded" : _isSavingOffline ? "Saving Offline…" : "Save Offline",
                () => MainWindow.Current.DispatcherQueue.TryEnqueue(() => _ = SaveOfflineAsync()),
                _isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle");
            save.IsEnabled = !_isSavingOffline && !_isDownloaded;
        }
        AutomationProperties.SetAutomationId(save, "work.options.download");
        menu.Items.Add(save);
        // A saved copy can be behind AO3, so only a live payload sets the baseline.
        menu.Items.Add(_subscribe.MenuItem(() => new(title, _work.AuthorName, _payload?.Summary.ChapterCount)));
    }

    private async Task SaveOfflineAsync()
    {
        if (_isSavingOffline || _isUpdating) return;
        _isSavingOffline = true;
        UpdateMoreButton();
        MainWindow.Current.Announce("Saving for offline reading");
        var textSaved = false;
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
                textSaved = true;
            }
            await AppHost.Client.DownloadEpubAsync(_work.Ao3Id);
            _isDownloaded = true;
            MainWindow.Current.ShowMessage("Saved offline", "This work is available offline.");
        }
        catch (Exception e)
        {
            AppHost.Log($"Save offline failed: {e}");
            await Dialogs.AlertAsync("Couldn't download for offline", textSaved
                ? $"The text is saved for offline reading, but the EPUB download failed: {e.Message}"
                : e.Message);
        }
        finally
        {
            _isSavingOffline = false;
            UpdateMoreButton();
        }
    }

    // MARK: - Update download (#180)

    /// <summary>Saved text read from the device: the menu offers an update instead
    /// of Save Offline (which would only fetch the EPUB and leave stale chapters).
    /// A whole live payload is AO3's current copy.</summary>
    private bool CanUpdate => HasOfflineText && _payload is null;

    /// <summary>Brings the saved copy up to date: one throttled fetch of the whole
    /// work, saved over the old chapters, then the EPUB again. The reader is swapped
    /// for one with the new chapters that opens where this one is, once Listen
    /// stops. When the fetch fails, or AO3 now has fewer chapters than are saved,
    /// the old copy stays as it was.</summary>
    private async Task UpdateDownloadAsync()
    {
        if (_isUpdating || _isSavingOffline || !HasOfflineText) return;
        _isUpdating = true;
        if (_newChapters is { } notice) notice.IsUpdating = true;
        UpdateMoreButton();
        MainWindow.Current.Announce("Updating download");
        try
        {
            AO3WorkPayload fetched;
            try { fetched = await AppHost.Client.FetchWorkAsync(_work.Ao3Id); }
            catch (Exception e)
            {
                AppHost.Log($"Updating download {_work.Ao3Id} failed: {e.Message}");
                if (!IsRemoved)
                    await Dialogs.AlertAsync("Couldn't update the download",
                        $"Couldn't get the new chapters from AO3, so the saved copy is unchanged: {e.Message}");
                return;
            }
            // Deleted from the Library while the fetch ran: don't bring it back.
            if (AppHost.Library.GetWork(_work.Ao3Id) is null) return;
            var outcome = DownloadUpdate.Apply(fetched, _work, AppHost.Library);
            if (!outcome.Updated)
            {
                if (!IsRemoved)
                    await Dialogs.AlertAsync("Download kept as it is",
                        $"AO3 now has {outcome.OnAO3} {(outcome.OnAO3 == 1 ? "chapter" : "chapters")}, fewer than the {outcome.Saved} saved on this device, so the saved copy was kept as it is.");
                return;
            }
            if (!IsRemoved)
                MainWindow.Current.Announce(outcome.Added > 0
                    ? $"Download updated: {outcome.Added} new {(outcome.Added == 1 ? "chapter" : "chapters")}"
                    : "Download updated");
            // The EPUB follows the text even when the reader has closed, so share
            // and export never keep the old chapters.
            var epub = UpdateEpubAsync();
            // The reader showing the new chapters takes over where this one is
            // (ContinueFrom), once Listen stops, so it isn't cut off: as when the
            // rest of a work finishes loading.
            while (Reader is { IsListening: true } && !IsRemoved) await Task.Delay(TimeSpan.FromSeconds(2));
            if (!IsRemoved) SwapReader(MakeReader(OfflineReader(fetched.Summary.ChapterCount)));
            await epub;
        }
        finally
        {
            _isUpdating = false;
            if (_newChapters is { } current) current.IsUpdating = false;
            UpdateMoreButton();
        }
    }

    private async Task UpdateEpubAsync()
    {
        try
        {
            await AppHost.Client.DownloadEpubAsync(_work.Ao3Id);
            _isDownloaded = true;
        }
        catch (Exception e)
        {
            AppHost.Log($"Updating the EPUB of {_work.Ao3Id} failed: {e.Message}");
            if (!IsRemoved)
                await Dialogs.AlertAsync("Couldn't update the download",
                    $"The new chapters are saved for offline reading, but the EPUB download failed: {e.Message}");
        }
    }
}
