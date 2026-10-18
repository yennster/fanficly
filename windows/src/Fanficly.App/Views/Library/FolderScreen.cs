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
/// One custom folder (FolderDetailView): its stories, sorted by the shared
/// sort menu atop the list and searchable (starting from the Library's search
/// text). Edit switches to multi-select, with "Remove (n)" taking the chosen
/// stories out of the folder. Download All saves every story not yet
/// downloaded, through <see cref="RestoreDownloadCenter"/>'s queue. Keys: Enter opens, Delete removes from the
/// folder, Ctrl+A selects all while selecting, Esc leaves selection, F2
/// renames the folder, Ctrl+F searches.
/// </summary>
public sealed class FolderScreen : Screen
{
    private string _folderName;
    private string _query;
    private bool _selecting;
    private readonly HashSet<int> _selected = [];
    private Grid _root = null!;
    private AutoSuggestBox _search = null!;
    private VirtualList<Work> _list = null!;
    private Grid _headerRow = null!;
    private TextBlock _countText = null!;
    private Grid _bottomBar = null!;
    private Button _removeSelected = null!;
    private ContentPresenter _emptyHost = null!;
    private DispatcherQueueTimer? _debounce;
    private bool _subscribed;
    private int _pendingFocusIndex = -1;
    private int _lastFocusedIndex = -1;

    public FolderScreen(string folderName, string initialSearchText = "")
    {
        _folderName = folderName;
        _query = initialSearchText;
        Title = folderName;
    }

    private static LibraryStore Store => AppHost.Library;

    private CustomFolder? Folder => Store.GetFolder(_folderName);

    private string Query => _query.Trim().ToLowerInvariant();

    protected override FrameworkElement Build()
    {
        _root = UI.UI.Grid("*", "Auto,Auto,*,Auto");
        RestoreBanner.Attach(_root).Row(0);

        _search = new AutoSuggestBox
        {
            PlaceholderText = "Search stories in folder",
            QueryIcon = new SymbolIcon(Symbol.Find),
            Text = _query,
            Margin = new Thickness(24, 4, 24, 8),
            MaxWidth = 912,
        };
        AutomationProperties.SetName(_search, "Search stories in folder");
        AutomationProperties.SetAutomationId(_search, "folder.search");
        _search.TextChanged += (_, _) =>
        {
            if (_search.Text == _query) return;
            _query = _search.Text;
            Rebuild(resetScroll: true);
        };
        _search.QuerySubmitted += (_, _) => LibraryActions.FocusFirst(_list.Element);
        _root.Children.Add(_search.Row(1));

        // "N stories" + the sort menu, atop the list (hidden while selecting).
        _countText = UI.UI.Secondary("");
        _countText.VerticalAlignment = VerticalAlignment.Center;
        _headerRow = UI.UI.Grid("*,Auto");
        _headerRow.Margin = new Thickness(12, 0, 4, 6);
        _headerRow.Children.Add(_countText.Col(0));
        _headerRow.Children.Add(LibrarySortMenu.Create("folder.sort").Col(1));

        _list = new VirtualList<Work>(BuildRow, spacing: 0, padding: new Thickness(24, 0, 24, 24), maxWidth: 960);
        AutomationProperties.SetName(_list.Element, "Stories in folder");
        AutomationProperties.SetAutomationId(_list.Element, "folder.list");
        _list.Header = _headerRow;
        _root.Children.Add(_list.Element.Row(2));

        _emptyHost = new ContentPresenter
        {
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
        };
        _root.Children.Add(_emptyHost.Row(2));

        // Edit mode's bottom bar: Select All and the destructive "Remove (n)".
        var selectAll = UI.UI.Button("Select All", SelectAll, "checkmark.square", UI.UI.ButtonKind.Subtle);
        AutomationProperties.SetAutomationId(selectAll, "folder.selectAll");
        ToolTipService.SetToolTip(selectAll, "Select All (Ctrl+A)");
        _removeSelected = UI.UI.Button("Remove (0)", RemoveSelected, "folder.badge.minus", UI.UI.ButtonKind.Destructive);
        _removeSelected.HorizontalAlignment = HorizontalAlignment.Stretch;
        _removeSelected.MinWidth = 200;
        _removeSelected.Padding = new Thickness(16, 10, 16, 10);
        AutomationProperties.SetAutomationId(_removeSelected, "folder.removeSelected");
        ToolTipService.SetToolTip(_removeSelected, "Remove the selected stories from this folder (Delete)");
        _bottomBar = UI.UI.Grid("Auto,*", columnSpacing: 12);
        _bottomBar.Padding = new Thickness(24, 10, 24, 14);
        _bottomBar.BorderBrush = Theme.Divider;
        _bottomBar.BorderThickness = new Thickness(0, 1, 0, 0);
        _bottomBar.Children.Add(selectAll.Col(0));
        _bottomBar.Children.Add(_removeSelected.Col(1));
        _bottomBar.Visibility = Visibility.Collapsed;
        _root.Children.Add(_bottomBar.Row(3));

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
        var folder = Folder;
        if (folder is null || (folder.Works.Count == 0 && !_selecting)) yield break;
        if (!_selecting)
        {
            // Download All (RM-010): every story here without an EPUB, one at a time.
            var count = DownloadCandidates(folder).Count;
            var downloadAll = UI.UI.ToolbarButton("arrow.down.circle", "Download All", () => _ = DownloadAllAsync(), showLabel: true);
            downloadAll.IsEnabled = count > 0 && RestoreDownloadCenter.Shared.Progress is null;
            AutomationProperties.SetAutomationId(downloadAll, "folder.downloadAll");
            AutomationProperties.SetHelpText(downloadAll, count == 0
                ? "Every story in this folder is already downloaded."
                : $"Saves {count} {(count == 1 ? "story" : "stories")} for offline reading, one at a time.");
            ToolTipService.SetToolTip(downloadAll, count == 0
                ? "Every story here is downloaded"
                : "Download every story in this folder for offline reading");
            yield return downloadAll;
        }
        var edit = UI.UI.ToolbarButton(_selecting ? "checkmark" : "checklist", _selecting ? "Done" : "Edit", ToggleSelecting, showLabel: true);
        AutomationProperties.SetAutomationId(edit, "folder.edit");
        ToolTipService.SetToolTip(edit, _selecting ? "Done selecting" : "Select stories to remove");
        yield return edit;
    }

    public override IEnumerable<ICommandBarElement> SecondaryCommands()
    {
        if (Folder is null) yield break;
        var rename = UI.UI.ToolbarButton("pencil", "Rename Folder...", () => _ = RenameAsync(), showLabel: true);
        rename.KeyboardAcceleratorTextOverride = "F2";
        AutomationProperties.SetAutomationId(rename, "folder.rename");
        yield return rename;
        var delete = UI.UI.ToolbarButton("trash", "Delete Folder", () => _ = DeleteFolderAsync(), showLabel: true);
        delete.Foreground = Theme.Danger;
        AutomationProperties.SetAutomationId(delete, "folder.delete");
        yield return delete;
    }

    /// <summary>The folder's stories without an EPUB, in on-screen order.</summary>
    private static IReadOnlyList<int> DownloadCandidates(CustomFolder folder) =>
        RestoreDownloadCenter.FolderDownloadCandidates(
            LibrarySortMenu.Current.Sorted(folder.Works.OrderByDescending(w => w.SavedAt)));

    private async Task DownloadAllAsync()
    {
        if (Folder is not { } folder) return;
        var ids = DownloadCandidates(folder);
        if (ids.Count == 0 || RestoreDownloadCenter.Shared.IsDownloading) return;
        var ok = await Dialogs.ConfirmAsync(
            $"Download {ids.Count} {(ids.Count == 1 ? "story" : "stories")} for offline reading?",
            "Stories download one at a time. You can cancel anytime, and the ones already downloaded stay.",
            "Download");
        if (!ok) return;
        _ = RestoreDownloadCenter.Shared.StartFolderDownload(AppHost.Client, Store, ids);
    }

    private void ToggleSelecting()
    {
        _selecting = !_selecting;
        _selected.Clear();
        Rebuild(resetScroll: false);
        MainWindow.Current?.Announce(_selecting ? "Selecting stories" : "Done selecting");
    }

    private async Task RenameAsync()
    {
        if (Folder is not { } folder) return;
        if (await LibraryActions.RenameFolderAsync(folder) is { } name)
        {
            _folderName = name;
            Title = name;
            Rebuild(resetScroll: false);
        }
    }

    private async Task DeleteFolderAsync()
    {
        if (Folder is not { } folder) return;
        if (await LibraryActions.DeleteFolderAsync(folder)) Navigator.Remove(this);
    }

    // MARK: - Lifecycle

    public override void OnAppearing()
    {
        Subscribe();
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
        RestoreDownloadCenter.Shared.PropertyChanged += OnDownloadsChanged;
    }

    private void Unsubscribe()
    {
        if (!_subscribed) return;
        _subscribed = false;
        Store.Changed -= OnStoreChanged;
        LibrarySortMenu.Changed -= ScheduleRebuild;
        LibraryActions.FilesChanged -= ScheduleRebuild;
        RestoreDownloadCenter.Shared.PropertyChanged -= OnDownloadsChanged;
    }

    /// <summary>Each finished download refreshes the rows' Downloaded badges
    /// and the Download All button.</summary>
    private void OnDownloadsChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(RestoreDownloadCenter.Progress)) return;
        var queue = MainWindow.Current?.DispatcherQueue;
        if (queue is null) return;
        if (queue.HasThreadAccess) ScheduleRebuild();
        else queue.TryEnqueue(ScheduleRebuild);
    }

    private void OnStoreChanged(LibraryEntityKinds kinds)
    {
        if ((kinds & (LibraryEntityKinds.Works | LibraryEntityKinds.Folders | LibraryEntityKinds.Chapters)) == 0) return;
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

    // MARK: - Content

    private void Rebuild(bool resetScroll)
    {
        if (_list is null) return;
        var folder = Folder;
        if (folder is null)
        {
            _list.Element.Visibility = Visibility.Collapsed;
            _search.Visibility = Visibility.Collapsed;
            _bottomBar.Visibility = Visibility.Collapsed;
            _emptyHost.Content = UI.UI.EmptyState("folder.badge.questionmark", "Folder Not Found",
                $"The folder '{_folderName}' could not be found.");
            _list.Reset([]);
            RefreshChromeIfNeeded();
            return;
        }
        _search.Visibility = Visibility.Visible;

        var query = Query;
        var all = folder.Works.ToList();
        var filtered = query.Length == 0 ? all : all.Where(w => w.Matches(query)).ToList();
        var sorted = LibrarySortMenu.Current.Sorted(filtered.OrderByDescending(w => w.SavedAt));
        _selected.IntersectWith(sorted.Select(w => w.Ao3Id));

        if (all.Count == 0)
        {
            _selecting = false;
            _list.Element.Visibility = Visibility.Collapsed;
            _emptyHost.Content = UI.UI.EmptyState("folder", "No Stories in This Folder",
                "Add stories from the Library: right-click a story and choose Folders….");
        }
        else
        {
            _emptyHost.Content = null;
            _list.Element.Visibility = Visibility.Visible;
        }

        _headerRow.Visibility = !_selecting && sorted.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _countText.Text = sorted.Count == 1 ? "1 story" : $"{sorted.Count} stories";
        _bottomBar.Visibility = _selecting ? Visibility.Visible : Visibility.Collapsed;
        UpdateRemoveButton();

        // Keep keyboard focus on the same row when the list rebuilds in place.
        if (resetScroll) _lastFocusedIndex = -1;
        else if (_pendingFocusIndex < 0 && _lastFocusedIndex >= 0 && LibraryActions.IsFocusWithin(_list.Element))
            _pendingFocusIndex = _lastFocusedIndex;
        if (_pendingFocusIndex >= 0) _pendingFocusIndex = Math.Min(_pendingFocusIndex, sorted.Count - 1);
        if (resetScroll)
        {
            _list.Reset(sorted);
        }
        else
        {
            _list.Items.Clear();
            _list.Items.AddRange(sorted);
            _list.Refresh();
        }
        _list.Footer = query.Length > 0 && filtered.Count == 0
            ? UI.UI.EmptyState("magnifyingglass", $"No Results for “{_query.Trim()}”", "Check the spelling or try a new search.")
                .Also(f => f.Margin = new Thickness(0, 24, 0, 0))
            : null;
        RefreshChromeIfNeeded();
    }

    private (bool Exists, bool HasWorks, bool Selecting, string Name, bool CanDownload, int ToDownload) _chromeState;

    /// <summary>Redraws the toolbar only when what it shows changed (rebuilding
    /// it on every refresh would take focus off its buttons).</summary>
    private void RefreshChromeIfNeeded()
    {
        var folder = Folder;
        // While a run goes the button is disabled, so the shrinking count
        // doesn't redraw the toolbar (and take focus) after every story.
        var downloading = RestoreDownloadCenter.Shared.Progress is not null;
        var toDownload = downloading || folder is null ? 0 : DownloadCandidates(folder).Count;
        var state = (folder is not null, folder is { Works.Count: > 0 }, _selecting, _folderName,
            !downloading && toDownload > 0, toDownload);
        if (state == _chromeState) return;
        _chromeState = state;
        InvalidateChrome();
    }

    private void UpdateRemoveButton()
    {
        _removeSelected.Content = UI.UI.Label("folder.badge.minus", $"Remove ({_selected.Count})", foreground: Theme.Danger, spacing: 6, maxLines: UI.UI.LineLimit(1));
        AutomationProperties.SetName(_removeSelected, $"Remove {_selected.Count} from folder");
        _removeSelected.IsEnabled = _selected.Count > 0;
    }

    private UIElement BuildRow(Work work, int index)
    {
        var downloaded = WorkPersistence.EpubPath(work.Ao3Id) is not null;
        var (content, name) = LibraryRow.Build(work, downloaded);
        Control row;
        if (_selecting)
        {
            // Edit mode: each row is a check box (Narrator reads its state).
            var box = new CheckBox
            {
                Content = content,
                IsChecked = _selected.Contains(work.Ao3Id),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(8, 6, 8, 6),
                Margin = new Thickness(8, 0, 8, 0),
            };
            AutomationProperties.SetName(box, name);
            AutomationProperties.SetAutomationId(box, $"folder.select.{work.Ao3Id}");
            box.Click += (_, _) =>
            {
                if (box.IsChecked == true) _selected.Add(work.Ao3Id);
                else _selected.Remove(work.Ao3Id);
                UpdateRemoveButton();
            };
            LibraryActions.HandleRowKeys(box, onDelete: () =>
            {
                if (_selected.Count == 0) _selected.Add(work.Ao3Id);
                _pendingFocusIndex = index;
                RemoveSelected();
            });
            row = box;
        }
        else
        {
            var button = new Button
            {
                Content = content,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Background = Theme.Transparent,
                BorderBrush = Theme.Transparent,
                Padding = new Thickness(12, 6, 12, 6),
                CornerRadius = new CornerRadius(6),
            };
            AutomationProperties.SetName(button, name);
            AutomationProperties.SetAutomationId(button, $"folder.work.{work.Ao3Id}");
            ToolTipService.SetToolTip(button, $"Read {work.Title}");
            button.Click += (_, _) => Routes.OpenSavedWork(work.Ao3Id);
            if (Folder is { } folder)
            {
                button.ContextFlyout = LibraryActions.WorkMenu(work, folder);
                LibraryActions.HandleRowKeys(button, onDelete: () =>
                {
                    _pendingFocusIndex = index;
                    LibraryActions.RemoveFromFolder([work], folder);
                });
            }
            row = button;
        }
        row.GotFocus += (_, _) => _lastFocusedIndex = index;
        if (_pendingFocusIndex == index)
        {
            row.Loaded += (_, _) =>
            {
                if (_pendingFocusIndex != index) return;
                _pendingFocusIndex = -1;
                row.Focus(FocusState.Keyboard);
            };
        }
        return UI.UI.VStack(0, row, UI.UI.Divider());
    }

    private void SelectAll()
    {
        if (!_selecting) return;
        foreach (var w in _list.Items) _selected.Add(w.Ao3Id);
        _list.Refresh();
        UpdateRemoveButton();
        MainWindow.Current?.Announce($"Selected {_selected.Count} stories");
    }

    private void RemoveSelected()
    {
        if (Folder is not { } folder || _selected.Count == 0) return;
        var works = folder.Works.Where(w => _selected.Contains(w.Ao3Id)).ToList();
        _selected.Clear();
        _selecting = false;
        LibraryActions.RemoveFromFolder(works, folder);
        Rebuild(resetScroll: false);
    }

    // MARK: - Keyboard

    public override bool HandleKey(VirtualKey key, VirtualKeyModifiers modifiers)
    {
        if (key == VirtualKey.A && modifiers == VirtualKeyModifiers.Control && _selecting)
        {
            SelectAll();
            return true;
        }
        if (key == VirtualKey.F && modifiers == VirtualKeyModifiers.Control)
        {
            _search.Focus(FocusState.Keyboard);
            return true;
        }
        if (key == VirtualKey.F2 && modifiers == VirtualKeyModifiers.None)
        {
            _ = RenameAsync();
            return true;
        }
        return false;
    }

    /// <summary>Esc / Back leaves selection first.</summary>
    public override bool HandleBack()
    {
        if (!_selecting) return false;
        ToggleSelecting();
        return true;
    }
}
