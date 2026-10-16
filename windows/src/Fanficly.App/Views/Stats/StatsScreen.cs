using System.Globalization;
using System.Runtime.InteropServices.WindowsRuntime;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.App.Views.Library;
using Fanficly.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;

namespace Fanficly.App.Views.Stats;

/// <summary>
/// The Stats tab (StatsView): reading totals (stories finished, time read,
/// words read, day streak) and top fandoms / categories / ships / authors for
/// a chosen period — Week / Month / Year / All Time (the default) — with ‹ ›
/// to page through periods. Share renders the wrap-up card to a PNG and offers
/// Share, Save As and Copy. Works for everyone, on-device; reading time is the
/// real active time the reader was open.
/// </summary>
public sealed class StatsScreen : Screen
{
    private StatsPeriod _period = StatsPeriod.AllTime;
    /// <summary>A date inside the period shown; ‹ › moves it by one unit.</summary>
    private DateTimeOffset _anchor = DateTimeOffset.Now;
    private List<ReadingStatSnapshot> _snapshots = [];
    private ReadingStatsSummary _summary = ReadingStatsSummary.Empty;

    private Grid _root = null!;
    private Canvas _renderHost = null!;
    private ScrollViewer _scroll = null!;
    private SelectorBar _periodBar = null!;
    private readonly List<SelectorBarItem> _periodItems = [];
    private Grid _pager = null!;
    private Button _prev = null!;
    private Button _next = null!;
    private TextBlock _pagerTitle = null!;
    private StackPanel _body = null!;
    private ContentPresenter _emptyHost = null!;
    private DispatcherQueueTimer? _debounce;
    private bool _subscribed;
    private bool _rendering;

    private static LibraryStore Store => AppHost.Library;

    private DateSpan? Interval => _period.Interval(_anchor);
    private string ScopeTitle => _period.ScopeTitle(_anchor);

    protected override FrameworkElement Build()
    {
        Title = "Stats";
        _root = new Grid();

        // The wrap-up card is rendered off-screen: it has to be in the visual
        // tree, so it goes in this invisible host behind the content.
        _renderHost = new Canvas { Opacity = 0, IsHitTestVisible = false };
        AutomationProperties.SetAccessibilityView(_renderHost, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        _root.Children.Add(_renderHost);

        // Period picker + pager.
        _periodBar = new SelectorBar();
        AutomationProperties.SetName(_periodBar, "Period");
        AutomationProperties.SetAutomationId(_periodBar, "stats.period");
        foreach (var period in StatsPeriodExtensions.All)
        {
            var item = new SelectorBarItem { Text = period.Title() };
            AutomationProperties.SetAutomationId(item, $"stats.period.{period.RawValue()}");
            _periodItems.Add(item);
            _periodBar.Items.Add(item);
        }
        _periodBar.SelectedItem = _periodItems[(int)_period];
        _periodBar.HorizontalAlignment = HorizontalAlignment.Center;
        _periodBar.SelectionChanged += (_, _) =>
        {
            if (_periodBar.SelectedItem is not SelectorBarItem selected) return;
            var period = (StatsPeriod)_periodItems.IndexOf(selected);
            if (period == _period) return;
            _period = period;
            // Reset to the current period when switching granularity.
            _anchor = DateTimeOffset.Now;
            Rebuild();
        };

        _prev = UI.UI.IconButton("chevron.left", "Previous", () => Page(-1));
        _prev.Width = 44;
        AutomationProperties.SetAutomationId(_prev, "stats.prev");
        _next = UI.UI.IconButton("chevron.right", "Next", () => Page(1));
        _next.Width = 44;
        AutomationProperties.SetAutomationId(_next, "stats.next");
        _pagerTitle = UI.UI.Text("", Theme.Style.Subheadline, wrap: false);
        _pagerTitle.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        _pagerTitle.HorizontalAlignment = HorizontalAlignment.Center;
        _pagerTitle.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetLiveSetting(_pagerTitle, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        _pager = UI.UI.Grid("Auto,*,Auto", columnSpacing: 8);
        _pager.Children.Add(_prev.Col(0));
        _pager.Children.Add(_pagerTitle.Col(1));
        _pager.Children.Add(_next.Col(2));

        _body = UI.UI.VStack(24);
        var content = UI.UI.VStack(24, UI.UI.VStack(12, _periodBar, _pager), _body);
        _scroll = UI.UI.Scroll(content, maxWidth: 900);
        AutomationProperties.SetAutomationId(_scroll, "stats.content");
        _root.Children.Add(_scroll);

        _emptyHost = new ContentPresenter
        {
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
        };
        _root.Children.Add(_emptyHost);

        _debounce = MainWindow.Current.DispatcherQueue.CreateTimer();
        _debounce.Interval = TimeSpan.FromMilliseconds(200);
        _debounce.IsRepeating = false;
        _debounce.Tick += (_, _) => Rebuild();

        Rebuild();
        return _root;
    }

    // MARK: - Toolbar

    public override IEnumerable<ICommandBarElement> PrimaryCommands()
    {
        if (_snapshots.Count == 0) yield break;
        var share = new AppBarButton
        {
            Icon = Symbols.Icon("square.and.arrow.up"),
            Label = "Share",
            LabelPosition = CommandBarLabelPosition.Default,
        };
        ToolTipService.SetToolTip(share, "Share your reading wrap-up");
        AutomationProperties.SetName(share, "Share");
        AutomationProperties.SetHelpText(share, "Share your reading wrap-up as an image");
        AutomationProperties.SetAutomationId(share, "stats.share");
        var menu = new MenuFlyout();
        menu.Items.Add(UI.UI.MenuItem("Share...", () => Later(ShareWrapAsync), "square.and.arrow.up").Also(i => AutomationProperties.SetAutomationId(i, "stats.share.share")));
        menu.Items.Add(UI.UI.MenuItem("Save Image As...", () => Later(SaveWrapAsync), "square.and.arrow.down").Also(i => AutomationProperties.SetAutomationId(i, "stats.share.save")));
        menu.Items.Add(UI.UI.MenuItem("Copy Image", () => Later(CopyWrapAsync), "doc.on.doc").Also(i => AutomationProperties.SetAutomationId(i, "stats.share.copy")));
        share.Flyout = menu;
        yield return share;
    }

    /// <summary>Runs after the menu has closed (never present from menu content).</summary>
    private static void Later(Func<Task> action) => MainWindow.Current.DispatcherQueue.TryEnqueue(() => _ = action());

    // MARK: - Lifecycle

    public override void OnAppearing()
    {
        if (!_subscribed)
        {
            _subscribed = true;
            Store.Changed += OnStoreChanged;
        }
        // New reading time (or a new streak day) may have come in while away.
        if (IsBuilt) Rebuild();
    }

    public override void OnDisappearing() => Unsubscribe();

    public override void OnRemoved() => Unsubscribe();

    private void Unsubscribe()
    {
        if (!_subscribed) return;
        _subscribed = false;
        Store.Changed -= OnStoreChanged;
    }

    private void OnStoreChanged(LibraryEntityKinds kinds)
    {
        if ((kinds & LibraryEntityKinds.ReadingStats) == 0) return;
        var queue = MainWindow.Current?.DispatcherQueue;
        if (queue is null || _debounce is null) return;
        if (queue.HasThreadAccess) { _debounce.Stop(); _debounce.Start(); }
        else queue.TryEnqueue(() => { _debounce.Stop(); _debounce.Start(); });
    }

    // MARK: - Content

    private void Page(int direction)
    {
        if (_period.Unit() is null) return;
        if (direction < 0 && !CanPageBackward()) return;
        if (direction > 0 && !CanPageForward()) return;
        _anchor = _period.Step(_anchor, direction);
        Rebuild();
    }

    /// <summary>Forward paging stops at the period containing today.</summary>
    private bool CanPageForward() => Interval is { } interval && interval.End <= DateTimeOffset.Now;

    /// <summary>Backward paging stops when there's no reading before this period.</summary>
    private bool CanPageBackward() =>
        Interval is { } interval &&
        ReadingStatsAggregator.DataDateRange(_snapshots) is { } range &&
        range.Lower < interval.Start;

    private void Rebuild()
    {
        if (_body is null) return;
        var hadStats = _snapshots.Count > 0;
        _snapshots = Store.All<ReadingStat>().Select(s => s.Snapshot).ToList();
        if (hadStats != _snapshots.Count > 0) InvalidateChrome();

        if (_snapshots.Count == 0)
        {
            _scroll.Visibility = Visibility.Collapsed;
            _emptyHost.Content = UI.UI.EmptyState("chart.bar.xaxis", "No Reading Stats Yet",
                "Open a story in the reader and your reading time, top fandoms, and yearly wrap-up will show up here.");
            _summary = ReadingStatsSummary.Empty;
            return;
        }
        _emptyHost.Content = null;
        _scroll.Visibility = Visibility.Visible;

        _summary = ReadingStatsAggregator.Summarize(_snapshots, Interval);
        var scope = ScopeTitle;

        // Pager.
        var paged = _period != StatsPeriod.AllTime;
        _pager.Visibility = paged ? Visibility.Visible : Visibility.Collapsed;
        _pagerTitle.Text = scope;
        _prev.IsEnabled = CanPageBackward();
        _next.IsEnabled = CanPageForward();
        var unit = _period.Title().ToLower(CultureInfo.CurrentCulture);
        AutomationProperties.SetName(_prev, $"Previous {unit}");
        AutomationProperties.SetName(_next, $"Next {unit}");
        ToolTipService.SetToolTip(_prev, $"Previous {unit}");
        ToolTipService.SetToolTip(_next, $"Next {unit}");

        _body.Children.Clear();
        _body.Children.Add(HeaderCards(scope, _summary));
        AddTopList("Top Fandoms", "books.vertical", _summary.TopFandoms);
        AddTopList("Top Categories", "person.2.square.stack", _summary.TopCategories);
        AddTopList("Top Ships", "heart", _summary.TopRelationships);
        AddTopList("Top Authors", "person", _summary.TopAuthors);
    }

    private static FrameworkElement HeaderCards(string scope, ReadingStatsSummary summary)
    {
        var heading = UI.UI.Text(scope, Theme.Style.Title2).A11yHeading();
        heading.FontWeight = Microsoft.UI.Text.FontWeights.Bold;
        AutomationProperties.SetAutomationId(heading, "stats.scope");
        // An adaptive grid so the four tiles wrap nicely at any width.
        var tiles = new AdaptiveGrid { MinItemWidth = 150, Spacing = 12 };
        tiles.Children.Add(StatTile(summary.StoriesRead.ToString(CultureInfo.CurrentCulture),
            summary.StoriesRead == 1 ? "Story Finished" : "Stories Finished", "checkmark.circle"));
        tiles.Children.Add(StatTile(StatsFormat.FormatDuration(summary.TotalSeconds), "Time Read", "clock"));
        tiles.Children.Add(StatTile(StatsFormat.FormatWords(summary.TotalWords), "Words Read", "text.alignleft"));
        tiles.Children.Add(StatTile(StreakStore.LoadStreakInfo().CurrentStreak.ToString(CultureInfo.CurrentCulture), "Day Streak", "flame"));
        return UI.UI.VStack(8, heading, tiles);
    }

    private static FrameworkElement StatTile(string value, string label, string symbol)
    {
        var valueText = UI.UI.Text(value, Theme.Style.Title, wrap: false);
        valueText.FontWeight = Microsoft.UI.Text.FontWeights.Bold;
        var stack = UI.UI.VStack(4,
            UI.UI.Icon(symbol, 18, Theme.Accent).Also(i => i.HorizontalAlignment = HorizontalAlignment.Left),
            new Viewbox { Child = valueText, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, HorizontalAlignment = HorizontalAlignment.Left, Height = 34 },
            UI.UI.Caption(label));
        var card = new Border
        {
            Child = stack,
            Padding = new Thickness(16),
            CornerRadius = new CornerRadius(8),
            Background = Theme.CardBackground,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
        };
        return new AccessibleGroup($"{label}: {value}", card);
    }

    private void AddTopList(string title, string symbol, IReadOnlyList<ReadingTagCount> items)
    {
        if (items.Count == 0) return;
        var maxCount = Math.Max(1, items.Max(i => i.Count));
        var stack = UI.UI.VStack(10, UI.UI.Label(symbol, title, Theme.Style.Headline, Theme.TextPrimary).A11yHeading());
        foreach (var item in items) stack.Children.Add(BarRow(item, (double)item.Count / maxCount));
        _body.Children.Add(stack);
    }

    private static FrameworkElement BarRow(ReadingTagCount item, double fraction)
    {
        var top = UI.UI.Grid("*,Auto", columnSpacing: 8);
        top.Children.Add(UI.UI.Text(item.Name, Theme.Style.Subheadline, wrap: false).Col(0));
        top.Children.Add(UI.UI.Secondary(item.Count.ToString(CultureInfo.CurrentCulture)).Col(1));
        var bar = new ProgressBar { Minimum = 0, Maximum = 1, Value = Math.Max(0.02, fraction), MinHeight = 6, CornerRadius = new CornerRadius(3) };
        return new AccessibleGroup($"{item.Name}, {item.Count} {(item.Count == 1 ? "story" : "stories")}", UI.UI.VStack(4, top, bar));
    }

    // MARK: - Share

    private string WrapFileName => ShareService.SafeFileName($"Fanficly – My Reading – {ScopeTitle}");

    /// <summary>Renders the wrap-up card (at 2× or the screen's scale, whichever
    /// is larger) to PNG bytes.</summary>
    private async Task<byte[]?> RenderWrapAsync()
    {
        if (_rendering || _snapshots.Count == 0) return null;
        _rendering = true;
        var card = WrapShareCard.Build(ScopeTitle, _summary);
        _renderHost.Children.Add(card);
        try
        {
            card.UpdateLayout();
            var scale = Math.Max(_root.XamlRoot?.RasterizationScale ?? 1, 2);
            var bitmap = new RenderTargetBitmap();
            await bitmap.RenderAsync(card, (int)Math.Round(WrapShareCard.Width * scale), (int)Math.Round(WrapShareCard.Height * scale));
            var pixels = await bitmap.GetPixelsAsync();
            using var stream = new InMemoryRandomAccessStream();
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96 * scale, 96 * scale, pixels.ToArray());
            await encoder.FlushAsync();
            var bytes = new byte[stream.Size];
            using var reader = new DataReader(stream.GetInputStreamAt(0));
            await reader.LoadAsync((uint)stream.Size);
            reader.ReadBytes(bytes);
            return bytes;
        }
        catch (Exception e)
        {
            AppHost.Log($"Rendering the wrap-up failed: {e}");
            MainWindow.Current?.ShowMessage("Couldn't make the image", e.Message, InfoBarSeverity.Error);
            return null;
        }
        finally
        {
            _renderHost.Children.Remove(card);
            _rendering = false;
        }
    }

    private async Task ShareWrapAsync()
    {
        if (await RenderWrapAsync() is not { } png) return;
        await ShareService.ShareImageAsync(png, WrapFileName, $"My Reading — {ScopeTitle}");
    }

    private async Task SaveWrapAsync()
    {
        if (await RenderWrapAsync() is not { } png) return;
        try
        {
            var picker = new FileSavePicker
            {
                SuggestedStartLocation = PickerLocationId.PicturesLibrary,
                SuggestedFileName = WrapFileName,
                DefaultFileExtension = ".png",
            };
            picker.FileTypeChoices.Add("PNG image", new List<string> { ".png" });
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Current));
            var file = await picker.PickSaveFileAsync();
            if (file is null) return;
            await FileIO.WriteBytesAsync(file, png);
            MainWindow.Current?.ShowMessage("Image saved", file.Name);
        }
        catch (Exception e)
        {
            AppHost.Log($"Saving the wrap-up failed: {e.Message}");
            MainWindow.Current?.ShowMessage("Couldn't save the image", e.Message, InfoBarSeverity.Error);
        }
    }

    private async Task CopyWrapAsync()
    {
        if (await RenderWrapAsync() is not { } png) return;
        try
        {
            var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(png.AsBuffer());
            stream.Seek(0);
            var package = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
            package.SetBitmap(RandomAccessStreamReference.CreateFromStream(stream));
            Clipboard.SetContent(package);
            Clipboard.Flush();
            MainWindow.Current?.ShowMessage("Image copied", "Paste it anywhere.");
        }
        catch (Exception e)
        {
            AppHost.Log($"Copying the wrap-up failed: {e.Message}");
            MainWindow.Current?.ShowMessage("Couldn't copy the image", e.Message, InfoBarSeverity.Error);
        }
    }
}

/// <summary>A wrapping grid of equal-width cells at least <see cref="MinItemWidth"/>
/// wide (SwiftUI's <c>GridItem(.adaptive(minimum:))</c>).</summary>
public sealed partial class AdaptiveGrid : Panel
{
    public double MinItemWidth { get; set; } = 150;
    public double Spacing { get; set; } = 12;

    private int Columns(double width)
    {
        if (double.IsInfinity(width) || width <= 0) return Math.Max(1, Children.Count);
        return Math.Clamp((int)((width + Spacing) / (MinItemWidth + Spacing)), 1, Math.Max(1, Children.Count));
    }

    private double CellWidth(double width, int columns) =>
        double.IsInfinity(width) ? MinItemWidth : Math.Max(0, (width - Spacing * (columns - 1)) / columns);

    protected override Size MeasureOverride(Size availableSize)
    {
        var columns = Columns(availableSize.Width);
        var cell = CellWidth(availableSize.Width, columns);
        double total = 0, rowHeight = 0;
        for (var i = 0; i < Children.Count; i++)
        {
            Children[i].Measure(new Size(cell, double.PositiveInfinity));
            rowHeight = Math.Max(rowHeight, Children[i].DesiredSize.Height);
            if (i % columns == columns - 1 || i == Children.Count - 1)
            {
                total += rowHeight + (total > 0 ? Spacing : 0);
                rowHeight = 0;
            }
        }
        var width = double.IsInfinity(availableSize.Width) ? columns * cell + (columns - 1) * Spacing : availableSize.Width;
        return new Size(width, total);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var columns = Columns(finalSize.Width);
        var cell = CellWidth(finalSize.Width, columns);
        double y = 0;
        for (var start = 0; start < Children.Count; start += columns)
        {
            double rowHeight = 0;
            for (var i = start; i < Math.Min(start + columns, Children.Count); i++)
                rowHeight = Math.Max(rowHeight, Children[i].DesiredSize.Height);
            for (var i = start; i < Math.Min(start + columns, Children.Count); i++)
                Children[i].Arrange(new Rect((i - start) * (cell + Spacing), y, cell, rowHeight));
            y += rowHeight + Spacing;
        }
        return finalSize;
    }
}
