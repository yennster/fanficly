using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using DispatcherQueue = Microsoft.UI.Dispatching.DispatcherQueue;
using DispatcherQueuePriority = Microsoft.UI.Dispatching.DispatcherQueuePriority;
using Windows.System.Display;
using Windows.UI.ViewManagement;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// The reader (ReaderView): a work's chapters in one of three modes —
/// continuous scroll, "Swipe by chapter" (one chapter per page) and page-by-page
/// (pages that fit the window, two side by side on a wide one) — with the
/// chapter header and indicator, the chapters and Aa menus, full screen, Listen
/// (on-device narration with a karaoke highlight), reading-position save and
/// restore, and the Stats reading-time timer.
///
/// Not a screen itself: <see cref="WorkDetailScreen"/> and
/// <see cref="SavedWorkReaderScreen"/> host it and add their own toolbar items
/// (<see cref="SetTrailingItems"/>), and forward the screen lifecycle and keys.
/// The reader draws its own top bar in its theme's colours, like the Mac reader's
/// toolbar painted with the page background.
/// </summary>
internal sealed partial class ReaderView
{
    private readonly string _title;
    private readonly string _author;
    private readonly string _authorUsername;
    private readonly IReadOnlyList<AO3ChapterPayload> _chapters;
    private readonly int[] _chapterOrder;
    /// <summary>The work's chapter count; more than <see cref="_chapters"/> holds
    /// while the reader has opened on one chapter and the rest are loading.</summary>
    private readonly int _totalChapters;
    private readonly AO3WorkSummary? _summary;

    private readonly ReaderBrushes _brushes = new();
    private readonly ReaderTextMeasurer _measurer = new();
    private readonly SpeechController _speech;
    private readonly ReaderAnchorSampler _sampler = new();
    private readonly DispatcherQueue _dispatcher;

    // MARK: - State (the Swift view's @State)

    /// <summary>Start of the current active-reading span (Stats); null while paused.</summary>
    private DateTimeOffset? _activeSpanStart;
    private int _selectedChapter = 1;
    private int _visibleChapter = 1;
    private ReadingAnchor? _currentAnchor;
    private bool _loadedFromDisk;
    /// <summary>Where a saved position past the loaded chapters was moved to (see
    /// <see cref="ChapterTracking.ClampedAnchor"/>). Never saved: opening a shorter
    /// copy mustn't overwrite the real place. Reading on from it saves as usual.</summary>
    private ReadingAnchor? _clampedRestoreAnchor;
    /// <summary>Not saved until the reader moves (#160); see <see cref="OpenedAnchorGate"/>.</summary>
    private OpenedAnchorGate _openedAnchorGate;
    private bool _isRestoring;
    private DateTimeOffset _lastSaveAt = DateTimeOffset.MinValue;
    /// <summary>"Swipe by chapter"'s one-shot paragraph restore.</summary>
    private ReadingAnchor? _pendingParagraphRestore;
    private bool _isUIMinimized;
    private int? _listeningChapter;
    private int _reportedChapter = -1;

    private ReadingMode _builtMode;
    private bool _bodyBuilt;
    private bool _visible;
    private bool _windowVisible = true;
    private bool _immersive;
    private bool _removed;
    private DisplayRequest? _displayRequest;
    private bool _displayActive;
    private readonly HashSet<string> _pendingKeys = [];
    private bool _settingsFlushQueued;

    // MARK: - Elements

    /// <summary>The reader's root (AutomationId <c>reader.root</c>).</summary>
    public Grid Root { get; }
    private readonly Grid _bodyHost;
    private readonly Grid _bottomHost;

    /// <summary>The chapter the reader is on changed (for the parent's Comments action).</summary>
    public event Action<int>? ChapterChanged;

    public string WorkTitle => _title;

    /// <summary>"Show images in stories", and only for works rated General or Teen:
    /// Mature, Explicit and unrated works stay text-only on Windows (see
    /// <see cref="ContentFilter.AllowsStoryImages"/>).</summary>
    private bool ShowImages => ReaderPrefs.ShowImages && ContentFilter.AllowsStoryImages(_summary?.Rating);

    public ReaderView(string title, string author, string authorUsername, IReadOnlyList<AO3ChapterPayload> chapters, AO3WorkSummary? summary,
                      int totalChapters = 0)
    {
        ReaderProfile.MigrateLegacySettingsIfNeeded();
        _title = title;
        _author = author;
        _authorUsername = authorUsername;
        _chapters = chapters.OrderBy(c => c.Index).ToList();
        _chapterOrder = _chapters.Select(c => c.Index).ToArray();
        _totalChapters = Math.Max(totalChapters, _chapters.Count);
        _summary = summary;
        if (_chapters.Count > 0) _selectedChapter = _visibleChapter = _chapters[0].Index;

        _dispatcher = DispatcherQueue.GetForCurrentThread();
        _speech = new SpeechController(_dispatcher);
        _speech.Changed += OnSpeechChanged;
        _speech.Finished += AdvanceNarration;

        _brushes.Update(ReaderPrefs.Theme);

        Root = new RegionGrid("reader.root", title);
        foreach (var height in new[] { GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto })
            Root.RowDefinitions.Add(new RowDefinition { Height = height });
        Root.Background = _brushes.Background;
        Root.RequestedTheme = _brushes.ElementTheme;

        BuildHeader();
        Root.Children.Add(_header.Row(0));
        BuildIndicator();
        Root.Children.Add(_indicator.Row(1));
        UpdateHeaderChapter();
        _bodyHost = new Grid { Background = _brushes.Background };
        Root.Children.Add(_bodyHost.Row(2));
        _bottomHost = new Grid();
        Root.Children.Add(_bottomHost.Row(3));
        Root.Children.Add(_measurer.Host.Row(0));

        Root.Loaded += OnRootLoaded;
        Root.ContextFlyout = BuildAccessibilityMenu();

        KeyValueStores.Default.Changed += OnSettingChanged;
        Theme.Changed += OnAppThemeChanged;
        var window = MainWindow.Current;
        window.VisibilityChanged += OnWindowVisibilityChanged;
        window.AppWindow.Changed += OnAppWindowChanged;
        window.AppWindow.Closing += OnAppWindowClosing;
    }

    /// <summary>From a saved work's offline chapters (Swift: <c>ReaderView(work:)</c>).</summary>
    public static ReaderView FromWork(Work work, IReadOnlyList<Chapter> chapters)
    {
        var payloads = chapters.OrderBy(c => c.Index)
            .Select(c => new AO3ChapterPayload(c.Index, c.Title, c.BodyHtml, c.AoId)).ToList();
        return new ReaderView(work.Title, work.AuthorName, work.AuthorUsername, payloads, SummaryOf(work));
    }

    public static ReaderView FromPayload(AO3WorkPayload payload) =>
        new(payload.Summary.Title, payload.Summary.Author, payload.Summary.AuthorUsername, payload.Chapters, payload.Summary);

    /// <summary>From one chapter of a work whose other chapters are still loading
    /// (Windows only: AO3's whole-work page is its slowest). Progress is reckoned
    /// against the whole work, so finishing this chapter doesn't finish the story.</summary>
    public static ReaderView FromChapterPage(AO3WorkChapterPage page) =>
        new(page.Payload.Summary.Title, page.Payload.Summary.Author, page.Payload.Summary.AuthorUsername, page.Payload.Chapters,
            page.Payload.Summary, Math.Max(page.ChapterIds.Count, page.Payload.Summary.ChapterCount));

    /// <summary>Narration is playing (a reader with more chapters waits for it to stop).</summary>
    public bool IsListening => _speech.IsActive;

    /// <summary>Opens where <paramref name="previous"/>, a reader of the same work
    /// with fewer chapters, is. Call before the reader is shown.</summary>
    public void ContinueFrom(ReaderView previous)
    {
        // A place moved onto the chapters the shorter reader had: this one may
        // hold the saved chapter, so it reads the saved place itself.
        if (previous._currentAnchor is { } moved && moved == previous._clampedRestoreAnchor) return;
        _loadedFromDisk = true;
        _openedAnchorGate = previous._openedAnchorGate;
        if (previous._currentAnchor is { } anchor && ChapterAt(anchor.Chapter) is not null)
        {
            _currentAnchor = anchor;
            _selectedChapter = _visibleChapter = anchor.Chapter;
        }
        else if (ChapterAt(previous.EffectiveChapter) is not null)
        {
            _selectedChapter = _visibleChapter = previous.EffectiveChapter;
        }
    }

    public static AO3WorkSummary SummaryOf(Work work) => work.ToSummary();

    // MARK: - Derived settings

    private ReadingMode Mode => ReaderPrefs.Mode;
    private static double Zoom => ReaderPrefs.ZoomScale;
    private double FontSize => ReaderPrefs.FontSizePt / Zoom;

    /// <summary>The reader's text settings, divided by the UI zoom (so the app's
    /// zoom doesn't change the story's text size, as on the Mac).</summary>
    private static ReaderTypography CurrentTypography() => new(
        ReaderPrefs.FontFamily,
        ReaderPrefs.FontSizePt / Zoom,
        ReaderPrefs.LineSpacingPt / Zoom,
        ReaderPrefs.ParagraphSpacingPt / Zoom,
        ReaderPrefs.KerningPt / Zoom,
        ReaderPrefs.BoldText);

    private ReaderTextStyle TextStyle() => _measurer.StyleFor(CurrentTypography());

    /// <summary>The chapter actually being read: the visible one in continuous
    /// scroll, the selected page or chapter otherwise.</summary>
    public int EffectiveChapter => Mode == ReadingMode.Continuous ? _visibleChapter : _selectedChapter;

    private static double ColumnWidth(double containerWidth, double widthPercent) =>
        ReaderMetrics.TextColumnWidth(containerWidth, widthPercent, ReaderPrefs.FontSizePt, limitLineLength: false);

    private AO3ChapterPayload? ChapterAt(int index) => _chapters.FirstOrDefault(c => c.Index == index);

    private static string ChapterLabel(AO3ChapterPayload chapter) =>
        chapter.Title.Length == 0 ? $"Chapter {chapter.Index}" : $"Chapter {chapter.Index}: {chapter.Title}";

    // MARK: - Lifecycle (ReaderLifecycleModifier)

    private void OnRootLoaded(object sender, RoutedEventArgs e)
    {
        if (_bodyBuilt || _removed) return;
        Root.XamlRoot.Changed += (_, _) => _measurer.ClearCache();
        RebuildBody();
    }

    /// <summary>The screen came on top.</summary>
    public void Appearing()
    {
        _visible = true;
        ApplyKeepScreenAwake(ReaderPrefs.KeepScreenAwake);
        StartReadingTimer();
        if (MainWindow.Current.IsFullScreen) EnterImmersive();
        ReportCurrentChapter(force: true);
    }

    /// <summary>The screen left the top (popped, or something pushed over it).</summary>
    public void Disappearing()
    {
        _visible = false;
        _speech.Stop();
        _listeningChapter = null;
        ApplyKeepScreenAwake(false);
        RecordReadingSpan(restart: false);
        PersistNow();
        if (_immersive)
        {
            ExitImmersive();
            if (MainWindow.Current.IsFullScreen) MainWindow.Current.ToggleFullScreen();
        }
    }

    /// <summary>The screen was popped for good.</summary>
    public void Removed()
    {
        if (_removed) return;
        _removed = true;
        // Only when the reader closes, not when Comments or an author page
        // opens over it: the prompt must never land on top of a story.
        ReviewPrompter.Shared.ReaderClosed(() => ReviewPromptStats.From(
            ReadingStatsStore.Snapshots(AppHost.Library)
                .Select(s => (s.IsFinished, (IEnumerable<string>)s.DaySeconds.Keys, s.FirstReadAt))));
        Release();
    }

    /// <summary>Hands over to a reader of the same work with more of it loaded:
    /// records the reading time and position, then lets go, without the closing
    /// prompt or leaving full screen (the story is still open).</summary>
    public void Retire()
    {
        if (_removed) return;
        _removed = true;
        if (_visible)
        {
            RecordReadingSpan(restart: false);
            PersistNow();
        }
        _visible = false;
        Release();
    }

    private void Release()
    {
        _speech.Dispose();
        ApplyKeepScreenAwake(false);
        KeyValueStores.Default.Changed -= OnSettingChanged;
        Theme.Changed -= OnAppThemeChanged;
        var window = MainWindow.Current;
        window.VisibilityChanged -= OnWindowVisibilityChanged;
        window.AppWindow.Changed -= OnAppWindowChanged;
        window.AppWindow.Closing -= OnAppWindowClosing;
        TeardownBody();
    }

    private void OnWindowVisibilityChanged(object sender, WindowVisibilityChangedEventArgs args)
    {
        _windowVisible = args.Visible;
        if (_removed) return;
        // Foregrounded again: restart the timer only while this reader is the
        // screen on top — a reader buried under a pushed screen records nothing.
        if (args.Visible) { if (_visible) StartReadingTimer(); }
        else
        {
            // Listening goes on minimized and counts as reading time (#161),
            // so narration that's playing keeps the span going.
            RecordReadingSpan(restart: _visible && _speech.IsPlaying);
            if (_visible) PersistNow();
        }
    }

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_removed || !_visible) return;
        RecordReadingSpan(restart: false);
        PersistNow();
    }

    /// <summary>Keeps the display awake while reading (like a video player).</summary>
    private void ApplyKeepScreenAwake(bool enabled)
    {
        try
        {
            if (enabled && !_displayActive)
            {
                _displayRequest ??= new DisplayRequest();
                _displayRequest.RequestActive();
                _displayActive = true;
            }
            else if (!enabled && _displayActive)
            {
                _displayRequest?.RequestRelease();
                _displayActive = false;
            }
        }
        catch (Exception e)
        {
            AppHost.Log($"Display request failed: {e.Message}");
        }
    }

    // MARK: - Settings changes (@AppStorage onChange)

    private void OnSettingChanged(string key)
    {
        if (!ReaderPrefs.IsReaderKey(key)) return;
        _dispatcher.TryEnqueue(() =>
        {
            if (_removed) return;
            _pendingKeys.Add(key);
            if (_settingsFlushQueued) return;
            _settingsFlushQueued = true;
            // A profile switch writes a dozen keys at once: apply them together.
            _dispatcher.TryEnqueue(DispatcherQueuePriority.Low, ApplyPendingSettings);
        });
    }

    private void ApplyPendingSettings()
    {
        _settingsFlushQueued = false;
        if (_removed) return;
        var keys = _pendingKeys.ToList();
        _pendingKeys.Clear();

        if (keys.Any(ReaderPrefs.IsProfileKey)) LibrarySyncManager.QueueBackupShared(AppHost.Library);
        if (keys.Contains(ReaderPrefs.KeepScreenAwakeKey) && _visible) ApplyKeepScreenAwake(ReaderPrefs.KeepScreenAwake);

        var themeChanged = keys.Any(k => ReaderPrefs.Is(k, ReaderPrefs.ThemeBase));
        var modeChanged = keys.Any(k => ReaderPrefs.Is(k, ReaderPrefs.ModeBase)) && ReaderPrefs.Mode != _builtMode;
        var layoutChanged = keys.Any(k =>
            ReaderPrefs.Is(k, ReaderPrefs.FontFamilyBase) || ReaderPrefs.Is(k, ReaderPrefs.FontSizeBase)
            || ReaderPrefs.Is(k, ReaderPrefs.LineSpacingBase) || ReaderPrefs.Is(k, ReaderPrefs.ParagraphSpacingBase)
            || ReaderPrefs.Is(k, ReaderPrefs.KerningBase) || ReaderPrefs.Is(k, ReaderPrefs.BoldTextBase)
            || ReaderPrefs.Is(k, ReaderPrefs.WidthPercentBase) || k == ReaderPrefs.ShowImagesKey || k == ReaderPrefs.ZoomKey);
        var spreadChanged = keys.Any(k => ReaderPrefs.Is(k, ReaderPrefs.TwoPageSpreadBase) || ReaderPrefs.Is(k, ReaderPrefs.SpreadWidthBase));

        if (themeChanged) ApplyTheme();
        if (!_bodyBuilt) return;
        if (modeChanged || ((themeChanged || layoutChanged) && _builtMode != ReadingMode.PageByPage))
        {
            RebuildBody();
        }
        else if (_builtMode == ReadingMode.PageByPage && (layoutChanged || spreadChanged || themeChanged))
        {
            if (themeChanged) RefillAllPageSlots();
            SchedulePagination();
        }
        RefreshChrome();
    }

    private void OnAppThemeChanged()
    {
        if (_removed || ReaderPrefs.Theme != ReaderTheme.System) return;
        var before = _brushes.Scheme;
        ApplyTheme();
        if (_bodyBuilt && before != _brushes.Scheme)
        {
            if (_builtMode == ReadingMode.PageByPage) RefillAllPageSlots();
            else RebuildBody();
        }
    }

    private void ApplyTheme()
    {
        _brushes.Update(ReaderPrefs.Theme);
        Root.RequestedTheme = _brushes.ElementTheme;
    }

    // MARK: - Body

    private void TeardownBody()
    {
        TeardownContinuous();
        TeardownPaginated();
        TeardownPages();
        _bodyHost.Children.Clear();
    }

    /// <summary>Builds the body for the current mode. Each mode restores from the
    /// live anchor (loaded from disk the first time), so switching modes keeps
    /// your place.</summary>
    private void RebuildBody()
    {
        if (_removed) return;
        if (_bodyBuilt) PersistNow();
        TeardownBody();
        _bodyBuilt = true;
        _builtMode = Mode;
        _sampler.BeginResize(0);
        FrameworkElement content = _builtMode switch
        {
            ReadingMode.Paginated => BuildPaginated(),
            ReadingMode.PageByPage => BuildPages(),
            _ => BuildContinuous(),
        };
        AutomationProperties.SetAutomationId(content, "reader.content");
        _bodyHost.Children.Add(content);
        RefreshChrome();
    }

    // MARK: - Chapter selection

    /// <summary>Jumps to a chapter (the chapters menu, Ctrl+←/→, a shoulder button,
    /// narration following along).</summary>
    private void SelectChapter(int index, bool userInitiated = true)
    {
        if (ChapterAt(index) is null) return;
        var changed = index != _selectedChapter;
        _selectedChapter = index;
        switch (_builtMode)
        {
            case ReadingMode.Continuous:
                _visibleChapter = index;
                // Always scroll, even when the selection didn't change: you may
                // have scrolled away from it.
                if (userInitiated || changed) _ = ScrollToChapterAsync(index);
                break;
            case ReadingMode.Paginated:
                if (changed) OnPaginatedChapterSelected(index, fromFlip: false);
                break;
            case ReadingMode.PageByPage:
                if (changed) OnPageChapterChanged(index);
                break;
        }
        ReportCurrentChapter();
        RefreshChrome();
    }

    /// <summary>Turns a "page" in Swipe-by-chapter (a chapter), clamped to the ends.</summary>
    private void TurnChapter(bool forward)
    {
        if (ChapterTracking.AdjacentChapter(_chapterOrder, EffectiveChapter, forward) is { } target)
            SelectChapter(target);
    }

    private void ReportCurrentChapter(bool force = false)
    {
        var chapter = EffectiveChapter;
        if (!force && chapter == _reportedChapter) return;
        _reportedChapter = chapter;
        UpdateHeaderChapter();
        ChapterChanged?.Invoke(chapter);
    }

    // MARK: - Reading position (save / restore)

    /// <summary>Loads the saved anchor from disk the first time; afterwards the
    /// live in-memory anchor (so mode switches re-anchor correctly).</summary>
    private ReadingAnchor? LoadAnchorIfNeeded()
    {
        if (!_loadedFromDisk)
        {
            _loadedFromDisk = true;
            if (_summary is { } summary
                && ReaderModule.OpeningAnchor(summary.Id) is { } saved
                && ChapterTracking.ClampedAnchor(saved, _chapterOrder, chapter => Paragraphs(chapter).Count - 1) is { } anchor)
            {
                if (anchor != saved) _clampedRestoreAnchor = anchor;
                _openedAnchorGate = new OpenedAnchorGate(anchor);
                _currentAnchor = anchor;
                _selectedChapter = anchor.Chapter;
                _visibleChapter = anchor.Chapter;
            }
        }
        return _currentAnchor;
    }

    private void SetCurrentAnchor(ReadingAnchor anchor, bool save = true, bool force = false)
    {
        _currentAnchor = anchor;
        if (save) SaveProgress(anchor, force);
    }

    private void PersistNow()
    {
        if (_currentAnchor is { } anchor) SaveProgress(anchor, force: true, syncWidgetImmediately: true);
    }

    private void SaveProgress(ReadingAnchor anchor, bool force = false, bool syncWidgetImmediately = false)
    {
        // Reading on from the moved place: it's a real place again from now on.
        if (anchor != _clampedRestoreAnchor) _clampedRestoreAnchor = null;
        if (!_openedAnchorGate.AllowsSave(anchor) || _summary is not { } summary || anchor == _clampedRestoreAnchor
            || ReadingProgressFraction(anchor) is not { } progress) return;
        var now = DateTimeOffset.Now;
        if (!force && now - _lastSaveAt < TimeSpan.FromSeconds(1.5)) return;
        _lastSaveAt = now;
        CheckpointReadingTime();
        try
        {
            ReadingProgressStore.Save(summary.Id, anchor.Chapter, anchor.Paragraph, _title, _author, AppHost.Library,
                                      progress: progress, syncWidgetImmediately: syncWidgetImmediately);
        }
        catch (Exception e)
        {
            AppHost.Log($"Saving reading progress failed: {e.Message}");
        }
    }

    /// <summary>How far through the work an anchor is, 0…1: whole chapters before
    /// it plus the fraction of its chapter's paragraphs. Null when its chapter isn't
    /// loaded: reading that as 0 would overwrite the real progress.</summary>
    private double? ReadingProgressFraction(ReadingAnchor anchor)
    {
        var chapterOffset = Array.IndexOf(_chapterOrder, anchor.Chapter);
        if (chapterOffset < 0) return null;
        var chapter = _chapters[chapterOffset];
        var paragraphCount = Math.Max(Paragraphs(chapter.Index).Count, 1);
        var denominator = Math.Max(paragraphCount - 1, 1);
        var paragraphProgress = Math.Clamp((double)anchor.Paragraph / denominator, 0, 1);
        // With only some chapters loaded, the chapters before this one are
        // counted by number, not by what's in hand.
        var before = _totalChapters > _chapters.Count ? Math.Max(chapter.Index - 1, 0) : chapterOffset;
        return Math.Clamp((before + paragraphProgress) / _totalChapters, 0, 1);
    }

    /// <summary>The final paragraph's anchor once the end of the work is on screen
    /// (so a finished work reads 100%), else null.</summary>
    private ReadingAnchor? EndOfContent(IReadOnlyDictionary<string, double> offsets, double viewportHeight) =>
        ChapterTracking.EndOfContentAnchor(offsets, _chapters, viewportHeight, ShowImages);

    // MARK: - Reading-time stats

    /// <summary>Begins (or resumes) timing a reading span. A span still running
    /// (narration timed while minimized, #161) is recorded first, so restoring
    /// the window doesn't drop the time listened.</summary>
    private void StartReadingTimer()
    {
        if (!_visible || !_windowVisible) return;
        if (_activeSpanStart is not null) RecordReadingSpan(restart: true);
        else _activeSpanStart = DateTimeOffset.Now;
    }

    /// <summary>Records the active reading time since the span started (capped at
    /// 4 h, so a reader left open overnight can't inflate the totals), then clears
    /// or restarts the span.</summary>
    private void RecordReadingSpan(bool restart)
    {
        if (_activeSpanStart is not { } start)
        {
            if (restart) _activeSpanStart = DateTimeOffset.Now;
            return;
        }
        var elapsed = (DateTimeOffset.Now - start).TotalSeconds;
        _activeSpanStart = restart ? DateTimeOffset.Now : null;
        if (elapsed < 1 || _summary is not { } summary) return;
        var capped = Math.Min(elapsed, 4 * 3600);
        // Credit only as far as you've actually read.
        var progress = _currentAnchor is { } anchor && anchor != _clampedRestoreAnchor
            ? ReadingProgressFraction(anchor) ?? 0 : 0;
        try
        {
            var justFinished = ReadingStatsStore.Record(
                summary.Id, _title, _author, summary.Fandoms, summary.Categories, summary.Relationships,
                summary.Rating, summary.WordCount, capped, AppHost.Library,
                progress: progress, isComplete: summary.IsComplete);
            if (justFinished) ReviewPrompter.Shared.StoryFinished();
        }
        catch (Exception e)
        {
            AppHost.Log($"Recording reading time failed: {e.Message}");
        }
    }

    /// <summary>Persists a long uninterrupted span (≥ 2 min) so a force-quit doesn't lose it.</summary>
    private void CheckpointReadingTime()
    {
        if (_activeSpanStart is { } start && (DateTimeOffset.Now - start).TotalSeconds >= 120)
            RecordReadingSpan(restart: true);
    }

    // MARK: - Narration (Listen)

    private void ToggleListening()
    {
        if (_speech.IsActive)
        {
            _speech.Stop();
            _listeningChapter = null;
            MainWindow.Current.Announce("Stopped listening");
        }
        else
        {
            StartNarration();
        }
    }

    /// <summary>Picks up from the live reading position (speech paragraphs are
    /// index-aligned with the rendered ones).</summary>
    private void StartNarration()
    {
        if (_currentAnchor is { } anchor) Narrate(anchor.Chapter, anchor.Paragraph);
        else Narrate(EffectiveChapter, 0);
    }

    /// <summary>Jumps narration to a chapter (from its top), keeping the page in sync.</summary>
    private void NarrateToChapter(int index)
    {
        if (index == _listeningChapter) return;
        SelectChapter(index, userInitiated: false);
        _visibleChapter = index;
        Narrate(index, 0);
    }

    private void Narrate(int chapterIndex, int paragraph)
    {
        if (ChapterAt(chapterIndex) is not { } chapter) return;
        var label = chapter.Title.Length == 0 ? $"Chapter {chapterIndex}" : $"Chapter {chapterIndex}: {chapter.Title}";
        var previous = _listeningChapter;
        _listeningChapter = chapterIndex;
        _speech.Play(HTMLToAttributed.SpeechParagraphs(chapter.BodyHtml, ShowImages), _title, _author, label, paragraph);
        if (previous != chapterIndex) OnListeningChapterChanged();
    }

    /// <summary>A chapter finished: roll on to the next, or stop at the end.</summary>
    private void AdvanceNarration()
    {
        if (_listeningChapter is not { } current
            || ChapterTracking.AdjacentChapter(_chapterOrder, current, forward: true) is not { } target)
        {
            _speech.Stop();
            _listeningChapter = null;
            RefreshChrome();
            return;
        }
        // Follow along visually so the page tracks what's being read.
        SelectChapter(target, userInitiated: false);
        _visibleChapter = target;
        Narrate(target, 0);
    }

    private int _lastSpokenParagraph = -1;
    private bool _lastSpeechActive;
    private bool _lastSpeechPlaying;

    private void OnSpeechChanged()
    {
        if (_removed) return;
        if (_speech.IsActive != _lastSpeechActive)
        {
            _lastSpeechActive = _speech.IsActive;
            if (!_speech.IsActive) _listeningChapter = null;
            RefreshChrome(); // the narration bar comes or goes (a page-area change)
        }
        if (_speech.IsPlaying != _lastSpeechPlaying)
        {
            _lastSpeechPlaying = _speech.IsPlaying;
            OnNarrationPlayingChanged();
        }
        UpdateNarrationBar();
        ApplyHighlight();
        if (_speech.IsActive && _speech.CurrentParagraph != _lastSpokenParagraph)
        {
            _lastSpokenParagraph = _speech.CurrentParagraph;
            OnSpokenParagraphChanged();
        }
    }

    private void OnListeningChapterChanged()
    {
        _lastSpokenParagraph = -1;
        ApplyHighlight();
        switch (_builtMode)
        {
            case ReadingMode.Continuous: ScrollToSpokenParagraph(); break;
            case ReadingMode.PageByPage: HandleListeningChapterChange(_listeningChapter); break;
        }
    }

    /// <summary>Listening counts as reading time (#161). With the window up the
    /// reader's own timer runs, narration or not; minimized, only narration that's
    /// playing is timed, so pausing it from the media keys ends the span and
    /// playing again starts a new one.</summary>
    private void OnNarrationPlayingChanged()
    {
        if (_windowVisible || !_visible) return;
        if (!_speech.IsPlaying) RecordReadingSpan(restart: false);
        else if (_activeSpanStart is null) _activeSpanStart = DateTimeOffset.Now;
    }

    private void OnSpokenParagraphChanged()
    {
        // The narrated paragraph is the reading place, saved here so it's kept
        // with the window minimized too, where the page may not follow (#161).
        // Throttled like scrolling's saves.
        if (_listeningChapter is { } chapter) SetCurrentAnchor(new ReadingAnchor(chapter, _speech.CurrentParagraph));
        switch (_builtMode)
        {
            case ReadingMode.Continuous: ScrollToSpokenParagraph(); break;
            case ReadingMode.Paginated: ScrollPaginatedToSpokenParagraph(); break;
            case ReadingMode.PageByPage: HandleSpeechParagraphChange(_speech.CurrentParagraph); break;
        }
    }

    /// <summary>The paragraph to karaoke-highlight in a chapter, or null.</summary>
    private int? HighlightedParagraph(int chapterIndex) =>
        _speech.IsActive && _listeningChapter == chapterIndex ? _speech.CurrentParagraph : null;

    private void ApplyHighlight()
    {
        switch (_builtMode)
        {
            case ReadingMode.Continuous: ApplyContinuousHighlight(); break;
            case ReadingMode.Paginated: ApplyPaginatedHighlight(); break;
            case ReadingMode.PageByPage: ApplyPageHighlight(); break;
        }
    }

    // MARK: - Controls (chrome) and full screen

    /// <summary>Shows or hides the reader's controls (the middle-third tap, Esc, the
    /// accessibility command). Page-by-page re-measures its pages for the new room.</summary>
    private void SetMinimized(bool minimized)
    {
        if (_isUIMinimized == minimized) return;
        _isUIMinimized = minimized;
        RefreshChrome();
    }

    private void ToggleChromeAccessibly()
    {
        SetMinimized(!_isUIMinimized);
        MainWindow.Current.Announce(_isUIMinimized ? "Reader controls hidden" : "Reader controls shown");
    }

    private string ChromeActionName => _isUIMinimized ? "Show reader controls" : "Hide reader controls";

    /// <summary>The full-screen button: the window goes full screen with the sidebar,
    /// title bar and reader controls out of the way; Esc, F11 or the button brings
    /// them back.</summary>
    private void ToggleFullScreen()
    {
        MainWindow.Current.ToggleFullScreen();
    }

    private void OnAppWindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (!args.DidPresenterChange || _removed || !_visible) return;
        if (MainWindow.Current.IsFullScreen) EnterImmersive();
        else if (_immersive) ExitImmersive();
    }

    private void EnterImmersive()
    {
        _immersive = true;
        MainWindow.Current.SetChromeHidden(true);
        SetMinimized(true);
        RefreshChrome();
    }

    private void ExitImmersive()
    {
        _immersive = false;
        MainWindow.Current.SetChromeHidden(false);
        SetMinimized(false);
        RefreshChrome();
    }

    // MARK: - Keyboard and controller

    /// <summary>Keys offered by the window before anything else handles them.</summary>
    public bool HandleKey(VirtualKey key, VirtualKeyModifiers modifiers)
    {
        if (!_bodyBuilt || _removed) return false;
        var focused = FocusManager.GetFocusedElement(Root.XamlRoot);
        if (focused is MenuFlyoutItemBase or Slider or ComboBox or ComboBoxItem or ListViewItem or RadioButton or PipsPager)
            return false;
        var activates = focused is ButtonBase or ToggleSwitch;
        // The D-pad moves focus between buttons (the toolbar, the Listen bar);
        // it turns pages only when the story itself has focus.
        if (activates && key is VirtualKey.GamepadDPadLeft or VirtualKey.GamepadDPadRight) return false;
        var ctrl = modifiers == VirtualKeyModifiers.Control;
        var none = modifiers == VirtualKeyModifiers.None;
        var shift = modifiers == VirtualKeyModifiers.Shift;

        switch (key)
        {
            case VirtualKey.Escape when none:
                if (MainWindow.Current.IsFullScreen) { MainWindow.Current.ToggleFullScreen(); return true; }
                if (_isUIMinimized) { ToggleChromeAccessibly(); return true; }
                return false;
            case VirtualKey.L when ctrl:
                ToggleListening();
                return true;
            case VirtualKey.Left when ctrl:
            case VirtualKey.GamepadLeftShoulder:
                TurnChapterAnnounced(forward: false);
                return true;
            case VirtualKey.Right when ctrl:
            case VirtualKey.GamepadRightShoulder:
                TurnChapterAnnounced(forward: true);
                return true;
            case VirtualKey.Left when none:
            case VirtualKey.PageUp when none:
            case VirtualKey.GamepadLeftTrigger:
            case VirtualKey.GamepadDPadLeft:
                return Turn(forward: false, arrow: key == VirtualKey.Left || key == VirtualKey.GamepadDPadLeft);
            case VirtualKey.Right when none:
            case VirtualKey.PageDown when none:
            case VirtualKey.GamepadRightTrigger:
            case VirtualKey.GamepadDPadRight:
                return Turn(forward: true, arrow: key == VirtualKey.Right || key == VirtualKey.GamepadDPadRight);
            case VirtualKey.Space when none && !activates:
                return Turn(forward: true, arrow: false);
            case VirtualKey.Space when shift && !activates:
                return Turn(forward: false, arrow: false);
            case VirtualKey.Home when none:
                GoToChapterEdge(end: false);
                return true;
            case VirtualKey.End when none:
                GoToChapterEdge(end: true);
                return true;
            // Up / Down turn the page in page by page: several Bluetooth page
            // turners and scroll remotes send only those (the Apple app too).
            case VirtualKey.Up when none && !activates && _builtMode == ReadingMode.PageByPage:
                return Turn(forward: false, arrow: false);
            case VirtualKey.Down when none && !activates && _builtMode == ReadingMode.PageByPage:
                return Turn(forward: true, arrow: false);
            // "Volume buttons turn pages" (off by default): remotes in their volume
            // mode send only these. Platform.VolumeKeyGate keeps the shell from
            // also changing the volume. Narration keeps them for its volume.
            case (VirtualKey)VolumeKeyTurn.VolumeUpKey when none && WantsVolumeKeys:
            case (VirtualKey)VolumeKeyTurn.VolumeDownKey when none && WantsVolumeKeys:
                Turn(forward: VolumeKeyTurn.Direction((int)key) == true, arrow: false);
                return true;
            case VirtualKey.Up when none:
                return ScrollBy(-48);
            case VirtualKey.Down when none:
                return ScrollBy(48);
        }
        return false;
    }

    /// <summary>Whether volume keys turn pages now: "Volume buttons turn pages" is on
    /// and narration isn't using them for its volume. They turn as Page Down / Page Up.</summary>
    public bool WantsVolumeKeys => _bodyBuilt && !_removed && ReaderPrefs.VolumeButtonsTurnPages && !_speech.IsActive;

    /// <summary>One "page" forward or back in whatever the mode turns: a page (or a
    /// spread), a chapter in Swipe by chapter for the arrow keys (Page Up / Down and
    /// Space scroll its page first), or a screenful in continuous scroll.</summary>
    private bool Turn(bool forward, bool arrow)
    {
        switch (_builtMode)
        {
            case ReadingMode.PageByPage:
                TurnPageByPage(forward);
                return true;
            case ReadingMode.Paginated:
                if (arrow) { TurnChapter(forward); return true; }
                return ScrollPaginatedPage(forward);
            default:
                return ScrollContinuousPage(forward);
        }
    }

    private bool ScrollBy(double delta) => _builtMode switch
    {
        ReadingMode.Continuous => ScrollContinuousBy(delta),
        ReadingMode.Paginated => ScrollPaginatedBy(delta),
        _ => false,
    };

    private void GoToChapterEdge(bool end)
    {
        switch (_builtMode)
        {
            case ReadingMode.Continuous: _ = ScrollContinuousToChapterEdgeAsync(EffectiveChapter, end); break;
            case ReadingMode.Paginated: ScrollPaginatedToEdge(end); break;
            case ReadingMode.PageByPage: GoToChapterEdgePage(end); break;
        }
    }

    private void TurnChapterAnnounced(bool forward)
    {
        if (ChapterTracking.AdjacentChapter(_chapterOrder, EffectiveChapter, forward) is not { } target) return;
        SelectChapter(target);
        MainWindow.Current.Announce($"Chapter {target} of {_chapters.Count}");
    }

    // MARK: - Accessibility equivalents of the invisible tap zones

    /// <summary>The reading area's context menu (right-click, press and hold,
    /// Shift+F10, the Menu key): the tap-to-turn zones and the chrome toggle as
    /// commands Narrator users can find.</summary>
    private MenuFlyout BuildAccessibilityMenu()
    {
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            if (_builtMode == ReadingMode.PageByPage)
            {
                menu.Items.Add(UI.UI.MenuItem("Next page", () => AccessibilityTurnPage(true), "chevron.right"));
                menu.Items.Add(UI.UI.MenuItem("Previous page", () => AccessibilityTurnPage(false), "chevron.left"));
            }
            if (_chapters.Count > 1)
            {
                menu.Items.Add(UI.UI.MenuItem("Next chapter", () => AccessibilityTurnChapter(true), "forward.fill"));
                menu.Items.Add(UI.UI.MenuItem("Previous chapter", () => AccessibilityTurnChapter(false), "backward.fill"));
            }
            if (menu.Items.Count > 0) menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(UI.UI.MenuItem(ChromeActionName, ToggleChromeAccessibly,
                _isUIMinimized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"));
            menu.Items.Add(UI.UI.MenuItem(_speech.IsActive ? "Stop listening" : "Listen to chapter", ToggleListening,
                _speech.IsActive ? "stop.circle" : "headphones"));
        };
        return menu;
    }

    private void AccessibilityTurnChapter(bool forward)
    {
        var target = EffectiveChapter + (forward ? 1 : -1);
        if (ChapterAt(target) is null) return;
        SelectChapter(target);
        MainWindow.Current.Announce($"Chapter {target} of {_chapters.Count}");
    }

    private void AccessibilityTurnPage(bool forward)
    {
        TurnPageByPage(forward);
        if (_pages.FirstOrDefault(p => p.Id == _selectedPageId) is { } page)
        {
            var total = _pages.Count(p => p.ChapterIndex == page.ChapterIndex);
            MainWindow.Current.Announce($"Page {page.PageIndex + 1} of {total}, chapter {page.ChapterIndex}");
        }
    }

    /// <summary>Whether an input came from inside a control that handles its own
    /// taps (a link, a tag chip, a button), so the reading area's tap zones ignore it.</summary>
    private static bool IsInsideControl(object? source, DependencyObject stopAt)
    {
        var node = source as DependencyObject;
        while (node is not null && node != stopAt)
        {
            if (node is ButtonBase or Microsoft.UI.Xaml.Documents.Hyperlink or ToggleSwitch or Slider or TextBox) return true;
            node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node);
        }
        return false;
    }

    private static bool AnimationsEnabled
    {
        get
        {
            try { return new UISettings().AnimationsEnabled; }
            catch { return true; }
        }
    }
}
