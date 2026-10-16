using System.Collections.ObjectModel;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Foundation;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// Continuous scroll (continuousBody): the title header and every chapter in one
/// scrolling column. Paragraphs are virtualized — an ItemsRepeater realizes only
/// those near the viewport — and the realized anchor paragraphs (every
/// <see cref="ChapterAnchors.AnchorStride"/>-th, plus each chapter's last) report
/// their offsets to <see cref="ReaderAnchorSampler"/>, which tracks the position.
/// </summary>
internal sealed partial class ReaderView
{
    private enum EntryKind { Title, ChapterHeader, Paragraph }

    private readonly record struct ContEntry(EntryKind Kind, int Chapter, int Paragraph, int Count);

    /// <summary>The line (from the viewport's top edge) a paragraph must have
    /// reached to count as the one you're reading. Restoring puts the paragraph's
    /// top exactly on the edge, so it's read back as the same anchor.</summary>
    private const double AnchorLine = 12;

    /// <summary>Offsets are reported shifted so Core's default threshold
    /// (<see cref="ChapterTracking.DefaultThreshold"/>) lands on <see cref="AnchorLine"/>.</summary>
    private const double AnchorShift = ChapterTracking.DefaultThreshold - AnchorLine;

    private RegionGrid? _contRoot;
    private ScrollViewer? _contScroll;
    private ItemsRepeater? _contRepeater;
    private StackPanel? _contPanel;
    private List<ContEntry> _entries = [];
    private readonly Dictionary<int, int> _chapterFirstEntry = [];
    private readonly Dictionary<(int Chapter, int Paragraph), int> _paragraphEntry = [];
    private readonly Dictionary<UIElement, int> _realized = [];
    private ReaderTextStyle? _contStyle;
    private int _contGeneration;
    private double _contWidth;
    private DispatcherQueueTimer? _trailingTimer;
    private int _trailingToken;

    private FrameworkElement BuildContinuous()
    {
        var generation = ++_contGeneration;
        _contStyle = TextStyle();
        _realized.Clear();
        _contWidth = 0;

        var root = new RegionGrid { Background = _brushes.Background };
        _contRoot = root;
        root.Children.Add(UI.UI.Loading().Also(l => l.Opacity = 0.6));
        root.Tapped += OnContinuousTapped;
        root.SizeChanged += OnContinuousSizeChanged;

        // Converting a long work's chapters takes a moment: off the UI thread.
        var images = ReaderPrefs.ShowImages;
        var chapters = _chapterOrder;
        _ = Task.Run(() =>
        {
            foreach (var index in chapters) Paragraphs(index, images);
        }).ContinueWith(_ => _dispatcher.TryEnqueue(() =>
        {
            if (generation != _contGeneration || _removed || _builtMode != ReadingMode.Continuous) return;
            PopulateContinuous(root, generation);
        }), TaskScheduler.Default);
        return root;
    }

    private void PopulateContinuous(RegionGrid root, int generation)
    {
        _entries = [new ContEntry(EntryKind.Title, 0, 0, 0)];
        _chapterFirstEntry.Clear();
        _paragraphEntry.Clear();
        foreach (var chapter in _chapters)
        {
            _chapterFirstEntry[chapter.Index] = _entries.Count;
            if (_chapters.Count > 1) _entries.Add(new ContEntry(EntryKind.ChapterHeader, chapter.Index, 0, 0));
            var count = Paragraphs(chapter.Index).Count;
            for (var p = 0; p < count; p++)
            {
                _paragraphEntry[(chapter.Index, p)] = _entries.Count;
                _entries.Add(new ContEntry(EntryKind.Paragraph, chapter.Index, p, count));
            }
        }

        _contRepeater = new ItemsRepeater
        {
            Layout = new StackLayout { Orientation = Orientation.Vertical, Spacing = 0 },
            ItemsSource = new ObservableCollection<object>(Enumerable.Range(0, _entries.Count).Select(i => (object)i)),
            ItemTemplate = new DelegateElementFactory(data => data is int i ? BuildEntry(i) : new Grid()),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        _contRepeater.ElementPrepared += (_, args) => _realized[args.Element] = args.Index;
        _contRepeater.ElementClearing += (_, args) => _realized.Remove(args.Element);

        _contPanel = new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(0, 16, 0, 16),
            Children = { _contRepeater },
        };
        _contScroll = new ScrollViewer
        {
            Content = _contPanel,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            ZoomMode = ZoomMode.Disabled,
            IsTabStop = false,
        };
        _contScroll.ViewChanged += (_, _) => SampleContinuous();
        _contScroll.PointerWheelChanged += OnFlowingWheel;
        root.Children.Clear();
        root.Children.Add(_contScroll);
        ApplyContinuousWidth(root.ActualWidth);
        _ = RestoreContinuousAsync(generation);
    }

    private void TeardownContinuous()
    {
        _contGeneration++;
        _trailingTimer?.Stop();
        if (_contRoot is not null)
        {
            _contRoot.Tapped -= OnContinuousTapped;
            _contRoot.SizeChanged -= OnContinuousSizeChanged;
        }
        _contRoot = null;
        _contScroll = null;
        _contRepeater = null;
        _contPanel = null;
        _realized.Clear();
        _entries = [];
    }

    private UIElement BuildEntry(int index)
    {
        if (index >= _entries.Count || _contStyle is null) return new Grid();
        var entry = _entries[index];
        switch (entry.Kind)
        {
            case EntryKind.Title:
                return TitleHeader().Also(e => e.Margin = new Thickness(0, 0, 0, 16));
            case EntryKind.ChapterHeader:
                // The chapter VStack's 8 pt spacing plus the chapter block's 8 pt top padding.
                return ChapterAt(entry.Chapter) is { } chapter
                    ? ChapterHeaderView(chapter).Also(e => e.Margin = new Thickness(0, 0, 0, 16))
                    : new Grid();
            default:
            {
                var paragraphs = Paragraphs(entry.Chapter);
                if (entry.Paragraph >= paragraphs.Count) return new Grid();
                var block = ReaderText.Block(paragraphs[entry.Paragraph], _contStyle, _brushes.Foreground);
                var last = entry.Paragraph == entry.Count - 1;
                var isLastChapter = entry.Chapter == _chapterOrder[^1];
                var top = entry.Paragraph == 0 && _chapters.Count == 1 ? 8 : 0;
                // Paragraph spacing inside a chapter; after its last paragraph the
                // block's 8 pt bottom padding and the 16 pt gap before the next chapter.
                var bottom = last ? (isLastChapter ? 8 : 24) : _contStyle.Typography.ParagraphSpacing;
                block.Margin = new Thickness(0, top, 0, bottom);
                if (HighlightedParagraph(entry.Chapter) == entry.Paragraph) ReaderText.SetHighlight(block, _brushes.Highlight);
                return block;
            }
        }
    }

    private void ApplyContinuousWidth(double containerWidth)
    {
        if (_contPanel is null || containerWidth <= 0) return;
        _contPanel.Width = ColumnWidth(containerWidth, ReaderPrefs.WidthPercent);
    }

    // MARK: - Resize (re-anchor)

    private void OnContinuousSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var width = e.NewSize.Width;
        ApplyContinuousWidth(width);
        var previous = _contWidth;
        _contWidth = width;
        if (previous <= 0 || Math.Abs(previous - width) <= 1) return;
        // A resize (snap layout, the sidebar, full screen) reflows the text: put
        // the paragraph you were on back on top. Samples at the new width resume
        // afterwards; reflow samples in between are ignored.
        _sampler.BeginResize(width);
        if (_currentAnchor is not { } anchor) return;
        _isRestoring = true;
        _ = ReanchorContinuousAsync(anchor, _contGeneration);
    }

    private async Task ReanchorContinuousAsync(ReadingAnchor anchor, int generation)
    {
        try
        {
            if (IsWorkStart(anchor)) return;
            foreach (var delay in new[] { 120, 280 })
            {
                await Task.Delay(delay);
                if (generation != _contGeneration) return;
                ScrollToParagraph(anchor, 0, animated: false);
            }
        }
        finally
        {
            if (generation == _contGeneration) _isRestoring = false;
        }
    }

    private bool IsWorkStart(ReadingAnchor anchor) =>
        _chapters.Count == 0 || (anchor.Chapter == _chapterOrder[0] && anchor.Paragraph == 0);

    // MARK: - Restore

    private async Task RestoreContinuousAsync(int generation)
    {
        var anchor = LoadAnchorIfNeeded();
        _visibleChapter = anchor?.Chapter ?? _visibleChapter;
        ReportCurrentChapter();
        if (anchor is not { } target || IsWorkStart(target)) return;
        _isRestoring = true;
        try
        {
            await Task.Delay(250);
            if (generation != _contGeneration) return;
            ScrollToEntry(_chapterFirstEntry.GetValueOrDefault(target.Chapter), 0, animated: false);
            // Paragraph heights below are estimates until realized: keep landing
            // on the paragraph until the layout around it has settled.
            for (var i = 0; i < 10; i++)
            {
                await Task.Delay(180);
                if (generation != _contGeneration) return;
                ScrollToParagraph(target, 0, animated: false);
            }
        }
        finally
        {
            if (generation == _contGeneration) _isRestoring = false;
        }
    }

    private void ScrollToParagraph(ReadingAnchor anchor, double ratio, bool animated)
    {
        if (_paragraphEntry.TryGetValue((anchor.Chapter, anchor.Paragraph), out var index))
            ScrollToEntry(index, ratio, animated);
        else if (_chapterFirstEntry.TryGetValue(anchor.Chapter, out var chapterEntry))
            ScrollToEntry(chapterEntry, ratio, animated);
    }

    private void ScrollToEntry(int index, double ratio, bool animated)
    {
        if (_contRepeater is null || index < 0 || index >= _entries.Count) return;
        try
        {
            var element = _contRepeater.GetOrCreateElement(index);
            element.UpdateLayout();
            element.StartBringIntoView(new BringIntoViewOptions
            {
                VerticalAlignmentRatio = ratio,
                HorizontalAlignmentRatio = double.NaN,
                AnimationDesired = animated,
            });
        }
        catch (Exception e)
        {
            AppHost.Log($"Reader scroll failed: {e.Message}");
        }
    }

    /// <summary>Jumps to a chapter's header (twice: the second lands once the
    /// paragraphs around it have been measured).</summary>
    private async Task ScrollToChapterAsync(int index)
    {
        if (_builtMode != ReadingMode.Continuous || !_chapterFirstEntry.TryGetValue(index, out var entry)) return;
        var generation = _contGeneration;
        ScrollToEntry(entry, 0, animated: false);
        await Task.Delay(60);
        if (generation != _contGeneration) return;
        ScrollToEntry(entry, 0, animated: false);
    }

    private async Task ScrollContinuousToChapterEdgeAsync(int chapter, bool end)
    {
        if (!end) { await ScrollToChapterAsync(chapter); return; }
        var count = Paragraphs(chapter).Count;
        if (count == 0) return;
        var generation = _contGeneration;
        var anchor = new ReadingAnchor(chapter, count - 1);
        ScrollToParagraph(anchor, 1, animated: false);
        await Task.Delay(60);
        if (generation != _contGeneration) return;
        ScrollToParagraph(anchor, 1, animated: false);
    }

    // MARK: - Position sampling

    private void SampleContinuous()
    {
        if (_contScroll is null || _contRepeater is null || _contRoot is null) return;
        var offsets = new Dictionary<string, double>();
        var chapterTops = new Dictionary<int, double>();
        foreach (var (element, index) in _realized)
        {
            if (index >= _entries.Count) continue;
            var entry = _entries[index];
            double top;
            try { top = element.TransformToVisual(_contScroll).TransformPoint(default(Point)).Y; }
            catch { continue; }
            var chapterKey = entry.Kind == EntryKind.Title ? 0 : entry.Chapter;
            if (!chapterTops.TryGetValue(chapterKey, out var existing) || top < existing) chapterTops[chapterKey] = top;
            if (entry.Kind == EntryKind.Paragraph && ChapterAnchors.IsAnchorIndex(entry.Paragraph, entry.Count))
                offsets[ChapterTracking.Key(entry.Chapter, entry.Paragraph)] = top + AnchorShift;
        }

        if (ChapterTracking.CurrentChapter(chapterTops, AnchorLine + 1) is { } current && current != _visibleChapter && !_isRestoring)
        {
            _visibleChapter = current;
            ReportCurrentChapter();
        }

        var viewport = _contScroll.ViewportHeight;
        var result = _sampler.OnOffsets(offsets, _contRoot.ActualWidth, _isRestoring, DateTimeOffset.Now,
                                        o => EndOfContent(o, viewport + AnchorShift));
        ApplySample(result, anchor => SetCurrentAnchor(anchor));
    }

    /// <summary>Acts on what the sampler said: take the anchor now, or once
    /// scrolling has come to rest (the trailing sample).</summary>
    private void ApplySample(AnchorSampleResult result, Action<ReadingAnchor> apply)
    {
        switch (result.Action)
        {
            case AnchorSampleAction.Apply when result.Anchor is { } anchor:
                apply(anchor);
                break;
            case AnchorSampleAction.ScheduleTrailing:
                _trailingToken = result.TrailingToken;
                _trailingTimer ??= CreateTrailingTimer();
                _trailingApply = apply;
                _trailingTimer.Stop();
                _trailingTimer.Start();
                break;
        }
    }

    private Action<ReadingAnchor>? _trailingApply;

    private DispatcherQueueTimer CreateTrailingTimer()
    {
        var timer = _dispatcher.CreateTimer();
        timer.Interval = ReaderAnchorSampler.TrailingDelay;
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            if (_removed) return;
            if (_sampler.FireTrailing(_trailingToken, _isRestoring, DateTimeOffset.Now) is { } anchor)
                _trailingApply?.Invoke(anchor);
        };
        return timer;
    }

    // MARK: - Narration follow + highlight

    /// <summary>Keeps the paragraph being read aloud in the upper third of the view.</summary>
    private void ScrollToSpokenParagraph()
    {
        if (!_speech.IsActive || _listeningChapter is not { } chapter || _builtMode != ReadingMode.Continuous) return;
        ScrollToParagraph(new ReadingAnchor(chapter, _speech.CurrentParagraph), 0.32, animated: AnimationsEnabled);
    }

    private void ApplyContinuousHighlight()
    {
        foreach (var (element, index) in _realized)
        {
            if (index >= _entries.Count || element is not FrameworkElement block) continue;
            var entry = _entries[index];
            if (entry.Kind != EntryKind.Paragraph) continue;
            ReaderText.SetHighlight(block, HighlightedParagraph(entry.Chapter) == entry.Paragraph ? _brushes.Highlight : null);
        }
    }

    // MARK: - Keyboard scrolling

    private bool ScrollContinuousPage(bool forward)
    {
        if (_contScroll is null) return false;
        var step = Math.Max(48, _contScroll.ViewportHeight * 0.9);
        _contScroll.ChangeView(null, Math.Clamp(_contScroll.VerticalOffset + (forward ? step : -step), 0, _contScroll.ScrollableHeight), null, !AnimationsEnabled);
        return true;
    }

    private bool ScrollContinuousBy(double delta)
    {
        if (_contScroll is null) return false;
        _contScroll.ChangeView(null, Math.Clamp(_contScroll.VerticalOffset + delta, 0, _contScroll.ScrollableHeight), null, true);
        return true;
    }

    // MARK: - Input

    /// <summary>A tap anywhere on the story shows or hides the controls.</summary>
    private void OnContinuousTapped(object sender, TappedRoutedEventArgs e)
    {
        if (IsInsideControl(e.OriginalSource, (DependencyObject)sender)) return;
        SetMinimized(!_isUIMinimized);
    }

    /// <summary>Ctrl + wheel (and a precision touchpad's pinch) would zoom: the
    /// reader never zooms, so it's swallowed. Everything else scrolls.</summary>
    private void OnFlowingWheel(object sender, PointerRoutedEventArgs e)
    {
        if (e.KeyModifiers.HasFlag(Windows.System.VirtualKeyModifiers.Control)) e.Handled = true;
    }
}
