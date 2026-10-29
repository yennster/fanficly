using System.Globalization;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.App.Views.Account;
using Fanficly.App.Views.Shared;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Fanficly.App.Views.Search;

/// <summary>
/// Search AO3 (SearchView). What you type is a keyword search run by AO3's own
/// ranking; suggestions turn the words you're typing into exact tag or filter
/// chips when chosen; the Filters sheet covers everything else. Words are never
/// silently reinterpreted — see <see cref="SearchSyntax"/> for the few phrases
/// that are.
/// </summary>
public sealed class SearchScreen : Screen
{
    private IAO3Client Client => AppHost.Client;
    private static LibraryStore Store => AppHost.Library;

    // MARK: - State (the Swift view's @State)

    /// <summary>The keywords in the search box.</summary>
    private string _text = "";
    /// <summary>Everything else, shown as chips: chosen suggestions, the Filters
    /// sheet, and <c>key:value</c> tokens typed into the box (moved here when the
    /// search runs). Also carries the sort.</summary>
    private AO3SearchFilters _active = new();
    /// <summary>The filters the current results came from (for loading more pages).</summary>
    private AO3SearchFilters? _searched;
    private List<AO3WorkSummary> _results = [];
    private int? _totalFound;
    private int _currentPage = 1;
    private int _totalPages = 1;
    private bool _isSearching;
    private bool _hasSearched;
    private bool _isLoadingMore;
    private string? _errorMessage;
    /// <summary>A failed next page: shown under the results, which stay, with
    /// Try Again for that page (#154).</summary>
    private string? _loadMoreError;
    /// <summary>That page failed because the AO3 session expired: offer Sign In
    /// Again, not a Try Again that would fail the same way.</summary>
    private bool _loadMoreSessionExpired;
    /// <summary>The last next-page run stopped on pages the content filter hid
    /// entirely, with more to load: the footer offers Load More (#155).</summary>
    private bool _stoppedOnHiddenPages;
    /// <summary>The error is an expired AO3 session (#131): offer Sign In Again.</summary>
    private bool _sessionExpired;
    private CancellationTokenSource? _searchCts;
    /// <summary>Bumped by every search and cancel: a response from an older
    /// search can never overwrite the results asked for last.</summary>
    private int _searchGeneration;
    private bool _slowNoteVisible;
    private DispatcherQueueTimerHolder? _slowTimer;
    private IReadOnlyList<SuggestionCandidate> _tagSuggestions = [];
    private string _suggestionKey = "";
    private CancellationTokenSource? _suggestCts;
    /// <summary>Set once a sort is chosen deliberately (sort bar, Filters sheet, a
    /// saved search); until then the sort follows <see cref="SearchSyntax.AutomaticSort"/>.</summary>
    private bool _userPickedSort;
    /// <summary>Focus is in the box or the suggestion row (searchFocused).</summary>
    private bool _focusInBox;
    /// <summary>Suggestions put away (Enter, Esc, a search run) until the next keystroke —
    /// what dismissing the keyboard does on the phone.</summary>
    private bool _suggestionsDismissed;

    // MARK: - Views

    private bool _built;
    private Grid _root = null!;
    private AutoSuggestBox _box = null!;
    private Button _filtersButton = null!;
    private ScrollViewer _suggestionScroller = null!;
    private StackPanel _suggestionRow = null!;
    private string _renderedSuggestionIds = "";
    private FlowPanel _chips = null!;
    private string _renderedChipIds = "";
    private Grid _sortBar = null!;
    private TextBlock _countText = null!;
    private DropDownButton _sortButton = null!;
    private TextBlock _sortLabel = null!;
    private Button _directionButton = null!;
    private Microsoft.UI.Xaml.Controls.ContentControl _content = null!;
    private VirtualList<AO3WorkSummary> _list = null!;

    public SearchScreen()
    {
        SearchModule.EnsureSymbols();
        Title = "Search";
        // The deep link / jump list / widget hand-off (search.pendingQuery):
        // run it as soon as it's set, like the Swift view's onChange.
        KeyValueStores.Default.Changed += OnSettingChanged;
        Routes.SearchRequested += _ => ConsumePendingQuery();
        Store.Changed += OnLibraryChanged;
    }

    // MARK: - Build

    protected override FrameworkElement Build()
    {
        _root = UI.UI.Grid("*", "Auto,*");
        _root.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        // Ctrl+F / F3: back to the search box from anywhere on the screen.
        _root.Shortcut(VirtualKey.F, VirtualKeyModifiers.Control, FocusSearchBox);
        _root.Shortcut(VirtualKey.F3, VirtualKeyModifiers.None, FocusSearchBox);

        _root.Children.Add(BuildHeader().Row(0));

        _list = new VirtualList<AO3WorkSummary>(BuildResultRow, padding: new Thickness(10, 0, 10, 24))
        {
            LoadMore = LoadMoreAsync,
        };
        _list.Element.XYFocusKeyboardNavigation = XYFocusKeyboardNavigationMode.Enabled;
        AutomationProperties.SetAutomationId(_list.Element, "search.results");
        AutomationProperties.SetName(_list.Element, "Search results");

        _content = new Microsoft.UI.Xaml.Controls.ContentControl
        {
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
            IsTabStop = false,
        };
        _root.Children.Add(_content.Row(1));

        _built = true;
        _box.Text = _text;
        ResetList();
        RenderAll();
        return _root;
    }

    private FrameworkElement BuildHeader()
    {
        _box = new AutoSuggestBox
        {
            PlaceholderText = "Fandoms, ships, tropes, titles…",
            QueryIcon = new SymbolIcon(Symbol.Find),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAutomationId(_box, "search.box");
        AutomationProperties.SetName(_box, "Search AO3");
        AutomationProperties.SetHelpText(_box, "Type keywords and press Enter. Press Down to reach suggestions.");
        _box.TextChanged += (_, e) =>
        {
            if (e.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
            _text = _box.Text;
            _suggestionsDismissed = false;
            UpdateSuggestionKey();
            RenderHeader();
        };
        _box.QuerySubmitted += (_, _) => Submit();
        _box.GotFocus += (_, _) => SetFocusInBox(true);
        _box.LostFocus += (_, _) => CheckFocusLater();
        _box.PreviewKeyDown += OnBoxKeyDown;
        _box.Loaded += (_, _) => ConfigureInnerTextBox();

        _filtersButton = new Button
        {
            Background = Theme.Transparent,
            BorderBrush = Theme.Transparent,
            Padding = new Thickness(4),
            MinWidth = 40,
            MinHeight = 40,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAutomationId(_filtersButton, "search.filters");
        ToolTipService.SetToolTip(_filtersButton, "Filters");
        _filtersButton.Click += (_, _) => _ = ShowFiltersAsync();

        var top = UI.UI.Grid("*,Auto", columnSpacing: 10);
        top.Children.Add(_box.Col(0));
        top.Children.Add(_filtersButton.Col(1));

        _suggestionRow = UI.UI.HStack(8);
        _suggestionRow.Padding = new Thickness(2, 0, 2, 2);
        _suggestionRow.XYFocusKeyboardNavigation = XYFocusKeyboardNavigationMode.Enabled;
        AutomationProperties.SetName(_suggestionRow, "Suggestions");
        _suggestionScroller = new ScrollViewer
        {
            Content = _suggestionRow,
            HorizontalScrollMode = ScrollMode.Enabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            IsTabStop = false,
            Visibility = Visibility.Collapsed,
        };
        _suggestionScroller.LostFocus += (_, _) => CheckFocusLater();
        _suggestionScroller.GotFocus += (_, _) => SetFocusInBox(true);
        _suggestionScroller.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Escape || (e.Key == VirtualKey.Up && MainWindow.CurrentModifiers() == VirtualKeyModifiers.None))
            {
                e.Handled = true;
                if (e.Key == VirtualKey.Escape) DismissSuggestions();
                FocusBox(FocusState.Keyboard);
            }
        };

        _chips = UI.UI.Flow(6, 6);
        AutomationProperties.SetName(_chips, "Active filters");

        _countText = UI.UI.Secondary("", Theme.Style.Subheadline);
        _countText.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetLiveSetting(_countText, AutomationLiveSetting.Polite);

        _sortLabel = UI.UI.Text("", Theme.Style.Subheadline, Theme.Accent, wrap: false);
        _sortButton = new DropDownButton
        {
            Content = UI.UI.HStack(6,
                UI.UI.Icon("arrow.up.arrow.down", 13, Theme.Accent).Also(i => i.VerticalAlignment = VerticalAlignment.Center),
                _sortLabel),
            Background = Theme.Transparent,
            BorderBrush = Theme.Transparent,
            Padding = new Thickness(8, 4, 8, 4),
        };
        AutomationProperties.SetAutomationId(_sortButton, "search.sort");
        ToolTipService.SetToolTip(_sortButton, "Sort by");
        var sortMenu = new MenuFlyout();
        sortMenu.Opening += (_, _) => FillSortMenu(sortMenu);
        _sortButton.Flyout = sortMenu;

        _directionButton = new Button
        {
            Width = 32,
            Height = 32,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(4),
            Background = Theme.AccentSubtle,
            BorderBrush = Theme.Transparent,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAutomationId(_directionButton, "search.sortDirection");
        _directionButton.Click += (_, _) =>
        {
            _active.SortDirection = _active.SortDirection == SortDirection.Asc ? SortDirection.Desc : SortDirection.Asc;
            _userPickedSort = true;
            StartSearch();
        };

        _sortBar = UI.UI.Grid("*,Auto,Auto", columnSpacing: 8);
        _sortBar.Children.Add(_countText.Col(0));
        _sortBar.Children.Add(_sortButton.Col(1));
        _sortBar.Children.Add(_directionButton.Col(2));

        var header = UI.UI.VStack(10, top, _suggestionScroller, _chips, _sortBar);
        header.Padding = new Thickness(24, 12, 24, 8);
        return header;
    }

    /// <summary>Fandom names and ships aren't dictionary words — autocorrect turned
    /// "sterek" into "streak" on the phone, and Windows' spell check would underline them.</summary>
    private void ConfigureInnerTextBox()
    {
        if (FindDescendant<TextBox>(_box) is { } tb)
        {
            tb.IsSpellCheckEnabled = false;
            tb.IsTextPredictionEnabled = false;
        }
    }

    private static T? FindDescendant<T>(DependencyObject parent) where T : DependencyObject
    {
        var count = VisualTreeHelper.GetChildrenCount(parent);
        for (var i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is T match) return match;
            if (FindDescendant<T>(child) is { } deeper) return deeper;
        }
        return null;
    }

    private static bool IsWithin(DependencyObject? element, DependencyObject container)
    {
        while (element is not null)
        {
            if (element == container) return true;
            element = VisualTreeHelper.GetParent(element);
        }
        return false;
    }

    // MARK: - Screen

    public override IEnumerable<ICommandBarElement> PrimaryCommands()
    {
        var button = new AppBarButton
        {
            Icon = Symbols.Icon("bookmark"),
            Label = "Saved searches",
            LabelPosition = CommandBarLabelPosition.Collapsed,
        };
        ToolTipService.SetToolTip(button, "Saved searches");
        AutomationProperties.SetName(button, "Saved searches");
        AutomationProperties.SetAutomationId(button, "search.saved");
        var menu = new MenuFlyout();
        menu.Opening += (_, _) => FillSavedSearchesMenu(menu);
        button.Flyout = menu;
        yield return button;
    }

    public override void OnAppearing()
    {
        ConsumePendingQuery();
        // Content settings or hidden works may have changed while away.
        RefreshVisible();
        RenderAll();
    }

    private void OnSettingChanged(string key)
    {
        if (key is not (DeepLink.PendingSearchQueryKey or Fanficly.Core.ContentControl.FilterMatureKey or RecentSearches.StorageKey)) return;
        MainWindow.Current?.DispatcherQueue.TryEnqueue(() =>
        {
            switch (key)
            {
                case DeepLink.PendingSearchQueryKey:
                    ConsumePendingQuery();
                    break;
                case Fanficly.Core.ContentControl.FilterMatureKey:
                    RefreshVisible();
                    RenderContent();
                    break;
                default:
                    if (!_hasSearched) RenderContent();
                    break;
            }
        });
    }

    private void OnLibraryChanged(LibraryEntityKinds kinds)
    {
        if ((kinds & (LibraryEntityKinds.SavedSearches | LibraryEntityKinds.HiddenWorks | LibraryEntityKinds.BlockedTerms)) == 0) return;
        MainWindow.Current?.DispatcherQueue.TryEnqueue(() =>
        {
            if (!_built) return;
            if ((kinds & (LibraryEntityKinds.HiddenWorks | LibraryEntityKinds.BlockedTerms)) != 0) RefreshVisible();
            RenderContent();
        });
    }

    private void FocusSearchBox()
    {
        FocusBox(FocusState.Keyboard);
        if (FindDescendant<TextBox>(_box) is { } tb) tb.SelectAll();
    }

    private void FocusBox(FocusState state)
    {
        _box.Focus(state);
        if (FindDescendant<TextBox>(_box) is { } tb && tb.SelectionLength == 0) tb.SelectionStart = tb.Text.Length;
    }

    // MARK: - Focus and keys

    private bool IsComposing => _focusInBox && !_suggestionsDismissed;

    private void SetFocusInBox(bool focused)
    {
        if (_focusInBox == focused) return;
        _focusInBox = focused;
        UpdateSuggestionKey();
        RenderHeader();
    }

    /// <summary>Focus leaving the box for the suggestion row (or a suggestion
    /// being clicked) still counts as typing; anywhere else puts suggestions away.</summary>
    private void CheckFocusLater() => MainWindow.Current.DispatcherQueue.TryEnqueue(() =>
    {
        var focused = _root.XamlRoot is { } root ? FocusManager.GetFocusedElement(root) as DependencyObject : null;
        SetFocusInBox(IsWithin(focused, _box) || IsWithin(focused, _suggestionScroller));
    });

    private void OnBoxKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Down when _suggestionScroller.Visibility == Visibility.Visible && _suggestionRow.Children.Count > 0:
                e.Handled = true;
                ((Control)_suggestionRow.Children[0]).Focus(FocusState.Keyboard);
                break;
            case VirtualKey.Escape when _suggestionScroller.Visibility == Visibility.Visible:
                e.Handled = true;
                DismissSuggestions();
                break;
        }
    }

    private void DismissSuggestions()
    {
        _suggestionsDismissed = true;
        UpdateSuggestionKey();
        RenderHeader();
    }

    // MARK: - Rendering

    private void RenderAll()
    {
        if (!_built) return;
        RenderHeader();
        RenderContent();
    }

    private void RenderHeader()
    {
        if (!_built) return;
        RenderFiltersButton();
        RenderSuggestions();
        RenderChips();
        RenderSortBar();
    }

    private void RenderFiltersButton()
    {
        var count = SearchChips.For(_active).Count;
        var icon = UI.UI.Icon(count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle", 22, Theme.Accent);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.VerticalAlignment = VerticalAlignment.Center;
        var grid = new Grid { Width = 36, Height = 36 };
        grid.Children.Add(icon);
        if (count > 0)
        {
            grid.Children.Add(new InfoBadge
            {
                Value = count,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, -4, -6, 0),
            }.A11yHidden());
        }
        _filtersButton.Content = grid;
        AutomationProperties.SetName(_filtersButton, count > 0 ? $"Filters, {count} active" : "Filters");
        AutomationProperties.SetItemStatus(_filtersButton, count > 0 ? $"{count} active" : "None");
    }

    /// <summary>Instant local suggestions first, then AO3's tags; anything already
    /// applied is left out.</summary>
    private List<SuggestionCandidate> SuggestionCandidates()
    {
        var output = SearchSuggestions.Local(SearchSuggestions.ActiveWords(_text)).ToList();
        foreach (var candidate in _tagSuggestions)
        {
            if (!output.Any(o => string.Equals(o.Suggestion.Label, candidate.Suggestion.Label, StringComparison.OrdinalIgnoreCase)))
                output.Add(candidate);
        }
        return output.Where(candidate =>
        {
            var probe = _active.Clone();
            candidate.Suggestion.Apply(probe);
            return probe != _active;
        }).ToList();
    }

    private void RenderSuggestions()
    {
        var candidates = IsComposing ? SuggestionCandidates() : [];
        var ids = string.Join("\n", candidates.Select(c => c.Id));
        if (ids != _renderedSuggestionIds)
        {
            _renderedSuggestionIds = ids;
            var hadFocus = _root.XamlRoot is { } root && IsWithin(FocusManager.GetFocusedElement(root) as DependencyObject, _suggestionRow);
            _suggestionRow.Children.Clear();
            foreach (var candidate in candidates)
                _suggestionRow.Children.Add(SearchChips.SuggestionButton(candidate, () => ApplySuggestion(candidate)));
            if (hadFocus) FocusBox(FocusState.Keyboard);
        }
        _suggestionScroller.Visibility = candidates.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RenderChips()
    {
        var chips = SearchChips.For(_active);
        var ids = string.Join("\n", chips.Select(c => c.Id)) + (_hasSearched ? "|searched" : "");
        if (ids == _renderedChipIds) return;
        _renderedChipIds = ids;
        _chips.Children.Clear();
        for (var i = 0; i < chips.Count; i++)
        {
            var chip = chips[i];
            var index = i;
            _chips.Children.Add(SearchChips.RemovableChip(chip, _hasSearched, () => RemoveChip(chip, index)));
        }
        _chips.Visibility = chips.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RemoveChip(ActiveChip chip, int index)
    {
        chip.Remove(_active);
        MainWindow.Current.Announce($"Removed filter: {chip.Label}");
        if (_hasSearched) StartSearch();
        RenderAll();
        // Keep the keyboard where it was: the chip that took this one's place,
        // the one before it, or the box.
        if (_chips.Children.Count > 0)
            ((Control)_chips.Children[Math.Min(index, _chips.Children.Count - 1)]).Focus(FocusState.Keyboard);
        else
            FocusBox(FocusState.Keyboard);
    }

    private void RenderSortBar()
    {
        var visible = _hasSearched && !_isSearching && _errorMessage is null;
        _sortBar.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (!visible) return;
        _countText.Text = _totalFound is { } total
            ? total == 1 ? "1 work" : $"{total.ToString("N0", CultureInfo.CurrentCulture)} works"
            : "";
        _countText.Visibility = _totalFound is null ? Visibility.Collapsed : Visibility.Visible;
        var column = _active.SortColumn.DisplayName();
        _sortLabel.Text = column;
        AutomationProperties.SetName(_sortButton, $"Sort by, {column}");
        AutomationProperties.SetItemStatus(_sortButton, column);
        _directionButton.Content = UI.UI.Icon(_active.SortDirection.Symbol(), 13, Theme.Accent);
        var direction = _active.SortDirection.DisplayName();
        AutomationProperties.SetName(_directionButton, $"Sort direction, {direction}");
        AutomationProperties.SetItemStatus(_directionButton, direction);
        ToolTipService.SetToolTip(_directionButton, $"Sort direction: {direction}");
    }

    private void FillSortMenu(MenuFlyout menu)
    {
        menu.Items.Clear();
        foreach (var column in SearchEnums.AllSortColumns)
        {
            var item = new RadioMenuFlyoutItem { Text = column.DisplayName(), GroupName = "search.sort", IsChecked = column == _active.SortColumn };
            item.Click += (_, _) =>
            {
                if (column == _active.SortColumn) return;
                _active.SortColumn = column;
                _userPickedSort = true;
                StartSearch();
            };
            menu.Items.Add(item);
        }
    }

    private void RenderContent()
    {
        if (!_built) return;
        UIElement view;
        if (_isSearching)
        {
            view = SearchingView();
        }
        else if (_errorMessage is { } expired && _sessionExpired && !AppHost.Auth.HasSession)
        {
            view = SessionExpiry.EmptyState(expired);
        }
        else if (_errorMessage is not null && _sessionExpired)
        {
            // Signed in again since: the expiry note no longer stands.
            view = UI.UI.EmptyState("magnifyingglass", "Signed in again", "Search again to see every result, restricted works included.", "Try Again", StartSearch);
        }
        else if (_errorMessage is { } error)
        {
            view = UI.UI.EmptyState("exclamationmark.triangle", "Search failed", error, "Try Again", StartSearch);
        }
        else if (!_hasSearched)
        {
            view = StartView();
        }
        else if (_results.Count == 0)
        {
            var hasChips = SearchChips.For(_active).Count > 0;
            view = UI.UI.EmptyState("magnifyingglass", "No results",
                hasChips
                    ? "Try removing a filter, or fewer keywords — AO3 matches every word."
                    : "Try different keywords, or fewer of them — AO3 matches every word.",
                hasChips ? "Remove All Filters" : null,
                hasChips ? () => { ClearFilters(); StartSearch(); RenderAll(); } : null);
        }
        else if (_list.Items.Count == 0)
        {
            // Rows are what ask for the next page, so offer it here.
            const string soFar = "Every match so far is hidden or filtered out by your content settings.";
            if (_isLoadingMore)
                view = UI.UI.VStack(12,
                        UI.UI.EmptyState("eye.slash", "Nothing to show", soFar),
                        new ProgressRing { IsActive = true, Width = 24, Height = 24 }.A11y("Loading more results"))
                    .Also(p => p.VerticalAlignment = VerticalAlignment.Center);
            else if (_currentPage >= _totalPages)
                view = UI.UI.EmptyState("eye.slash", "Nothing to show",
                    "Every match is hidden or filtered out by your content settings.");
            else if (_loadMoreError is { } failed && LoadMoreNeedsSignIn)
                view = UI.UI.EmptyState("eye.slash", "Nothing to show", $"{soFar} {failed}",
                    SessionExpiry.ActionTitle, Routes.OpenLogin);
            else if (_loadMoreError is { } failedPage)
                view = UI.UI.EmptyState("eye.slash", "Nothing to show", $"{soFar} {failedPage}",
                    "Try Again", () => _ = LoadMoreAsync());
            else
                view = UI.UI.EmptyState("eye.slash", "Nothing to show", soFar,
                    "Load more results", () => _ = LoadMoreAsync());
        }
        else
        {
            view = _list.Element;
        }
        if (!ReferenceEquals(_content.Content, view)) _content.Content = view;
        _list.Footer = LoadMoreFooter();
    }

    /// <summary>Under the results: a spinner while the next page loads, or why it
    /// failed with Try Again (Sign In Again for an expired session), like
    /// <c>PagedWorksList</c>. The list's own infinite scroll stays off until then.</summary>
    private bool LoadMoreNeedsSignIn => _loadMoreSessionExpired && !AppHost.Auth.HasSession;

    private UIElement? LoadMoreFooter()
    {
        if (_isLoadingMore)
            return new ProgressRing { IsActive = true, Width = 24, Height = 24, Margin = new Thickness(0, 8, 0, 8), HorizontalAlignment = HorizontalAlignment.Center }
                .A11y("Loading more results");
        if (_loadMoreError is not { } error)
            return _stoppedOnHiddenPages && _currentPage < _totalPages && _list.Items.Count > 0
                ? HiddenPagesFooter()
                : null;
        var button = LoadMoreNeedsSignIn
            ? UI.UI.Button(SessionExpiry.ActionTitle, Routes.OpenLogin, kind: UI.UI.ButtonKind.Accent)
            : UI.UI.Button("Try Again", () => _ = LoadMoreAsync());
        button.HorizontalAlignment = HorizontalAlignment.Center;
        var footer = UI.UI.VStack(6,
            UI.UI.Secondary(error, Theme.Style.Footnote).Also(t => t.TextAlignment = TextAlignment.Center),
            button);
        footer.HorizontalAlignment = HorizontalAlignment.Center;
        footer.Margin = new Thickness(0, 8, 0, 8);
        return footer;
    }

    /// <summary>After a run of hidden pages: nothing new scrolled into view, so
    /// the next page waits for a press (#155).</summary>
    private UIElement HiddenPagesFooter()
    {
        var button = UI.UI.Button("Load More", () => _ = LoadMoreAsync());
        button.HorizontalAlignment = HorizontalAlignment.Center;
        var footer = UI.UI.VStack(6,
            UI.UI.Secondary("The last few pages are hidden by your content settings.", Theme.Style.Footnote)
                .Also(t => t.TextAlignment = TextAlignment.Center),
            button);
        footer.HorizontalAlignment = HorizontalAlignment.Center;
        footer.Margin = new Thickness(0, 8, 0, 8);
        return footer;
    }

    private FrameworkElement SearchingView()
    {
        var stack = UI.UI.VStack(12,
            new ProgressRing { IsActive = true, Width = 32, Height = 32 }.A11y("Searching AO3"),
            UI.UI.Secondary("Searching AO3…", Theme.Style.Body).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center));
        // AO3 often takes 20–30 s to answer a search; say so, and offer a way
        // out, once it's clearly not instant.
        if (_slowNoteVisible)
        {
            var cancel = UI.UI.Button("Cancel", CancelSearch);
            cancel.HorizontalAlignment = HorizontalAlignment.Center;
            AutomationProperties.SetAutomationId(cancel, "search.cancel");
            AutomationProperties.SetHelpText(cancel, "Stops this search");
            stack.Children.Add(UI.UI.VStack(10,
                UI.UI.Secondary("AO3 can take up to half a minute to search.", Theme.Style.Footnote)
                    .Also(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.TextAlignment = TextAlignment.Center; }),
                cancel));
        }
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Center;
        stack.Padding = new Thickness(16);
        return stack;
    }

    // MARK: - Start view (recent and saved searches)

    private static List<SavedSearch> SavedSearches() =>
        Store.All<SavedSearch>().OrderByDescending(s => s.SavedAt).ToList();

    /// <summary>Before the first search: recent and saved searches, or a short intro.</summary>
    private FrameworkElement StartView()
    {
        var recents = RecentSearches.Load();
        var saved = SavedSearches();
        if (recents.Count == 0 && saved.Count == 0)
        {
            return UI.UI.EmptyState("magnifyingglass", "Search AO3",
                "Type a fandom, ship, trope, title or author. Select a suggestion to filter by an exact tag.",
                "Search Tips", () => _ = SearchHelp.ShowAsync());
        }

        var stack = UI.UI.VStack(8);
        if (recents.Count > 0)
        {
            var clear = UI.UI.Button("Clear", () =>
            {
                RecentSearches.Clear();
                MainWindow.Current.Announce("Recent searches cleared");
                RenderContent();
            }, kind: UI.UI.ButtonKind.Subtle);
            clear.Foreground = Theme.Accent;
            clear.Padding = new Thickness(8, 2, 8, 2);
            clear.VerticalAlignment = VerticalAlignment.Bottom;
            AutomationProperties.SetName(clear, "Clear recent searches");
            AutomationProperties.SetAutomationId(clear, "search.recent.clear");
            var header = UI.UI.Grid("*,Auto");
            header.Children.Add(UI.UI.SectionHeader("Recent").Col(0));
            header.Children.Add(clear.Col(1));

            var rows = new List<ListRow>();
            foreach (var prompt in recents)
            {
                void Remove()
                {
                    RecentSearches.Remove(prompt);
                    MainWindow.Current.Announce("Removed from recent searches");
                    RenderContent();
                }
                rows.Add(new ListRow(UI.UI.Label("clock.arrow.circlepath", prompt, maxLines: UI.UI.LineLimit(1)), prompt, "Runs this search again",
                    () => LoadPrompt(prompt), Remove, [UI.UI.MenuItem("Remove", Remove, "trash", isDestructive: true)]));
            }
            stack.Children.Add(UI.UI.VStack(2, header, RowList("search.recent", "Recent searches", rows)));
        }
        if (saved.Count > 0)
        {
            var rows = new List<ListRow>();
            foreach (var s in saved)
            {
                void Delete()
                {
                    LibrarySyncManager.RecordDeletionShared(DeletionKind.Search, s.Name);
                    Store.Delete(s);
                    Store.TrySave();
                    MainWindow.Current.Announce($"Deleted {s.Name}");
                    RenderContent();
                }
                var text = UI.UI.VStack(2,
                    UI.UI.Text(s.Name, Theme.Style.Headline),
                    UI.UI.Text(s.Prompt, Theme.Style.Caption, Theme.TextSecondary, wrap: false));
                if (SearchEnums.ParseSortColumn(s.SortColumn) is { } col)
                    text.Children.Add(UI.UI.Text($"Sort: {col.DisplayName()} {(s.SortDirection == "asc" ? "↑" : "↓")}", Theme.Style.Caption2, Theme.TextTertiary));
                var status = AlertStatus(s);
                if (status is not null) text.Children.Add(UI.UI.Label("bell.fill", status, Theme.Style.Caption,
                    s.AlertNewWorkIds.Count > 0 ? Theme.Accent : Theme.TextSecondary, spacing: 4));
                var alerts = UI.UI.MenuItem(s.AlertsEnabled ? "Turn Off New-Fic Alerts" : "Alert Me About New Fics",
                    () => Later(() => _ = ToggleAlertsAsync(s)), s.AlertsEnabled ? "bell.fill" : "bell");
                AutomationProperties.SetAutomationId(alerts, "search.saved.alerts");
                rows.Add(new ListRow(text, status is null ? s.Name : $"{s.Name}, {status}", $"Runs {s.Prompt}", () => LoadSaved(s), Delete,
                    [alerts, UI.UI.MenuItem("Delete", Delete, "trash", isDestructive: true)]));
            }
            stack.Children.Add(UI.UI.VStack(2, UI.UI.SectionHeader("Saved searches"), RowList("search.saved.list", "Saved searches", rows)));
        }
        return UI.UI.Scroll(stack);
    }

    /// <summary>A saved search's alert line (#309): "Alerts on", or how many
    /// alerted fics haven't been looked at yet. Null with alerts off.</summary>
    private static string? AlertStatus(SavedSearch s) =>
        !s.AlertsEnabled ? null : s.AlertNewWorkIds.Count > 0 ? $"{s.AlertNewWorkIds.Count} new" : "Alerts on";

    /// <summary>Switches a saved search's new-fic alerts on or off, up to
    /// <see cref="SavedSearchAlerts.MaxAlertingSearches"/> at once. Switching on
    /// records what the search finds now, so only fics posted after this alert;
    /// if that fails, the next poll takes the baseline instead.</summary>
    private async Task ToggleAlertsAsync(SavedSearch s)
    {
        var on = !s.AlertsEnabled;
        if (on && !SavedSearchAlerts.CanEnableMore(Store))
        {
            await Dialogs.AlertAsync("Too many alerts",
                $"You can have new-fic alerts on for up to {SavedSearchAlerts.MaxAlertingSearches} saved searches. Turn one off to add another.");
            return;
        }
        SavedSearchAlerts.SetAlerts(on, s, Store);
        LibrarySyncManager.QueueBackupShared(Store);
        MainWindow.Current.Announce(on ? $"New-fic alerts on for {s.Name}" : $"New-fic alerts off for {s.Name}");
        if (!_hasSearched) RenderContent();
        if (on) await TakeAlertBaselineAsync(s);
    }

    private async Task TakeAlertBaselineAsync(SavedSearch s)
    {
        if (AppHost.IsDemoMode) return;
        var poller = new SubscriptionPoller(Client, Store, AppHost.Auth.Username, new AppHost.ToastNotifier());
        await poller.CheckSavedSearchAsync(s);
        Store.TrySave();
    }

    /// <summary>One row of the start view's lists (the Swift List rows with a
    /// swipe-to-delete action; here Delete or the context menu removes it).</summary>
    private sealed record ListRow(UIElement Content, string Name, string Help, Action Open, Action Delete, IReadOnlyList<MenuFlyoutItem> MenuItems);

    /// <summary>An inset list card: a Fluent ListView (arrow keys, Narrator's
    /// "list, n of m"); clicking a row opens it, Delete removes it.</summary>
    private static Border RowList(string automationId, string name, IReadOnlyList<ListRow> rows)
    {
        var list = new ListView
        {
            SelectionMode = ListViewSelectionMode.None,
            IsItemClickEnabled = true,
            Padding = new Thickness(0, 4, 0, 4),
        };
        ScrollViewer.SetVerticalScrollMode(list, ScrollMode.Disabled);
        ScrollViewer.SetVerticalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        AutomationProperties.SetAutomationId(list, automationId);
        AutomationProperties.SetName(list, name);
        var byItem = new Dictionary<ListViewItem, ListRow>();
        foreach (var row in rows)
        {
            var item = new ListViewItem
            {
                Content = row.Content,
                Padding = new Thickness(14, 8, 14, 8),
                MinHeight = 44,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
            };
            AutomationProperties.SetName(item, row.Name);
            AutomationProperties.SetHelpText(item, row.Help);
            item.ContextFlyout = UI.UI.Menu(row.MenuItems.Cast<MenuFlyoutItemBase?>().ToArray());
            byItem[item] = row;
            list.Items.Add(item);
        }
        ListRow? Find(object? clicked) => clicked switch
        {
            ListViewItem lvi when byItem.TryGetValue(lvi, out var r) => r,
            _ => byItem.FirstOrDefault(kv => ReferenceEquals(kv.Key.Content, clicked)).Value,
        };
        list.ItemClick += (_, e) => Find(e.ClickedItem)?.Open();
        list.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Delete || list.XamlRoot is not { } root) return;
            var focused = FocusManager.GetFocusedElement(root) as DependencyObject;
            while (focused is not null and not ListViewItem) focused = VisualTreeHelper.GetParent(focused);
            if (focused is ListViewItem lvi && byItem.TryGetValue(lvi, out var row))
            {
                e.Handled = true;
                row.Delete();
            }
        };
        return new Border
        {
            Child = list,
            CornerRadius = new CornerRadius(8),
            Background = Theme.CardBackground,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
        };
    }

    // MARK: - Results

    /// <summary>Results minus hidden works, blocked tags and authors (except ones
    /// this search asked for by name) and (optionally) Mature/Explicit-rated ones.</summary>
    private IReadOnlyList<AO3WorkSummary> Visible(IEnumerable<AO3WorkSummary> works) =>
        ContentFilter.Apply(works, HiddenWorkStore.Ids(Store),
            KeyValueStores.Default.GetBool(Fanficly.Core.ContentControl.FilterMatureKey, true),
            Blocklist.From(Store).Lifting(_searched ?? _active));

    private void ResetList()
    {
        if (!_built) return;
        _list.Reset(Visible(_results));
        _list.HasMore = _currentPage < _totalPages && _loadMoreError is null;
    }

    /// <summary>Re-applies the content filter after a setting or a hidden work
    /// changed, keeping the scroll position (coming back from a work must not
    /// jump the results to the top).</summary>
    private void RefreshVisible()
    {
        if (!_built || !_hasSearched) return;
        var visible = Visible(_results);
        if (visible.Select(w => w.Id).SequenceEqual(_list.Items.Select(w => w.Id))) return;
        var offset = _list.Element.VerticalOffset;
        ResetList();
        MainWindow.Current.DispatcherQueue.TryEnqueue(() => _list.Element.ChangeView(null, offset, null, disableAnimation: true));
    }

    private UIElement BuildResultRow(AO3WorkSummary work, int index)
    {
        var holder = new Border();
        void Fill()
        {
            var row = WorkRow.Build(work);
            ToolTipService.SetToolTip(row, $"Read {work.Title}");
            holder.Child = row;
        }
        Fill();

        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            menu.Items.Add(UI.UI.MenuItem("Read Now", () => Routes.OpenWork(work.Id, work), "book"));
            var followed = WorkPersistence.IsFollowed(work.Id, Store);
            menu.Items.Add(UI.UI.MenuItem(followed ? "Remove from Library" : "Save to Library", () => Later(() =>
            {
                var saved = WorkPersistence.ToggleFollow(work, Store);
                // Redraw the row so its bookmark button shows the new state.
                var hadFocus = holder.XamlRoot is { } root && IsWithin(FocusManager.GetFocusedElement(root) as DependencyObject, holder);
                Fill();
                if (hadFocus && holder.Child is Control c) c.Focus(FocusState.Keyboard);
                MainWindow.Current.Announce(saved ? "Saved to Library" : "Removed from Library");
            }), followed ? "bookmark.slash" : "bookmark"));
            menu.Items.Add(UI.UI.MenuItem("Share Story...", () =>
                ShareLink.Share(work.Title, new Uri($"https://archiveofourown.org/works/{work.Id}"), $"Check out this story: {work.Title}"),
                "square.and.arrow.up"));
        };
        holder.ContextFlyout = menu;
        return UI.UI.VStack(0, holder, UI.UI.Divider(14));
    }

    // MARK: - Suggestions

    /// <summary>The words at the end of the box, when the box is being typed in.</summary>
    private void UpdateSuggestionKey()
    {
        var key = IsComposing ? string.Join(" ", SearchSuggestions.ActiveWords(_text)).ToLowerInvariant() : "";
        if (key == _suggestionKey) return;
        _suggestionKey = key;
        // Debounced AO3 tag suggestions for the words being typed; restarts
        // (cancelling the last lookup) whenever those words change.
        _suggestCts?.Cancel();
        _suggestCts = new CancellationTokenSource();
        _tagSuggestions = [];
        _ = LoadTagSuggestionsAsync(_suggestCts.Token);
    }

    private async Task LoadTagSuggestionsAsync(CancellationToken ct)
    {
        var words = SearchSuggestions.ActiveWords(_text);
        if (!IsComposing || words.Count == 0) return;
        // Wait for a pause in typing: every lookup is a throttled AO3 request.
        try { await Task.Delay(350, ct); }
        catch (OperationCanceledException) { return; }
        // The longest trailing phrase AO3 has tags for: "teen wolf slow" backs
        // off to "wolf slow", then "slow".
        for (var n = words.Count; n >= 1; n--)
        {
            var phrase = string.Join(" ", words.Skip(words.Count - n));
            if (new StringInfo(phrase).LengthInTextElements < 2) continue;
            IReadOnlyList<string> names;
            if (TagSuggestionCache.Shared.Value(phrase) is { } cached)
            {
                names = cached;
            }
            else
            {
                try { names = await Client.AutocompleteAsync(AO3AutocompleteField.Tag, phrase, ct); }
                catch { return; }
                TagSuggestionCache.Shared.Set(names, phrase);
            }
            if (ct.IsCancellationRequested) return;
            var ranked = SearchSuggestions.RankTags(names, phrase);
            if (ranked.Count > 0)
            {
                var consumed = n;
                _tagSuggestions = ranked.Select(t => new SuggestionCandidate(SearchSuggestion.Tag(t), consumed)).ToList();
                RenderHeader();
                return;
            }
        }
    }

    private void ApplySuggestion(SuggestionCandidate candidate)
    {
        var text = _text;
        SearchSuggestions.Apply(candidate, ref text, _active);
        SetText(text);
        _tagSuggestions = [];
        MainWindow.Current.Announce($"Added filter: {candidate.Suggestion.Label}");
        // Refining results that are already showing: keep them in step with the
        // chips. Before the first search, keep composing instead.
        if (_hasSearched) StartSearch();
        FocusBox(FocusState.Keyboard);
        UpdateSuggestionKey();
        RenderHeader();
    }

    private void SetText(string text)
    {
        _text = text;
        if (!_built) return;
        _box.Text = text;
        if (FindDescendant<TextBox>(_box) is { } tb) tb.SelectionStart = text.Length;
    }

    // MARK: - Filters sheet

    private async Task ShowFiltersAsync()
    {
        var sortWhenOpened = _active.SortColumn;
        var edited = await WorkFilterSheet.ShowAsync(_active);
        if (edited is null) return;
        _active = edited;
        if (_active.SortColumn != sortWhenOpened) _userPickedSort = true;
        if (_hasSearched || !CurrentFilters.IsEmpty) Submit();
        else RenderHeader();
    }

    private void ClearFilters()
    {
        var (column, direction) = (_active.SortColumn, _active.SortDirection);
        _active = new AO3SearchFilters { SortColumn = column, SortDirection = direction };
    }

    // MARK: - Searching

    /// <summary>The whole search: chips plus the keywords in the box.</summary>
    private AO3SearchFilters CurrentFilters
    {
        get
        {
            var filters = _active.Clone();
            filters.Query = SearchSyntax.CollapseWhitespace(_text);
            return filters;
        }
    }

    /// <summary>Runs the search box: explicit tokens and filter phrases typed there
    /// become chips; the rest stays as keywords.</summary>
    private void Submit()
    {
        // The box's own text: TextChanged can still be queued when Enter lands
        // right after the last keystroke, so _text may be a step behind.
        _text = _box.Text;
        var parsed = SearchSyntax.Parse(_text);
        _active = _active.Merging(parsed);
        SetText(parsed.Query);
        _suggestionsDismissed = true;
        UpdateSuggestionKey();
        StartSearch();
        RenderHeader();
    }

    private void StartSearch()
    {
        if (CurrentFilters.IsEmpty) return;
        if (!_userPickedSort)
        {
            _active.SortColumn = SearchSyntax.AutomaticSort(hasKeywords: CurrentFilters.Query.Length > 0);
            _active.SortDirection = SortDirection.Desc;
        }
        var filters = CurrentFilters;
        RecentSearches.Record(filters.PromptText());
        // A newer search replaces an in-flight one, so a slow earlier response
        // can never overwrite the results you asked for last.
        _searchCts?.Cancel();
        _searchCts = new CancellationTokenSource();
        var generation = ++_searchGeneration;
        _ = PerformSearchAsync(filters, generation, _searchCts.Token);
    }

    private void CancelSearch()
    {
        _searchCts?.Cancel();
        _searchCts = null;
        _searchGeneration++;
        _slowTimer?.Stop();
        _isSearching = false;
        _slowNoteVisible = false;
        MainWindow.Current.Announce("Search cancelled");
        RenderAll();
    }

    private async Task PerformSearchAsync(AO3SearchFilters requested, int generation, CancellationToken ct)
    {
        _errorMessage = null;
        _sessionExpired = false;
        _isSearching = true;
        _slowNoteVisible = false;
        StartSlowTimer(generation);
        RenderAll();
        var filters = requested;
        try
        {
            // Tags typed into the Filters sheet's fields get AO3's canonical names
            // first (suggestions already are canonical, so they skip this).
            if (filters.FandomNames.Count + filters.RelationshipNames.Count + filters.CharacterNames.Count + filters.FreeformNames.Count > 0)
            {
                filters = await TagResolver.ResolveAsync(filters, Client, ct: ct);
                if (generation != _searchGeneration) return;
                _active.FandomNames = [.. filters.FandomNames];
                _active.RelationshipNames = [.. filters.RelationshipNames];
                _active.CharacterNames = [.. filters.CharacterNames];
                _active.FreeformNames = [.. filters.FreeformNames];
            }

            var result = await Client.SearchAsync(filters, 1, ct);
            if (generation != _searchGeneration) return;
            SessionExpiry.Check(result);
            _loadMoreError = null;
            _stoppedOnHiddenPages = false;
            _results = result.Works.ToList();
            _totalFound = result.TotalFound;
            _totalPages = result.TotalPages;
            _currentPage = result.CurrentPage;
            _searched = filters;
            _hasSearched = true;
            ResetList();
            // Narrator gets no cue from the list swap alone.
            MainWindow.Current.Announce(result.TotalFound is { } found
                ? $"Search finished. {found} works found."
                : $"Search finished. {_results.Count} works on this page.");
        }
        catch (Exception) when (generation != _searchGeneration || ct.IsCancellationRequested)
        {
            return;
        }
        catch (Exception e)
        {
            _sessionExpired = SessionExpiry.Explains(e);
            _errorMessage = _sessionExpired ? SessionExpiry.MessageFor(e) : Message(e);
        }
        _slowTimer?.Stop();
        _isSearching = false;
        _slowNoteVisible = false;
        RenderAll();
        // A first page the content filter hides entirely has no row to scroll
        // to, so fetch on by itself rather than look like the end (#155).
        if (_errorMessage is null && _results.Count > 0 && _list.Items.Count == 0 && _currentPage < _totalPages)
            await LoadMoreAsync();
    }

    private void StartSlowTimer(int generation)
    {
        _slowTimer?.Stop();
        _slowTimer = new DispatcherQueueTimerHolder(TimeSpan.FromSeconds(5), () =>
        {
            if (generation != _searchGeneration || !_isSearching) return;
            _slowNoteVisible = true;
            RenderContent();
        });
    }

    private static string Message(Exception error) => error switch
    {
        AO3Exception { Kind: AO3ErrorKind.LoginFailed } e => e.Reason ?? e.Message,
        AO3Exception { Kind: AO3ErrorKind.Http, Status: { } status } e when AO3Exception.IsServerUnavailable(status) => e.Message,
        AO3Exception { Kind: AO3ErrorKind.Http } e => $"AO3 returned HTTP {e.Status}.",
        AO3Exception { Kind: AO3ErrorKind.ParseFailed } e => $"Couldn't read AO3's response: {e.Reason}",
        AO3Exception { Kind: AO3ErrorKind.Network } e => $"Network: {e.Reason}",
        AO3Exception { Kind: AO3ErrorKind.RateLimited } => "AO3 is asking us to slow down. Try again in a minute.",
        AO3Exception { Kind: AO3ErrorKind.Unauthorized } => "AO3 sent its login page instead of results. Sign in again, then try again.",
        _ => error.Message,
    };

    private async Task LoadMoreAsync()
    {
        // There's no page past totalPages, and a search in flight owns the list.
        if (_isLoadingMore || _isSearching || _currentPage >= _totalPages || _searched is not { } searched) return;
        var generation = _searchGeneration;
        var ct = _searchCts?.Token ?? CancellationToken.None;
        _isLoadingMore = true;
        _loadMoreError = null;
        _stoppedOnHiddenPages = false;
        RenderContent();
        try
        {
            // A page whose works are all hidden adds no rows, and nothing would
            // scroll to ask for the next; fetch on (a few pages at most) instead,
            // then leave the next run to the footer's Load More (#155).
            var ended = false;
            for (var attempt = 0; attempt < 3 && _currentPage < _totalPages; attempt++)
            {
                var result = await Client.SearchAsync(searched, _currentPage + 1, ct);
                if (generation != _searchGeneration) return; // a new search started meanwhile
                SessionExpiry.Check(result);
                var existing = _results.Select(w => w.Id).ToHashSet();
                var added = result.Works.Where(w => !existing.Contains(w.Id)).ToList();
                _results.AddRange(added);
                _currentPage = result.CurrentPage;
                _totalPages = result.TotalPages;
                var visible = Visible(added);
                _list.Append(visible);
                _list.HasMore = _currentPage < _totalPages;
                if (visible.Count > 0 || added.Count == 0) { ended = true; break; }
            }
            _stoppedOnHiddenPages = !ended && _currentPage < _totalPages;
        }
        catch (Exception) when (generation != _searchGeneration || ct.IsCancellationRequested)
        {
            return;
        }
        catch (Exception e)
        {
            // The results so far stay, with the sort bar; the footer says why
            // and Try Again picks up at the page that failed (#154).
            _loadMoreSessionExpired = SessionExpiry.Explains(e);
            _loadMoreError = _loadMoreSessionExpired ? SessionExpiry.MessageFor(e) : $"Couldn't load more: {Message(e)}";
            _list.HasMore = false;
            MainWindow.Current.Announce(_loadMoreError);
            AppHost.Log($"Search: next page failed: {e.Message}");
        }
        finally
        {
            _isLoadingMore = false;
            if (generation == _searchGeneration) RenderContent();
        }
    }

    // MARK: - Saved, recent and linked searches

    /// <summary>Loads a stored search (saved, recent, jump list or link) into the box
    /// and chips, then runs it.</summary>
    private void LoadPrompt(string prompt, SortColumn? sortColumn = null, SortDirection? sortDirection = null)
    {
        var parsed = SearchSyntax.Parse(prompt);
        var filters = new AO3SearchFilters().Merging(parsed);
        filters.SortColumn = sortColumn ?? _active.SortColumn;
        filters.SortDirection = sortDirection ?? _active.SortDirection;
        _active = filters;
        SetText(parsed.Query);
        _suggestionsDismissed = true;
        UpdateSuggestionKey();
        StartSearch();
        RenderHeader();
    }

    private void LoadSaved(SavedSearch saved)
    {
        SavedSearchAlerts.MarkSeen(saved, Store);
        _userPickedSort = true;
        LoadPrompt(saved.Prompt,
            SearchEnums.ParseSortColumn(saved.SortColumn) ?? SortColumn.BestMatch,
            SearchEnums.ParseSortDirection(saved.SortDirection) ?? SortDirection.Desc);
    }

    private void ConsumePendingQuery()
    {
        var prompt = KeyValueStores.Default.GetString(DeepLink.PendingSearchQueryKey) ?? "";
        if (prompt.Length == 0) return;
        KeyValueStores.Default.SetString(DeepLink.PendingSearchQueryKey, "");
        if (DeepLink.SavedFilter(prompt) is not { } saved)
        {
            LoadPrompt(prompt);
            return;
        }
        // A saved filter runs as saved, sort included. Reading it back as a
        // prompt would turn keywords like "complete" into filters.
        _userPickedSort = true;
        _active = saved;
        SetText(saved.Query);
        _suggestionsDismissed = true;
        UpdateSuggestionKey();
        StartSearch();
        RenderHeader();
    }

    private string SuggestName()
    {
        var prompt = CurrentFilters.PromptText();
        return prompt.Length == 0 ? "Untitled" : prompt.Length > 40 ? prompt[..40] : prompt;
    }

    private void FillSavedSearchesMenu(MenuFlyout menu)
    {
        menu.Items.Clear();
        var save = UI.UI.MenuItem("Save this search", () => Later(() => _ = SaveCurrentAsync()), "bookmark");
        save.IsEnabled = !CurrentFilters.IsEmpty;
        menu.Items.Add(save);

        var saved = SavedSearches();
        if (saved.Count > 0)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(new MenuFlyoutItem { Text = "Saved searches", IsEnabled = false });
            foreach (var s in saved)
            {
                var item = UI.UI.MenuItem(s.Name, () => LoadSaved(s));
                ToolTipService.SetToolTip(item, s.Prompt);
                menu.Items.Add(item);
            }
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(UI.UI.MenuItem("Search tips", () => Later(() => _ = SearchHelp.ShowAsync()), "questionmark.circle"));
    }

    /// <summary>Runs after the menu has closed, so a dialog never opens from a
    /// flyout that's being torn down.</summary>
    private static void Later(Action action) => MainWindow.Current.DispatcherQueue.TryEnqueue(() => action());

    private async Task SaveCurrentAsync()
    {
        var name = await Dialogs.PromptAsync("Save search", "Name", "Save", SuggestName(),
            "Saves the keywords, filters and sort so you can re-run it later.");
        if (name is null) return;
        var prompt = CurrentFilters.PromptText();
        if (Store.GetSavedSearch(name) is { } existing)
        {
            // Alerts for an edited search start over: what the old search saw
            // says nothing about the new one.
            var edited = existing.Prompt != prompt;
            if (edited) SavedSearchAlerts.ResetBaseline(existing);
            existing.Prompt = prompt;
            existing.SortColumn = _active.SortColumn.RawValue();
            existing.SortDirection = _active.SortDirection.RawValue();
            existing.SavedAt = DateTimeOffset.Now;
            if (edited && existing.AlertsEnabled) _ = TakeAlertBaselineAsync(existing);
        }
        else
        {
            Store.Insert(new SavedSearch(name, prompt, _active.SortColumn.RawValue(), _active.SortDirection.RawValue()));
        }
        Store.TrySave();
        MainWindow.Current.Announce($"Saved search {name}");
        if (!_hasSearched) RenderContent();
    }
}

/// <summary>A one-shot UI-thread timer that can be stopped before it fires.</summary>
internal sealed class DispatcherQueueTimerHolder
{
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _timer;

    public DispatcherQueueTimerHolder(TimeSpan delay, Action action)
    {
        _timer = MainWindow.Current.DispatcherQueue.CreateTimer();
        _timer.Interval = delay;
        _timer.IsRepeating = false;
        _timer.Tick += (_, _) => action();
        _timer.Start();
    }

    public void Stop() => _timer.Stop();
}
