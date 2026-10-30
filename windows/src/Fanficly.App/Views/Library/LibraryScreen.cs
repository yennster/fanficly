using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.System;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;

namespace Fanficly.App.Views.Library;

/// <summary>
/// The Library tab (LibraryView): every saved story, filtered by All /
/// Starred / Downloaded / Folders, searchable by title, author or tag, sorted
/// by the sort menu that rides first in the filter row (pinned stories stay
/// on top). A reading-stats strip atop the list opens the Stats tab. The
/// Folders filter lists custom folders (New Folder…, rename, delete). Rows
/// open the story; their context menus hold every Swift swipe and
/// context-menu action. Keys: Enter opens, Delete removes, F2 renames a
/// folder, Ctrl+F searches, Ctrl+Shift+N makes a folder.
/// </summary>
public sealed class LibraryScreen : Screen
{
    internal enum LibraryFilter { All, Starred, Downloaded, Folders }

    private static readonly (LibraryFilter Filter, string Title, string Compact, string Symbol, string Id)[] FilterInfo =
    [
        (LibraryFilter.All, "All", "All", "books.vertical", "library.filter.all"),
        (LibraryFilter.Starred, "Starred", "Starred", "star", "library.filter.starred"),
        (LibraryFilter.Downloaded, "Downloaded", "Offline", "arrow.down.circle", "library.filter.downloaded"),
        (LibraryFilter.Folders, "Folders", "Folders", "folder", "library.filter.folders"),
    ];

    private LibraryFilter _filter = LibraryFilter.All;
    private string _query = "";
    private Grid _root = null!;
    private AutoSuggestBox _search = null!;
    private VirtualList<object> _list = null!;
    private Border _statsHost = null!;
    private SelectorBar _filterBar = null!;
    private readonly List<SelectorBarItem> _filterItems = [];
    private Button _newFolder = null!;
    private ContentPresenter _emptyHost = null!;
    private DispatcherQueueTimer? _debounce;
    private bool _subscribed;
    private bool _suppressFilterEvent;
    private int _pendingFocusIndex = -1;
    private int _lastFocusedIndex = -1;

    private static LibraryStore Store => AppHost.Library;

    private string Query => _query.Trim().ToLowerInvariant();

    protected override FrameworkElement Build()
    {
        Title = "Library";
        _root = UI.UI.Grid("*", "Auto,Auto,*");

        RestoreBanner.Attach(_root).Row(0);

        _search = new AutoSuggestBox
        {
            PlaceholderText = "Search titles, authors, tags, or notes",
            QueryIcon = new SymbolIcon(Symbol.Find),
            Margin = new Thickness(24, 4, 24, 8),
            MaxWidth = 912,
        };
        AutomationProperties.SetName(_search, "Search titles, authors, tags, or notes");
        AutomationProperties.SetAutomationId(_search, "library.search");
        _search.TextChanged += (_, _) =>
        {
            if (_search.Text == _query) return;
            _query = _search.Text;
            Rebuild(resetScroll: true);
        };
        _search.QuerySubmitted += (_, _) => LibraryActions.FocusFirst(_list.Element);
        _root.Children.Add(_search.Row(1));

        // The filter row: sort first (sorting rides here, not in the toolbar;
        // in Folders it orders the stories inside each folder), then the filters.
        var sort = LibrarySortMenu.Create();
        _filterBar = new SelectorBar();
        AutomationProperties.SetName(_filterBar, "Filter");
        AutomationProperties.SetAutomationId(_filterBar, "library.filter");
        foreach (var info in FilterInfo)
        {
            var item = new SelectorBarItem
            {
                Text = info.Title,
                // Decorative beside the title, which is the item's name.
                Icon = Symbols.Icon(info.Symbol).A11yHidden(),
            };
            AutomationProperties.SetName(item, info.Title);
            AutomationProperties.SetAutomationId(item, info.Id);
            _filterItems.Add(item);
            _filterBar.Items.Add(item);
        }
        _filterBar.SelectedItem = _filterItems[(int)_filter];
        _filterBar.SelectionChanged += (_, _) =>
        {
            if (_suppressFilterEvent || _filterBar.SelectedItem is not SelectorBarItem selected) return;
            var index = _filterItems.IndexOf(selected);
            if (index < 0 || (LibraryFilter)index == _filter) return;
            _filter = (LibraryFilter)index;
            Rebuild(resetScroll: true);
        };
        var filterRow = UI.UI.Grid("Auto,*", columnSpacing: 10);
        filterRow.Children.Add(sort.Col(0));
        filterRow.Children.Add(new ScrollViewer
        {
            Content = _filterBar,
            HorizontalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        }.Col(1));

        _statsHost = new Border();
        _newFolder = UI.UI.Button("New Folder...", () => _ = NewFolderAsync(), "folder.badge.plus", UI.UI.ButtonKind.Subtle);
        _newFolder.Foreground = Theme.Accent;
        _newFolder.HorizontalAlignment = HorizontalAlignment.Left;
        AutomationProperties.SetName(_newFolder, "New Folder");
        AutomationProperties.SetAutomationId(_newFolder, "library.newFolder");
        ToolTipService.SetToolTip(_newFolder, "New Folder (Ctrl+Shift+N)");

        _list = new VirtualList<object>(BuildRow, spacing: 0, padding: new Thickness(24, 0, 24, 24), maxWidth: 960);
        AutomationProperties.SetName(_list.Element, "Saved stories");
        AutomationProperties.SetAutomationId(_list.Element, "library.list");
        _list.Header = UI.UI.VStack(10, _statsHost, filterRow, _newFolder).Also(s => s.Margin = new Thickness(0, 0, 0, 6));
        _root.Children.Add(_list.Element.Row(2));

        _emptyHost = new ContentPresenter
        {
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
        };
        _root.Children.Add(_emptyHost.Row(2));

        // Narrow windows use the compact filter titles ("Offline").
        _root.SizeChanged += (_, e) =>
        {
            var compact = e.NewSize.Width < 560;
            // Phone-width windows drop the icons so all four filters fit.
            var tight = e.NewSize.Width < 440;
            for (var i = 0; i < FilterInfo.Length; i++)
            {
                _filterItems[i].Text = compact ? FilterInfo[i].Compact : FilterInfo[i].Title;
                if (_filterItems[i].Icon is { } icon) icon.Visibility = tight ? Visibility.Collapsed : Visibility.Visible;
            }
        };

        _debounce = MainWindow.Current.DispatcherQueue.CreateTimer();
        _debounce.Interval = TimeSpan.FromMilliseconds(150);
        _debounce.IsRepeating = false;
        _debounce.Tick += (_, _) => Rebuild(resetScroll: false);

        Rebuild(resetScroll: true);
        return _root;
    }

    // MARK: - Toolbar

    public override IEnumerable<ICommandBarElement> PrimaryCommands()
    {
        var import = UI.UI.ToolbarButton("square.and.arrow.down", "Import EPUB", () => _ = EpubImporter.PickAndImportAsync(), showLabel: true);
        import.IsEnabled = !EpubImporter.IsImporting;
        AutomationProperties.SetAutomationId(import, "library.importEpub");
        ToolTipService.SetToolTip(import, "Import EPUB files, like AO3 downloads, to read offline");
        yield return import;
    }

    private void OnImportingChanged() => InvalidateChrome();

    // MARK: - Lifecycle

    public override void OnAppearing()
    {
        Subscribe();
        // The sort, downloads or the reading position may have changed while away.
        if (IsBuilt) Rebuild(resetScroll: false);
    }

    public override void OnDisappearing() => Unsubscribe();

    public override void OnRemoved() => Unsubscribe();

    private void Subscribe()
    {
        if (_subscribed) return;
        _subscribed = true;
        Store.Changed += OnStoreChanged;
        LibrarySortMenu.Changed += ScheduleRebuild;
        LibraryActions.FilesChanged += ScheduleRebuild;
        EpubImporter.IsImportingChanged += OnImportingChanged;
    }

    private void Unsubscribe()
    {
        if (!_subscribed) return;
        _subscribed = false;
        Store.Changed -= OnStoreChanged;
        LibrarySortMenu.Changed -= ScheduleRebuild;
        LibraryActions.FilesChanged -= ScheduleRebuild;
        EpubImporter.IsImportingChanged -= OnImportingChanged;
    }

    private void OnStoreChanged(LibraryEntityKinds kinds)
    {
        const LibraryEntityKinds relevant = LibraryEntityKinds.Works | LibraryEntityKinds.Folders |
                                            LibraryEntityKinds.ReadingStats | LibraryEntityKinds.Chapters;
        if ((kinds & relevant) == 0) return;
        // The poller saves from the background; rows are rebuilt on the UI thread.
        var queue = MainWindow.Current?.DispatcherQueue;
        if (queue is null) return;
        if (queue.HasThreadAccess) ScheduleRebuild();
        else queue.TryEnqueue(ScheduleRebuild);
    }

    private void ScheduleRebuild()
    {
        if (_debounce is null) return;
        _debounce.Stop();
        _debounce.Start();
    }

    /// <summary>Shows the Folders filter (a folder deep link lands on top of it).</summary>
    internal void ShowFoldersFilter()
    {
        _filter = LibraryFilter.Folders;
        if (!IsBuilt) return;
        SelectFilterItem();
        Rebuild(resetScroll: true);
    }

    private void SelectFilterItem()
    {
        _suppressFilterEvent = true;
        _filterBar.SelectedItem = _filterItems[(int)_filter];
        _suppressFilterEvent = false;
    }

    // MARK: - Content

    private void Rebuild(bool resetScroll)
    {
        if (_list is null) return;
        var works = Store.Works;
        if (works.Count == 0)
        {
            _list.Element.Visibility = Visibility.Collapsed;
            _emptyHost.Content = UI.UI.EmptyState("books.vertical", "Nothing saved yet",
                "Click the bookmark to follow a story, or 'Save offline' to download it for reading without a connection. No AO3 account needed. Already have EPUB files, like AO3 downloads? Import them to read here.",
                "Import EPUB...", () => _ = EpubImporter.PickAndImportAsync());
            _list.Reset([]);
            return;
        }
        _emptyHost.Content = null;
        _list.Element.Visibility = Visibility.Visible;

        // Stats strip, when there's anything to show.
        var stats = Store.All<ReadingStat>();
        _statsHost.Child = stats.Count == 0
            ? null
            : LibraryStatsStrip.Build(ReadingStatsAggregator.Summarize(stats.Select(s => s.Snapshot), null),
                                      StreakStore.LoadStreakInfo().CurrentStreak);
        _statsHost.Visibility = stats.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        _newFolder.Visibility = _filter == LibraryFilter.Folders ? Visibility.Visible : Visibility.Collapsed;

        var query = Query;
        List<object> items;
        FrameworkElement? footer = null;
        if (_filter == LibraryFilter.Folders)
        {
            var folders = Store.Folders()
                .Where(f => query.Length == 0 || f.Name.ToLowerInvariant().Contains(query, StringComparison.Ordinal) || f.Works.Any(w => w.Matches(query)))
                .ToList();
            items = folders.Cast<object>().ToList();
            if (folders.Count == 0)
                footer = query.Length > 0
                    ? NoResults()
                    : UI.UI.EmptyState("folder", "No Folders",
                        "Make a folder to group stories — click New Folder, or choose Folders… on a story.");
        }
        else
        {
            IEnumerable<Work> baseList = _filter switch
            {
                LibraryFilter.Starred => works.Where(w => w.IsStarred),
                LibraryFilter.Downloaded => works.Where(w => WorkPersistence.EpubPath(w.Ao3Id) is not null),
                _ => works,
            };
            if (query.Length > 0) baseList = baseList.Where(w => w.Matches(query));
            var sorted = LibrarySortMenu.Current.Sorted(baseList.OrderByDescending(w => w.SavedAt));
            items = sorted.Cast<object>().ToList();
            if (sorted.Count == 0)
            {
                footer = query.Length > 0 ? NoResults() : _filter switch
                {
                    LibraryFilter.Starred => UI.UI.EmptyState("star", "No Starred Stories",
                        "Star a story from its menu (right-click it) to keep your favorites here."),
                    LibraryFilter.Downloaded => UI.UI.EmptyState("arrow.down.circle", "No Downloaded Stories",
                        "Download a story for offline reading and it shows up here."),
                    _ => null,
                };
            }
        }

        // Keep keyboard focus on the same row when the list rebuilds in place.
        if (resetScroll) _lastFocusedIndex = -1;
        else if (_pendingFocusIndex < 0 && _lastFocusedIndex >= 0 && LibraryActions.IsFocusWithin(_list.Element))
            _pendingFocusIndex = _lastFocusedIndex;
        if (_pendingFocusIndex >= 0) _pendingFocusIndex = Math.Min(_pendingFocusIndex, items.Count - 1);
        if (resetScroll)
        {
            _list.Reset(items);
        }
        else
        {
            _list.Items.Clear();
            _list.Items.AddRange(items);
            _list.Refresh();
        }
        _list.Footer = footer?.Also(f => f.Margin = new Thickness(0, 24, 0, 0));
    }

    /// <summary>ContentUnavailableView.search(text:).</summary>
    private FrameworkElement NoResults() =>
        UI.UI.EmptyState("magnifyingglass", $"No Results for “{_query.Trim()}”", "Check the spelling or try a new search.");

    private UIElement BuildRow(object item, int index)
    {
        FrameworkElement row = item switch
        {
            Work work => WorkRowButton(work, index),
            CustomFolder folder => FolderRowButton(folder, index),
            _ => new Grid(),
        };
        row.GotFocus += (_, _) => _lastFocusedIndex = index;
        if (row is Control c && _pendingFocusIndex == index)
        {
            c.Loaded += (_, _) =>
            {
                if (_pendingFocusIndex != index) return;
                _pendingFocusIndex = -1;
                c.Focus(FocusState.Keyboard);
            };
        }
        return UI.UI.VStack(0, row, UI.UI.Divider());
    }

    private Button WorkRowButton(Work work, int index)
    {
        var downloaded = WorkPersistence.EpubPath(work.Ao3Id) is not null;
        var (content, name) = LibraryRow.Build(work, downloaded);
        var button = RowButton(content);
        AutomationProperties.SetName(button, name);
        AutomationProperties.SetAutomationId(button, $"library.work.{work.Ao3Id}");
        ToolTipService.SetToolTip(button, $"Read {work.Title}");
        button.ContextFlyout = LibraryActions.WorkMenu(work, folder: null);
        button.Click += (_, _) => Routes.OpenSavedWork(work.Ao3Id);
        LibraryActions.HandleRowKeys(button, onDelete: () =>
        {
            _pendingFocusIndex = index;
            LibraryActions.Delete(work);
        });
        return button;
    }

    private Button FolderRowButton(CustomFolder folder, int index)
    {
        var query = Query;
        var total = folder.Works.Count;
        var matching = query.Length == 0 ? total : folder.Works.Count(w => w.Matches(query));
        var countText = query.Length == 0 ? Plural.Stories(total) : $"{matching} of {Plural.Stories(total)}";

        var grid = UI.UI.Grid("Auto,*,Auto,Auto", columnSpacing: 10);
        grid.Padding = new Thickness(0, 6, 0, 6);
        grid.Children.Add(UI.UI.Icon("folder", 16, Theme.Accent).Also(i => i.VerticalAlignment = VerticalAlignment.Center).Col(0));
        grid.Children.Add(UI.UI.Text(folder.Name, Theme.Style.Headline, maxLines: UI.UI.LineLimit(1)).Also(t => t.VerticalAlignment = VerticalAlignment.Center).Col(1));
        grid.Children.Add(UI.UI.Secondary(countText).Also(t => { t.VerticalAlignment = VerticalAlignment.Center; t.TextWrapping = TextWrapping.NoWrap; }).Col(2));
        grid.Children.Add(UI.UI.Icon("chevron.right", 11, Theme.TextTertiary).Also(i => i.VerticalAlignment = VerticalAlignment.Center).Col(3));

        var button = RowButton(grid);
        AutomationProperties.SetName(button, $"{folder.Name}, folder, {countText}");
        AutomationProperties.SetAutomationId(button, $"library.folder.{folder.Name}");
        ToolTipService.SetToolTip(button, $"Open {folder.Name}");
        void Open() => Navigator.Push(new FolderScreen(folder.Name, _query));
        button.Click += (_, _) => Open();
        button.ContextFlyout = LibraryActions.FolderMenu(folder, Open);
        LibraryActions.HandleRowKeys(button,
            onDelete: () => _ = DeleteFolderAsync(folder, index),
            onRename: () => _ = LibraryActions.RenameFolderAsync(folder));
        return button;
    }

    private static Button RowButton(UIElement content) => new()
    {
        Content = content,
        HorizontalAlignment = HorizontalAlignment.Stretch,
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
        Background = Theme.Transparent,
        BorderBrush = Theme.Transparent,
        Padding = new Thickness(12, 6, 12, 6),
        CornerRadius = new CornerRadius(6),
    };

    private async Task DeleteFolderAsync(CustomFolder folder, int index)
    {
        if (await LibraryActions.DeleteFolderAsync(folder)) _pendingFocusIndex = index;
    }

    private async Task NewFolderAsync()
    {
        var folder = await LibraryActions.CreateFolderAsync();
        if (folder is not null && _filter != LibraryFilter.Folders)
        {
            _filter = LibraryFilter.Folders;
            SelectFilterItem();
            Rebuild(resetScroll: true);
        }
    }

    // MARK: - Keyboard

    public override bool HandleKey(VirtualKey key, VirtualKeyModifiers modifiers)
    {
        if (key == VirtualKey.F && modifiers == VirtualKeyModifiers.Control)
        {
            _search.Focus(FocusState.Keyboard);
            return true;
        }
        if (key == VirtualKey.N && modifiers == (VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift))
        {
            _ = NewFolderAsync();
            return true;
        }
        return false;
    }
}
