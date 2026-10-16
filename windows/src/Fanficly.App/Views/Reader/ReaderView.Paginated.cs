using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Foundation;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// "Swipe by chapter" (paginatedBody): one chapter per page of a FlipView, each
/// scrolling vertically on its own. Swipe (or the arrow keys, or the flip
/// buttons) for the next chapter. Only the chapters either side of the one on
/// screen are built.
/// </summary>
internal sealed partial class ReaderView
{
    private sealed class ChapterPageView
    {
        public required int Chapter { get; init; }
        public required ScrollViewer Scroll { get; init; }
        public required StackPanel Panel { get; init; }
        public required List<FrameworkElement> Paragraphs { get; init; }
    }

    private RegionGrid? _chapRoot;
    private FlipView? _chapFlip;
    private PipsPager? _pips;
    private readonly List<Grid> _chapSlots = [];
    private readonly Dictionary<int, ChapterPageView> _chapViews = [];
    private bool _suppressChapFlip;
    private int _chapGeneration;
    private double _chapWidth;

    private FrameworkElement BuildPaginated()
    {
        var generation = ++_chapGeneration;
        _isRestoring = true;
        if (LoadAnchorIfNeeded() is { } anchor)
        {
            _selectedChapter = anchor.Chapter;
            if (anchor.Paragraph > 0) _pendingParagraphRestore = anchor;
        }
        _visibleChapter = _selectedChapter;

        var root = new RegionGrid { Background = _brushes.Background };
        _chapRoot = root;
        _chapFlip = new FlipView
        {
            Background = _brushes.Background,
            UseTouchAnimationsForAllNavigation = ReaderPrefs.PageTurnAnimations && AnimationsEnabled,
            IsTabStop = false,
        };
        AutomationProperties.SetName(_chapFlip, "Chapters");
        _chapSlots.Clear();
        _chapViews.Clear();
        foreach (var _ in _chapters)
        {
            var slot = new Grid { Background = _brushes.Background };
            _chapSlots.Add(slot);
            _chapFlip.Items.Add(slot);
        }
        _suppressChapFlip = true;
        _chapFlip.SelectedIndex = Math.Max(0, Array.IndexOf(_chapterOrder, _selectedChapter));
        _suppressChapFlip = false;
        _chapFlip.SelectionChanged += OnChapterFlipChanged;
        root.Children.Add(_chapFlip);

        _pips = new PipsPager
        {
            NumberOfPages = _chapters.Count,
            MaxVisiblePips = 7,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 10),
            SelectedPageIndex = Math.Max(0, Array.IndexOf(_chapterOrder, _selectedChapter)),
        };
        AutomationProperties.SetName(_pips, "Chapter");
        _pips.SelectedIndexChanged += (pager, _) =>
        {
            var index = pager.SelectedPageIndex;
            if (index >= 0 && index < _chapterOrder.Length && _chapterOrder[index] != _selectedChapter)
                SelectChapter(_chapterOrder[index]);
        };
        root.Children.Add(_pips);

        root.SizeChanged += OnPaginatedSizeChanged;
        root.Tapped += OnPaginatedTapped;
        FillNearbyChapters();
        ReportCurrentChapter();

        // Warm the paragraph conversions for the other chapters in the background.
        var images = ReaderPrefs.ShowImages;
        var order = _chapterOrder;
        _ = Task.Run(() => { foreach (var index in order) Paragraphs(index, images); });
        _ = FinishPaginatedRestoreAsync(generation);
        return root;
    }

    private async Task FinishPaginatedRestoreAsync(int generation)
    {
        await Task.Delay(200);
        if (generation != _chapGeneration || _pendingParagraphRestore is not null) return;
        _isRestoring = false;
    }

    private void TeardownPaginated()
    {
        _chapGeneration++;
        if (_chapFlip is not null) _chapFlip.SelectionChanged -= OnChapterFlipChanged;
        if (_chapRoot is not null)
        {
            _chapRoot.SizeChanged -= OnPaginatedSizeChanged;
            _chapRoot.Tapped -= OnPaginatedTapped;
        }
        _chapRoot = null;
        _chapFlip = null;
        _pips = null;
        _chapSlots.Clear();
        _chapViews.Clear();
        _pendingParagraphRestore = null;
    }

    private void UpdatePaginatedPips()
    {
        if (_pips is null) return;
        _pips.Visibility = _chapters.Count > 1 && !_isUIMinimized ? Visibility.Visible : Visibility.Collapsed;
        var index = Array.IndexOf(_chapterOrder, _selectedChapter);
        if (index >= 0 && _pips.SelectedPageIndex != index) _pips.SelectedPageIndex = index;
    }

    /// <summary>Builds the chapter on screen and its neighbours; frees the rest.</summary>
    private void FillNearbyChapters()
    {
        if (_chapFlip is null) return;
        var nearby = new HashSet<int> { _selectedChapter };
        if (ChapterTracking.AdjacentChapter(_chapterOrder, _selectedChapter, forward: false) is { } previous) nearby.Add(previous);
        if (ChapterTracking.AdjacentChapter(_chapterOrder, _selectedChapter, forward: true) is { } next) nearby.Add(next);
        for (var i = 0; i < _chapters.Count; i++)
        {
            var index = _chapters[i].Index;
            var slot = _chapSlots[i];
            if (nearby.Contains(index))
            {
                if (!_chapViews.ContainsKey(index))
                {
                    var view = BuildChapterPage(_chapters[i]);
                    _chapViews[index] = view;
                    slot.Children.Clear();
                    slot.Children.Add(view.Scroll);
                }
            }
            else if (_chapViews.Remove(index))
            {
                slot.Children.Clear();
            }
        }
    }

    private ChapterPageView BuildChapterPage(AO3ChapterPayload chapter)
    {
        var style = TextStyle();
        var panel = new StackPanel
        {
            Spacing = 16,
            HorizontalAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(0, 16, 0, _chapters.Count > 1 ? 56 : 16),
        };
        if (chapter.Index == _chapterOrder[0]) panel.Children.Add(TitleHeader());
        if (_chapters.Count > 1) panel.Children.Add(ChapterHeaderView(chapter));
        var paragraphs = new List<FrameworkElement>();
        var column = ReaderText.Column(Paragraphs(chapter.Index), style, _brushes.Foreground, paragraphs);
        column.Padding = new Thickness(0, 8, 0, 8);
        panel.Children.Add(column);
        if (_chapRoot is { ActualWidth: > 0 } root) panel.Width = ColumnWidth(root.ActualWidth, ReaderPrefs.WidthPercent);

        var scroll = new ScrollViewer
        {
            Content = panel,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            ZoomMode = ZoomMode.Disabled,
            IsTabStop = false,
        };
        var view = new ChapterPageView { Chapter = chapter.Index, Scroll = scroll, Panel = panel, Paragraphs = paragraphs };
        scroll.ViewChanged += (_, _) => SamplePaginated(view);
        scroll.PointerWheelChanged += OnFlowingWheel;
        scroll.Loaded += (_, _) =>
        {
            ApplyPaginatedHighlight();
            if (view.Chapter == _selectedChapter) _ = RestorePaginatedParagraphAsync(view);
        };
        return view;
    }

    private void OnChapterFlipChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressChapFlip || _chapFlip is null) return;
        var index = _chapFlip.SelectedIndex;
        if (index < 0 || index >= _chapterOrder.Length) return;
        var chapter = _chapterOrder[index];
        if (chapter == _selectedChapter) return;
        _selectedChapter = chapter;
        OnPaginatedChapterSelected(chapter, fromFlip: true);
        ReportCurrentChapter();
        UpdatePaginatedPips();
    }

    /// <summary>A new chapter is on screen (swiped to, or picked): Swift's
    /// <c>onChange(of: selectedChapterIndex)</c>.</summary>
    private void OnPaginatedChapterSelected(int chapter, bool fromFlip)
    {
        if (_chapFlip is null) return;
        if (!fromFlip)
        {
            var index = Array.IndexOf(_chapterOrder, chapter);
            _chapFlip.UseTouchAnimationsForAllNavigation = ReaderPrefs.PageTurnAnimations && AnimationsEnabled;
            _suppressChapFlip = true;
            _chapFlip.SelectedIndex = index;
            _suppressChapFlip = false;
        }
        _visibleChapter = chapter;
        if (!_isRestoring && _pendingParagraphRestore is null)
            SetCurrentAnchor(new ReadingAnchor(chapter, 0), force: true);
        FillNearbyChapters();
        if (_chapViews.TryGetValue(chapter, out var view) && view.Scroll.IsLoaded) _ = RestorePaginatedParagraphAsync(view);
        UpdatePaginatedPips();
    }

    /// <summary>"Swipe by chapter"'s one-shot paragraph restore.</summary>
    private async Task RestorePaginatedParagraphAsync(ChapterPageView view)
    {
        if (view.Chapter != _selectedChapter || _pendingParagraphRestore is not { } pending
            || pending.Chapter != view.Chapter || pending.Paragraph <= 0) return;
        _pendingParagraphRestore = null; // consume: one shot
        _isRestoring = true;
        var generation = _chapGeneration;
        try
        {
            for (var i = 0; i < 10; i++)
            {
                await Task.Delay(180);
                if (generation != _chapGeneration) return;
                ScrollPageToParagraph(view, pending.Paragraph, 0, animated: false);
            }
        }
        finally
        {
            if (generation == _chapGeneration) _isRestoring = false;
        }
    }

    private static void ScrollPageToParagraph(ChapterPageView view, int paragraph, double ratio, bool animated)
    {
        if (paragraph < 0 || paragraph >= view.Paragraphs.Count) return;
        var element = view.Paragraphs[paragraph];
        double top;
        try { top = element.TransformToVisual(view.Panel).TransformPoint(default(Point)).Y; }
        catch { return; }
        var target = top - ratio * view.Scroll.ViewportHeight;
        view.Scroll.ChangeView(null, Math.Clamp(target, 0, view.Scroll.ScrollableHeight), null, !animated);
    }

    // MARK: - Resize

    private void OnPaginatedSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var width = e.NewSize.Width;
        foreach (var view in _chapViews.Values) view.Panel.Width = ColumnWidth(width, ReaderPrefs.WidthPercent);
        var previous = _chapWidth;
        _chapWidth = width;
        if (previous <= 0 || Math.Abs(previous - width) <= 1) return;
        _sampler.BeginResize(width);
        if (_currentAnchor is not { } anchor || !_chapViews.TryGetValue(_selectedChapter, out var current)) return;
        _isRestoring = true;
        _ = ReanchorPaginatedAsync(current, anchor, _chapGeneration);
    }

    private async Task ReanchorPaginatedAsync(ChapterPageView view, ReadingAnchor anchor, int generation)
    {
        try
        {
            if (IsWorkStart(anchor) || anchor.Chapter != view.Chapter) return;
            foreach (var delay in new[] { 120, 280 })
            {
                await Task.Delay(delay);
                if (generation != _chapGeneration) return;
                ScrollPageToParagraph(view, anchor.Paragraph, 0, animated: false);
            }
        }
        finally
        {
            if (generation == _chapGeneration) _isRestoring = false;
        }
    }

    // MARK: - Position sampling

    private void SamplePaginated(ChapterPageView view)
    {
        if (view.Chapter != _selectedChapter || _chapRoot is null) return;
        var offsets = new Dictionary<string, double>();
        var count = view.Paragraphs.Count;
        for (var p = 0; p < count; p++)
        {
            if (!ChapterAnchors.IsAnchorIndex(p, count)) continue;
            double top;
            try { top = view.Paragraphs[p].TransformToVisual(view.Scroll).TransformPoint(default(Point)).Y; }
            catch { continue; }
            offsets[ChapterTracking.Key(view.Chapter, p)] = top + AnchorShift;
        }
        var viewport = view.Scroll.ViewportHeight;
        var chapter = view.Chapter;
        var result = _sampler.OnOffsets(offsets, _chapRoot.ActualWidth, _isRestoring, DateTimeOffset.Now,
                                        o => EndOfContent(o, viewport + AnchorShift));
        // The end of the work on screen saves at once; other samples keep the
        // usual throttle.
        ApplySample(result, anchor => SetCurrentAnchor(new ReadingAnchor(chapter, anchor.Paragraph)));
    }

    // MARK: - Narration follow + highlight

    private void ScrollPaginatedToSpokenParagraph()
    {
        if (!_speech.IsActive || _listeningChapter is not { } chapter || !_chapViews.TryGetValue(chapter, out var view)) return;
        ScrollPageToParagraph(view, _speech.CurrentParagraph, 0.32, AnimationsEnabled);
    }

    private void ApplyPaginatedHighlight()
    {
        foreach (var view in _chapViews.Values)
        {
            var highlighted = HighlightedParagraph(view.Chapter);
            for (var p = 0; p < view.Paragraphs.Count; p++)
                ReaderText.SetHighlight(view.Paragraphs[p], p == highlighted ? _brushes.Highlight : null);
        }
    }

    // MARK: - Keyboard

    /// <summary>Page Up / Down and Space: a screenful of the chapter, then on into
    /// the next (or previous) chapter at its end.</summary>
    private bool ScrollPaginatedPage(bool forward)
    {
        if (!_chapViews.TryGetValue(_selectedChapter, out var view)) return false;
        var scroll = view.Scroll;
        var atEdge = forward ? scroll.VerticalOffset >= scroll.ScrollableHeight - 1 : scroll.VerticalOffset <= 1;
        if (atEdge)
        {
            TurnChapter(forward);
            return true;
        }
        var step = Math.Max(48, scroll.ViewportHeight * 0.9);
        scroll.ChangeView(null, Math.Clamp(scroll.VerticalOffset + (forward ? step : -step), 0, scroll.ScrollableHeight), null, !AnimationsEnabled);
        return true;
    }

    private bool ScrollPaginatedBy(double delta)
    {
        if (!_chapViews.TryGetValue(_selectedChapter, out var view)) return false;
        var scroll = view.Scroll;
        scroll.ChangeView(null, Math.Clamp(scroll.VerticalOffset + delta, 0, scroll.ScrollableHeight), null, true);
        return true;
    }

    private void ScrollPaginatedToEdge(bool end)
    {
        if (!_chapViews.TryGetValue(_selectedChapter, out var view)) return;
        view.Scroll.ChangeView(null, end ? view.Scroll.ScrollableHeight : 0, null, !AnimationsEnabled);
    }

    private void OnPaginatedTapped(object sender, TappedRoutedEventArgs e)
    {
        if (IsInsideControl(e.OriginalSource, (DependencyObject)sender)) return;
        SetMinimized(!_isUIMinimized);
    }
}
