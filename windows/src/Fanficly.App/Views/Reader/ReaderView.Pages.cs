using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// Page-by-page (pageByPageBody): the chapter being read and its neighbours cut
/// into pages that fit the reading area exactly (Core's
/// <see cref="ReaderPaginator"/>, measured with <see cref="ReaderTextMeasurer"/>),
/// shown one per FlipView item — or two side by side on a wide window
/// (<see cref="ReaderSpread"/>). Selection is always a page id, so progress,
/// restore and narration work in pages whatever is on screen.
///
/// Turning: swipe (touch), a pen flick, the mouse wheel, the outer thirds of the
/// page (tap or click), ←/→, Page Up/Down, Space, a controller's triggers and
/// D-pad. The middle third shows or hides the controls.
/// </summary>
internal sealed partial class ReaderView
{
    private List<ChapterPage> _pages = [];
    private Dictionary<int, List<ParagraphAtom>> _atoms = [];
    private string _selectedPageId = "";
    private PageStart? _pageStart;
    private ReaderSpread.Layout? _spreadLayout;
    private readonly PageAreaTracker _pageArea = new();
    private double _stableWidth;
    private double _stableWindowHeight;
    private bool _settledControlsUp = true;
    private PaginationTrigger? _lastTrigger;

    private RegionGrid? _pageRoot;
    private Grid? _pageHost;
    private FlipView? _pageFlip;
    private FrameworkElement? _pageLoading;
    private readonly List<Grid> _pageSlots = [];
    /// <summary>Each FlipView item's page id (a spread's: its left page's).</summary>
    private List<string> _slotIds = [];
    /// <summary>The rendered paragraphs in each filled slot, for the karaoke highlight.</summary>
    private readonly Dictionary<Grid, List<(int Chapter, int Paragraph, FrameworkElement Element)>> _slotBlocks = [];
    private bool _suppressPageFlip;
    private DispatcherQueueTimer? _paginationTimer;
    private DispatcherQueueTimer? _settleTimer;
    private double _settleArea;
    private bool _settleControlsUp;

    // Wheel and pen turns.
    private double _wheelAccumulator;
    private DateTimeOffset _lastWheelTurn = DateTimeOffset.MinValue;
    private (double X, DateTimeOffset At)? _penDown;

    private FrameworkElement BuildPages()
    {
        _isRestoring = true;
        _pages = [];
        _atoms = [];
        _selectedPageId = "";
        _pageStart = null;
        _spreadLayout = null;
        _lastTrigger = null;
        _stableWidth = 0;
        _stableWindowHeight = 0;
        _settledControlsUp = !_isUIMinimized;

        var root = new RegionGrid { Background = _brushes.Background };
        _pageRoot = root;
        _pageHost = new Grid { Background = _brushes.Background };
        _pageHost.SizeChanged += OnPageHostSizeChanged;
        _pageHost.Loaded += (_, _) => SchedulePagination();
        root.Children.Add(_pageHost);

        _pageFlip = new FlipView
        {
            Background = _brushes.Background,
            IsTabStop = false,
            UseTouchAnimationsForAllNavigation = false,
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetName(_pageFlip, "Pages");
        _pageFlip.SelectionChanged += OnPageFlipChanged;
        _pageHost.Children.Add(_pageFlip);

        var ring = new ProgressRing { IsActive = true, Width = 28, Height = 28, Foreground = _brushes.Fg50, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(ring, "Laying out pages");
        _pageLoading = ring;
        _pageHost.Children.Add(ring);
        return root;
    }

    private void TeardownPages()
    {
        _paginationTimer?.Stop();
        _settleTimer?.Stop();
        if (_pageHost is not null) _pageHost.SizeChanged -= OnPageHostSizeChanged;
        if (_pageFlip is not null) _pageFlip.SelectionChanged -= OnPageFlipChanged;
        _pageRoot = null;
        _pageHost = null;
        _pageFlip = null;
        _pageLoading = null;
        _pageSlots.Clear();
        _slotBlocks.Clear();
        _slotIds = [];
        _pages = [];
        _atoms = [];
        _selectedPageId = "";
        _pageStart = null;
        _spreadLayout = null;
        _lastTrigger = null;
    }

    // MARK: - The page area (PageAreaTracker)

    /// <summary>Pages are measured for the page area on screen, with the controls
    /// up or hidden. They shrink at once, so text never runs under the controls,
    /// and grow once the area has held still (0.3 s; 50 ms when the controls
    /// hide, or the old pages would sit over a blank band). A genuine layout
    /// change — the width, or the window's own height — starts over.</summary>
    private void OnPageHostSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var size = e.NewSize;
        var controlsUp = !_isUIMinimized;
        var windowHeight = MainWindow.Current.RootElement.ActualHeight;
        var widthChanged = Math.Abs(_stableWidth - size.Width) > 1;
        var windowChanged = Math.Abs(_stableWindowHeight - windowHeight) > 1;
        if (widthChanged || windowChanged || _stableWidth == 0)
        {
            _stableWidth = size.Width;
            _stableWindowHeight = windowHeight;
            _pageArea.Reset(size.Height, controlsUp);
        }
        else
        {
            _pageArea.Observe(size.Height, controlsUp);
        }

        var toggled = controlsUp != _settledControlsUp;
        _settleArea = size.Height;
        _settleControlsUp = controlsUp;
        _settleTimer ??= CreateSettleTimer();
        _settleTimer.Stop();
        _settleTimer.Interval = TimeSpan.FromMilliseconds(toggled ? 50 : 300);
        _settleTimer.Start();
        SchedulePagination();
    }

    private DispatcherQueueTimer CreateSettleTimer()
    {
        var timer = _dispatcher.CreateTimer();
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            if (_removed || _pageHost is null) return;
            _settledControlsUp = _settleControlsUp;
            _pageArea.Settle(_settleArea);
            SchedulePagination();
        };
        return timer;
    }

    // MARK: - Pagination

    private void SchedulePagination()
    {
        if (_builtMode != ReadingMode.PageByPage || _pageHost is null) return;
        if (_paginationTimer is null)
        {
            _paginationTimer = _dispatcher.CreateTimer();
            _paginationTimer.IsRepeating = false;
            _paginationTimer.Interval = TimeSpan.FromMilliseconds(60);
            _paginationTimer.Tick += (_, _) => RunPagination();
        }
        _paginationTimer.Stop();
        _paginationTimer.Start();
    }

    /// <summary>handlePaginationTrigger + performPagination: re-paginates when
    /// anything that shapes the pages changed, keeping the page on screen in place
    /// (its <see cref="PageStart"/>) when it's in the chapter being paginated.</summary>
    private void RunPagination()
    {
        if (_removed || _builtMode != ReadingMode.PageByPage || _pageHost is null || _pageFlip is null) return;
        if (!_pageHost.IsLoaded) return;
        _ = LoadAnchorIfNeeded();
        var width = _pageHost.ActualWidth;
        var area = _pageArea.PageHeight > 0 ? _pageArea.PageHeight : _pageHost.ActualHeight;
        if (width <= 0 || area <= 0) return;

        // Two pages side by side when the window is wide enough, decided on the
        // controls-up height so full screen keeps the layout.
        var decision = _pageArea.SpreadDecisionHeight > 0 ? _pageArea.SpreadDecisionHeight : area;
        var spread = ReaderPrefs.TwoPageSpread ? ReaderSpread.LayoutFor(new ReaderSize(width, decision), null) : null;
        var zoom = Zoom;
        var trigger = new PaginationTrigger(
            _selectedChapter,
            ReaderPrefs.FontSizePt / zoom,
            ReaderPrefs.FontFamilyRaw,
            spread is null ? ReaderPrefs.WidthPercent : ReaderPrefs.SpreadWidthPercent,
            ReaderPrefs.LineSpacingPt / zoom,
            ReaderPrefs.ParagraphSpacingPt / zoom,
            ReaderPrefs.KerningPt / zoom,
            ReaderPrefs.BoldText,
            ReaderPrefs.ShowImages,
            new ReaderSize(spread?.PageWidth ?? width, area));
        if (_pages.Count > 0 && trigger == _lastTrigger && Equals(spread, _spreadLayout)) return;
        _lastTrigger = trigger;
        _spreadLayout = spread;
        _isRestoring = true;

        var start = _pages.Count == 0 ? null : _pageStart is { } s && s.Chapter == trigger.Chapter ? s : (PageStart?)null;
        PaginationResult result;
        try
        {
            result = ReaderPaginator.PerformPagination(trigger, start, _chapters, _title, _author, _authorUsername, _summary,
                                                       limitLineLength: false, _measurer);
        }
        catch (Exception e)
        {
            AppHost.Log($"Pagination failed: {e}");
            _isRestoring = false;
            return;
        }

        var active = new HashSet<int> { _selectedChapter };
        if (ChapterTracking.AdjacentChapter(_chapterOrder, _selectedChapter, forward: false) is { } previous) active.Add(previous);
        if (ChapterTracking.AdjacentChapter(_chapterOrder, _selectedChapter, forward: true) is { } next) active.Add(next);
        var atoms = _atoms.Where(kv => active.Contains(kv.Key)).ToDictionary(kv => kv.Key, kv => kv.Value);
        foreach (var (chapter, list) in result.Atoms) atoms[chapter] = list;
        _atoms = atoms;
        _pages = result.Pages.ToList();

        RestoreOrValidatePageSelection(result.KeptPageId);
        RebuildPageSlots();
        RefreshChrome();
    }

    private PageStart? StartOf(ChapterPage page) =>
        _atoms.TryGetValue(page.ChapterIndex, out var atoms) ? ReaderPaginator.Start(page, atoms) : null;

    /// <summary>Picks the page to show after (re-)paginating: <paramref name="kept"/>
    /// (the page that starts where the one on screen did), else the page holding
    /// the reading anchor.</summary>
    private void RestoreOrValidatePageSelection(string? kept)
    {
        if (_pages.Count == 0) return;
        var before = _selectedPageId;

        void Select(string id)
        {
            _selectedPageId = id;
            _isRestoring = false;
            if (id != before) HandlePageIdChange(id);
        }

        if (kept is not null && _pages.Any(p => p.Id == kept))
        {
            Select(kept);
            return;
        }

        if (_currentAnchor is { } anchor)
        {
            bool HoldsAnchor(ChapterPage page) =>
                page.ChapterIndex == anchor.Chapter && _atoms.TryGetValue(anchor.Chapter, out var atoms)
                && page.ParagraphIndices.Indices().Any(i => i < atoms.Count && atoms[i].OriginalParagraphIndex == anchor.Paragraph);
            // The work's header-only title page also stands for paragraph 0.
            bool IsTitlePageForAnchor(ChapterPage page) =>
                page.ChapterIndex == anchor.Chapter && page.ParagraphIndices.IsEmpty && anchor.Paragraph == 0;

            // Re-paginating keeps the page you're on while it still holds the
            // anchor. Otherwise prefer the page with the paragraph over the title
            // page: matching the title page first sent a reader on the first page
            // of text back to the cover every time the layout changed.
            var current = _pages.FirstOrDefault(p => p.Id == _selectedPageId);
            if (current is not null && (HoldsAnchor(current) || IsTitlePageForAnchor(current)))
            {
                _isRestoring = false;
                return;
            }
            if ((_pages.FirstOrDefault(HoldsAnchor) ?? _pages.FirstOrDefault(IsTitlePageForAnchor)) is { } matching)
            {
                Select(matching.Id);
                return;
            }
            var chapterPages = _pages.Where(p => p.ChapterIndex == anchor.Chapter).ToList();
            if (chapterPages.Count > 0)
            {
                if (!_atoms.TryGetValue(anchor.Chapter, out var atoms)) return;
                var closest = chapterPages.FirstOrDefault(page =>
                {
                    if (page.ParagraphIndices.IsEmpty) return false;
                    var first = page.ParagraphIndices.Start;
                    return first < atoms.Count && atoms[first].OriginalParagraphIndex >= anchor.Paragraph;
                }) ?? chapterPages[^1];
                Select(closest.Id);
                return;
            }
        }

        if (!_pages.Any(p => p.Id == _selectedPageId))
        {
            var first = _pages.FirstOrDefault(p => p.ChapterIndex == _selectedChapter) ?? _pages[0];
            _selectedPageId = first.Id;
        }
        _isRestoring = false;
        if (_selectedPageId != before) HandlePageIdChange(_selectedPageId);
    }

    /// <summary>A page came on screen (Swift: <c>onChange(of: selectedPageId)</c>).</summary>
    private void HandlePageIdChange(string pageId)
    {
        if (_builtMode != ReadingMode.PageByPage) return;
        var page = _pages.FirstOrDefault(p => p.Id == pageId);
        if (page is null) return;
        var spreads = _spreadLayout is null ? null : ReaderSpread.Spreads(_pages);
        // What a re-pagination keeps in place: the page on screen, or in a spread
        // its left page (restoring a position can select the right one).
        var shown = spreads?.FirstOrDefault(s => s.Contains(pageId))?.Left ?? page;
        _pageStart = StartOf(shown);
        // A spread selects its left page; when its right page ends the work,
        // anchor there instead so reading to the last line still reads 100%.
        var lastChapter = _chapterOrder.Length > 0 ? _chapterOrder.Max() : 0;
        if (spreads?.FirstOrDefault(s => s.Left.Id == pageId)?.Right is { } right
            && right.ChapterIndex == lastChapter
            && _atoms.TryGetValue(right.ChapterIndex, out var rightAtoms)
            && right.ParagraphIndices.End >= rightAtoms.Count)
        {
            page = right;
        }

        if (page.ChapterIndex != _selectedChapter)
        {
            _selectedChapter = page.ChapterIndex;
            _visibleChapter = page.ChapterIndex;
            ReportCurrentChapter();
            SchedulePagination(); // the neighbours of the new chapter
        }

        if (!_isRestoring)
        {
            if (_atoms.TryGetValue(page.ChapterIndex, out var atoms) && !page.ParagraphIndices.IsEmpty)
            {
                // Landing on the work's final page puts the end of the content on
                // screen: anchor to its last paragraph, so progress reads 100%.
                var isFinalPage = page.ChapterIndex == lastChapter && page.ParagraphIndices.End >= atoms.Count;
                var atomIndex = isFinalPage ? page.ParagraphIndices.End - 1 : page.ParagraphIndices.Start;
                if (atomIndex < atoms.Count)
                    SetCurrentAnchor(new ReadingAnchor(page.ChapterIndex, atoms[atomIndex].OriginalParagraphIndex));
            }
            else
            {
                SetCurrentAnchor(new ReadingAnchor(page.ChapterIndex, 0));
            }
        }
        UpdateFooter();
    }

    /// <summary>A chapter was picked (the chapters menu, Ctrl+←/→, narration):
    /// re-paginate around it (Swift: <c>handleChapterIndexChange</c> + the trigger).</summary>
    private void OnPageChapterChanged(int chapter)
    {
        _visibleChapter = chapter;
        if (!_isRestoring && _pages.Count > 0)
        {
            var current = _pages.FirstOrDefault(p => p.Id == _selectedPageId);
            if (current?.ChapterIndex != chapter) SetCurrentAnchor(new ReadingAnchor(chapter, 0), force: true);
        }
        SchedulePagination();
    }

    // MARK: - Slots (the FlipView's items)

    private bool SpreadMode => _spreadLayout is not null;

    private int SlotIndexOf(string pageId)
    {
        if (SpreadMode)
        {
            var spreads = ReaderSpread.Spreads(_pages);
            for (var i = 0; i < spreads.Count; i++) if (spreads[i].Contains(pageId)) return i;
            return -1;
        }
        return _pages.FindIndex(p => p.Id == pageId);
    }

    /// <summary>Re-creates the FlipView's items for new pages (reusing them when
    /// the count hasn't changed) and shows the selected page without animating.</summary>
    private void RebuildPageSlots()
    {
        if (_pageFlip is null) return;
        var ids = SpreadMode ? ReaderSpread.Spreads(_pages).Select(s => s.Id).ToList() : _pages.Select(p => p.Id).ToList();
        _suppressPageFlip = true;
        _pageFlip.UseTouchAnimationsForAllNavigation = false;
        if (ids.Count != _pageSlots.Count)
        {
            _pageFlip.Items.Clear();
            _pageSlots.Clear();
            foreach (var _ in ids)
            {
                var slot = NewSlot();
                _pageSlots.Add(slot);
                _pageFlip.Items.Add(slot);
            }
        }
        foreach (var slot in _pageSlots) ClearSlot(slot);
        _slotIds = ids;
        var index = SlotIndexOf(_selectedPageId);
        if (index >= 0) _pageFlip.SelectedIndex = index;
        _suppressPageFlip = false;
        FillNearbySlots();
        _pageFlip.Visibility = _pages.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_pageLoading is not null) _pageLoading.Visibility = _pages.Count > 0 ? Visibility.Collapsed : Visibility.Visible;
        RestorePageTurnAnimations();
    }

    /// <summary>Page turns animate only when the reader setting (and Windows'
    /// animation setting) allow; rebuilding the pages never animates.</summary>
    private void RestorePageTurnAnimations() =>
        _dispatcher.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (_pageFlip is not null) _pageFlip.UseTouchAnimationsForAllNavigation = ReaderPrefs.PageTurnAnimations && AnimationsEnabled;
        });

    private Grid NewSlot()
    {
        var slot = new Grid { Background = _brushes.Background };
        slot.Tapped += OnPageTapped;
        slot.AddHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler(OnPageWheel), true);
        slot.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(OnPagePointerPressed), true);
        slot.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(OnPagePointerReleased), true);
        return slot;
    }

    private void ClearSlot(Grid slot)
    {
        slot.Children.Clear();
        _slotBlocks.Remove(slot);
    }

    /// <summary>Builds the pages near the one on screen (two either side, or one
    /// spread) and frees the rest.</summary>
    private void FillNearbySlots()
    {
        if (_pageFlip is null || _pageSlots.Count == 0) return;
        var selected = Math.Max(0, SlotIndexOf(_selectedPageId));
        var radius = SpreadMode ? 1 : 2;
        var spreads = SpreadMode ? ReaderSpread.Spreads(_pages) : null;
        for (var i = 0; i < _pageSlots.Count; i++)
        {
            var slot = _pageSlots[i];
            if (Math.Abs(i - selected) > radius)
            {
                if (slot.Children.Count > 0) ClearSlot(slot);
                continue;
            }
            if (slot.Children.Count > 0) continue;
            var blocks = new List<(int, int, FrameworkElement)>();
            if (spreads is not null && _spreadLayout is { } layout && i < spreads.Count) FillSpreadSlot(slot, spreads[i], layout, blocks);
            else if (i < _pages.Count) slot.Children.Add(PageCell(_pages[i], _pageHost?.ActualWidth ?? 0, ReaderPrefs.WidthPercent, blocks));
            _slotBlocks[slot] = blocks;
        }
        MarkSelectedSlot();
        ApplyPageHighlight();
    }

    private void FillSpreadSlot(Grid slot, ReaderSpread.Spread spread, ReaderSpread.Layout layout, List<(int, int, FrameworkElement)> blocks)
    {
        var percent = ReaderPrefs.SpreadWidthPercent;
        var row = new Grid { HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0, layout.LeftX)) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(layout.PageWidth) });
        // The gutter: blank space, no drawn crease.
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0, layout.GutterEnd - layout.GutterStart)) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(layout.PageWidth) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(PageCell(spread.Left, layout.PageWidth, percent, blocks).Col(1));
        if (spread.Right is { } right) row.Children.Add(PageCell(right, layout.PageWidth, percent, blocks).Col(3));
        slot.Children.Add(row);
    }

    /// <summary>One page as drawn (ReaderPageCell): inside a scroll viewer that only
    /// scrolls if the page ever overflows, the column holds the work's header on
    /// the title page, the chapter header at exactly the height the paginator
    /// budgeted, then the page's paragraphs built by the same code the measurer
    /// measures.</summary>
    private RegionGrid PageCell(ChapterPage page, double containerWidth, double requestedPercent, List<(int, int, FrameworkElement)> blocks)
    {
        var cell = new RegionGrid { Background = _brushes.Background, Tag = page.Id };
        var chapter = ChapterAt(page.ChapterIndex);
        if (chapter is null || !_atoms.TryGetValue(page.ChapterIndex, out var atoms) || containerWidth <= 0) return cell;

        // The title page holds only the work header: keep it at least the standard
        // width so narrow margins don't crush its metadata row.
        var percent = page.ParagraphIndices.IsEmpty ? Math.Max(requestedPercent, ReaderSpread.DefaultWidthPercent) : requestedPercent;
        var column = ColumnWidth(containerWidth, percent);
        var t = CurrentTypography();
        var isFirstChapter = page.ChapterIndex == _chapterOrder[0];
        var showTitle = page.PageIndex == 0 && isFirstChapter;
        var showChapterHeader = _chapters.Count > 1
                                && ((page.PageIndex == 0 && !isFirstChapter) || (page.PageIndex == 1 && isFirstChapter));

        var panel = new StackPanel { Width = column, HorizontalAlignment = HorizontalAlignment.Center };
        if (showTitle) panel.Children.Add(TitleHeader().Also(h => h.Margin = new Thickness(0, 0, 0, 16)));
        if (showChapterHeader)
        {
            var height = ReaderPaginator.EstimateChapterHeaderHeight(chapter.Title, column, t.FontSize, t.Family, _measurer);
            panel.Children.Add(ChapterHeaderView(chapter, height));
        }
        if (!page.ParagraphIndices.IsEmpty)
        {
            var rendered = ReaderPageContent.RenderedBlocks(atoms, page.ParagraphIndices);
            var elements = new List<FrameworkElement>();
            panel.Children.Add(ReaderText.Column(rendered.Select(b => b.Text), TextStyle(), _brushes.Foreground, elements));
            for (var i = 0; i < rendered.Count && i < elements.Count; i++)
                blocks.Add((page.ChapterIndex, rendered[i].OriginalParagraphIndex, elements[i]));
        }

        cell.Children.Add(new ScrollViewer
        {
            Content = panel,
            Margin = new Thickness(0, ReaderPaginator.PageVerticalMargin, 0, ReaderPaginator.PageVerticalMargin),
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollMode = ScrollMode.Auto,
            ZoomMode = ZoomMode.Disabled,
            IsTabStop = false,
        });
        return cell;
    }

    /// <summary>The selected page (or spread) carries <c>reader.page.left</c> /
    /// <c>reader.page.right</c> and the page's name; the others carry nothing, so
    /// tests and Narrator find exactly the pages on screen.</summary>
    private void MarkSelectedSlot()
    {
        var selected = SlotIndexOf(_selectedPageId);
        for (var i = 0; i < _pageSlots.Count; i++)
        {
            var cells = Cells(_pageSlots[i]).ToList();
            for (var c = 0; c < cells.Count; c++)
            {
                var cell = cells[c];
                if (i == selected)
                {
                    AutomationProperties.SetAutomationId(cell, c == 0 ? "reader.page.left" : "reader.page.right");
                    var page = _pages.FirstOrDefault(p => p.Id == cell.Tag as string);
                    if (page is not null)
                    {
                        var total = _pages.Count(p => p.ChapterIndex == page.ChapterIndex);
                        AutomationProperties.SetName(cell, $"Page {page.PageIndex + 1} of {total}, chapter {page.ChapterIndex}");
                    }
                }
                else
                {
                    cell.ClearValue(AutomationProperties.AutomationIdProperty);
                    cell.ClearValue(AutomationProperties.NameProperty);
                }
            }
        }
    }

    private static IEnumerable<RegionGrid> Cells(Grid slot)
    {
        foreach (var child in slot.Children)
        {
            if (child is RegionGrid cell) yield return cell;
            else if (child is Grid row)
                foreach (var inner in row.Children.OfType<RegionGrid>()) yield return inner;
        }
    }

    /// <summary>Rebuilds every built page (the theme changed).</summary>
    private void RefillAllPageSlots()
    {
        foreach (var slot in _pageSlots)
        {
            slot.Background = _brushes.Background;
            ClearSlot(slot);
        }
        FillNearbySlots();
    }

    private void ApplyPageHighlight()
    {
        foreach (var blocks in _slotBlocks.Values)
            foreach (var (chapter, paragraph, element) in blocks)
                ReaderText.SetHighlight(element, HighlightedParagraph(chapter) == paragraph ? _brushes.Highlight : null);
    }

    // MARK: - Turning

    private void OnPageFlipChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressPageFlip || _pageFlip is null) return;
        var index = _pageFlip.SelectedIndex;
        if (index < 0 || index >= _slotIds.Count) return;
        var id = _slotIds[index];
        if (SpreadMode && ReaderSpread.Spreads(_pages).FirstOrDefault(s => s.Id == id) is { } spread && spread.Contains(_selectedPageId)) return;
        if (id == _selectedPageId) return;
        _selectedPageId = id;
        HandlePageIdChange(id);
        FillNearbySlots();
    }

    /// <summary>Shows a page (Swift: <c>updatePageSelection</c>): animated when page
    /// turn animations are on.</summary>
    private void UpdatePageSelection(string pageId)
    {
        if (_pageFlip is null) return;
        _selectedPageId = pageId;
        HandlePageIdChange(pageId);
        var index = SlotIndexOf(pageId);
        if (index >= 0 && index != _pageFlip.SelectedIndex)
        {
            _pageFlip.UseTouchAnimationsForAllNavigation = ReaderPrefs.PageTurnAnimations && AnimationsEnabled;
            _suppressPageFlip = true;
            _pageFlip.SelectedIndex = index;
            _suppressPageFlip = false;
        }
        FillNearbySlots();
    }

    /// <summary>One page forward or back; a spread turns two pages at a time.</summary>
    private void TurnPageByPage(bool forward)
    {
        if (_builtMode != ReadingMode.PageByPage || _pages.Count == 0) return;
        string targetId;
        if (SpreadMode)
        {
            var spreads = ReaderSpread.Spreads(_pages);
            var current = -1;
            for (var i = 0; i < spreads.Count; i++) if (spreads[i].Contains(_selectedPageId)) { current = i; break; }
            if (current < 0) return;
            var target = forward ? current + 1 : current - 1;
            if (target < 0 || target >= spreads.Count) return;
            targetId = spreads[target].Id;
        }
        else
        {
            var current = _pages.FindIndex(p => p.Id == _selectedPageId);
            if (current < 0) return;
            var target = forward ? current + 1 : current - 1;
            if (target < 0 || target >= _pages.Count) return;
            targetId = _pages[target].Id;
        }
        UpdatePageSelection(targetId);
    }

    /// <summary>Home / End: the chapter's first or last page.</summary>
    private void GoToChapterEdgePage(bool end)
    {
        var chapterPages = _pages.Where(p => p.ChapterIndex == _selectedChapter).ToList();
        if (chapterPages.Count == 0) return;
        UpdatePageSelection((end ? chapterPages[^1] : chapterPages[0]).Id);
    }

    // MARK: - Narration follow

    /// <summary>Turns to the page holding the paragraph being read aloud.</summary>
    private void HandleSpeechParagraphChange(int paragraph)
    {
        if (_builtMode != ReadingMode.PageByPage || !_speech.IsActive || _listeningChapter is not { } chapter) return;
        if (!_atoms.TryGetValue(chapter, out var atoms)) return;
        var atomIndex = atoms.FindIndex(a => a.OriginalParagraphIndex == paragraph);
        if (atomIndex < 0) return;
        var page = _pages.FirstOrDefault(p => p.ChapterIndex == chapter && p.ParagraphIndices.Contains(atomIndex));
        if (page is not null && !IsShowing(page.Id)) UpdatePageSelection(page.Id);
    }

    /// <summary>Whether a page is on screen (in a spread, either page).</summary>
    private bool IsShowing(string pageId) =>
        pageId == _selectedPageId
        || (SpreadMode && ReaderSpread.Spreads(_pages).FirstOrDefault(s => s.Contains(_selectedPageId)) is { } spread && spread.Contains(pageId));

    private void HandleListeningChapterChange(int? chapter)
    {
        if (_builtMode != ReadingMode.PageByPage || !_speech.IsActive || chapter is not { } target) return;
        // Narration starting in the chapter on screen picks up from the page
        // you're on (HandleSpeechParagraphChange follows it from there).
        if (_pages.FirstOrDefault(p => p.Id == _selectedPageId)?.ChapterIndex == target) return;
        // Moving to another chapter: its first page with text, not the title page.
        if (_pages.FirstOrDefault(p => p.ChapterIndex == target && !p.ParagraphIndices.IsEmpty) is { } page && page.Id != _selectedPageId)
            UpdatePageSelection(page.Id);
    }

    // MARK: - Pointer input

    /// <summary>The outer thirds turn the page; the middle third shows or hides
    /// the controls. Measured across the whole reading area, so in a spread the
    /// left page's outer side goes back and the right page's goes forward.</summary>
    private void OnPageTapped(object sender, TappedRoutedEventArgs e)
    {
        if (_pageHost is null || IsInsideControl(e.OriginalSource, (DependencyObject)sender)) return;
        var x = e.GetPosition(_pageHost).X;
        var w = _pageHost.ActualWidth;
        if (x < w / 3) TurnPageByPage(forward: false);
        else if (x > w * 2 / 3) TurnPageByPage(forward: true);
        else SetMinimized(!_isUIMinimized);
        e.Handled = true;
    }

    /// <summary>The mouse wheel turns pages: a notch (or a touchpad's worth of
    /// scrolling) per page, with a short pause so one flick doesn't skip several.
    /// A page that overflows scrolls first. Ctrl + wheel never zooms.</summary>
    private void OnPageWheel(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint((UIElement)sender);
        if (e.KeyModifiers.HasFlag(Windows.System.VirtualKeyModifiers.Control)) { e.Handled = true; return; }
        if (point.Properties.IsHorizontalMouseWheel) return; // the FlipView pans sideways itself
        e.Handled = true;
        if (PageScrollerUnder(e.OriginalSource, (DependencyObject)sender) is { ScrollableHeight: > 0 } scroller)
        {
            var delta = point.Properties.MouseWheelDelta;
            if ((delta > 0 && scroller.VerticalOffset > 0.5) || (delta < 0 && scroller.VerticalOffset < scroller.ScrollableHeight - 0.5))
                return; // the page overflows: it scrolls first
        }
        var now = DateTimeOffset.Now;
        if (now - _lastWheelTurn < TimeSpan.FromMilliseconds(300)) { _wheelAccumulator = 0; return; }
        _wheelAccumulator += point.Properties.MouseWheelDelta;
        if (Math.Abs(_wheelAccumulator) < 120) return;
        var forward = _wheelAccumulator < 0;
        _wheelAccumulator = 0;
        _lastWheelTurn = now;
        TurnPageByPage(forward);
    }

    private static ScrollViewer? PageScrollerUnder(object? source, DependencyObject stopAt)
    {
        var node = source as DependencyObject;
        while (node is not null && node != stopAt)
        {
            if (node is ScrollViewer scroller) return scroller;
            node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node);
        }
        return null;
    }

    private void OnPagePointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (e.Pointer.PointerDeviceType != PointerDeviceType.Pen || _pageHost is null) { _penDown = null; return; }
        _penDown = (e.GetCurrentPoint(_pageHost).Position.X, DateTimeOffset.Now);
    }

    /// <summary>A quick sideways pen stroke turns the page, like a finger's swipe.</summary>
    private void OnPagePointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_penDown is not { } down || e.Pointer.PointerDeviceType != PointerDeviceType.Pen || _pageHost is null || _pageFlip is null) return;
        _penDown = null;
        var dx = e.GetCurrentPoint(_pageHost).Position.X - down.X;
        if (Math.Abs(dx) < 60 || DateTimeOffset.Now - down.At > TimeSpan.FromMilliseconds(700)) return;
        var forward = dx < 0;
        var before = _pageFlip.SelectedIndex;
        // The FlipView may already have taken the stroke as a swipe: turn only if it didn't.
        var timer = _dispatcher.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(350);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            if (_pageFlip is not null && _pageFlip.SelectedIndex == before) TurnPageByPage(forward);
        };
        timer.Start();
    }
}
