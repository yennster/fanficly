using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.App.Views.Shared;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Browse;

/// <summary>
/// Works matching a set of filters under a title (FandomWorksView): a fandom
/// from Browse, a saved filter, a popular tag, or any tag link. Results load a
/// page at a time as you scroll; the chips over the list (and the toolbar's
/// Filters button) open the filter panel. Hidden works and — unless turned off
/// in Settings — Mature/Explicit works are left out.
/// </summary>
internal sealed class FilteredWorksScreen : Screen
{
    private AO3SearchFilters _filters;
    private readonly List<AO3WorkSummary> _works = [];
    private int _currentPage = 1;
    private int _totalPages = 1;
    private bool _isLoading;
    private bool _isLoadingMore;
    private string? _errorMessage;
    private string? _loadMoreError;
    private CancellationTokenSource _cts = new();
    private bool _slowNoteVisible;
    private Search.DispatcherQueueTimerHolder? _slowTimer;

    /// <summary>When the slow note and its Cancel button appear.</summary>
    private static readonly TimeSpan SlowNoteDelay = TimeSpan.FromSeconds(10);
    /// <summary>The most a first page may take, retries included, before the
    /// screen stops waiting and says AO3 isn't answering (Windows only: a
    /// struggling AO3 can otherwise keep the spinner up for minutes).</summary>
    private static readonly TimeSpan FirstPageDeadline = TimeSpan.FromSeconds(90);

    private Grid _content = null!;
    private VirtualList<AO3WorkSummary> _list = null!;
    private FrameworkElement _applyingOverlay = null!;

    /// <summary>The tag this screen is about (a fandom, ship, character or
    /// tag); the title says it, so it has no removable chip.</summary>
    private readonly string? _subject;

    public FilteredWorksScreen(AO3SearchFilters filters, string title, string? subject = null)
    {
        _filters = filters.Clone();
        Title = title;
        _subject = subject;
    }

    protected override FrameworkElement Build()
    {
        _list = new VirtualList<AO3WorkSummary>(
            (work, _) => UI.UI.VStack(0, WorkRow.Build(work), UI.UI.Divider(14)),
            spacing: 0, padding: new Thickness(16, 0, 16, 24), maxWidth: 1000)
        {
            LoadMore = LoadMoreAsync,
            HasMore = false,
        };
        AutomationProperties.SetName(_list.Element, $"{Title} works");
        AutomationProperties.SetAutomationId(_list.Element, "filtered.results");

        _applyingOverlay = UI.UI.VStack(10,
            new ProgressRing { IsActive = true, Width = 28, Height = 28 },
            UI.UI.Secondary("Applying filters…", Theme.Style.Callout));
        _applyingOverlay.HorizontalAlignment = HorizontalAlignment.Center;
        _applyingOverlay.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetLiveSetting(_applyingOverlay, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);

        _content = new Grid();
        var root = new Grid();
        root.Children.Add(_content);
        root.Children.Add(_applyingOverlay);

        RefreshHeader();
        Render();
        // Initial load. Coming back from a work doesn't refetch (the list and
        // its scroll position stay); changing filters always does.
        _ = ReloadAsync();
        return root;
    }

    public override void OnAppearing()
    {
        // Hidden works and the Mature/Explicit setting may have changed while a
        // work was open on top of this list.
        if (IsBuilt) RefreshVisible();
    }

    public override void OnRemoved() => _cts.Cancel();

    // MARK: - Toolbar

    public override IEnumerable<ICommandBarElement> PrimaryCommands()
    {
        var count = BrowseModels.ActiveFilterCount(_filters, _subject);
        var button = UI.UI.ToolbarButton(count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
            "Filters", () => _ = ShowFiltersAsync());
        AutomationProperties.SetItemStatus(button, count > 0 ? $"{count} active" : "None");
        AutomationProperties.SetAutomationId(button, "filtered.filters");
        yield return button;
    }

    private async Task ShowFiltersAsync()
    {
        if (await Search.WorkFilterSheet.ShowAsync(_filters) is { } edited) await ApplyFiltersAsync(edited);
    }

    // MARK: - Visible works

    /// <summary>Works minus hidden ones, blocked tags and authors (except the
    /// ones being browsed, so a blocked tag's chip still opens its works) and
    /// (optionally) Mature/Explicit-rated ones.</summary>
    private IReadOnlyList<AO3WorkSummary> Visible(IEnumerable<AO3WorkSummary> works) =>
        ContentFilter.Apply(works, HiddenWorkStore.Ids(AppHost.Library),
            KeyValueStores.Default.GetBool(Core.ContentControl.FilterMatureKey, true),
            Blocklist.From(AppHost.Library).Lifting(_filters));

    private void RefreshVisible()
    {
        var visible = Visible(_works);
        if (!visible.Select(w => w.Id).SequenceEqual(_list.Items.Select(w => w.Id)))
        {
            // Swap the rows in place (keeps the scroll position, unlike Reset).
            _list.Items.Clear();
            _list.Items.AddRange(visible);
            _list.Refresh();
        }
        Render();
    }

    // MARK: - States

    private void Render()
    {
        var hasWorks = _works.Count > 0;
        UIElement view;
        if (_isLoading && !hasWorks)
            view = LoadingView();
        else if (_errorMessage is not null && !hasWorks)
            view = UI.UI.EmptyState("exclamationmark.triangle", "Couldn't load works", _errorMessage,
                "Try Again", () => _ = ReloadAsync());
        else if (!hasWorks)
            view = WithChips(UI.UI.EmptyState("magnifyingglass", "No works found",
                BrowseModels.FilterChips(_filters, _subject).Count == 0 ? "Try adjusting your filters or search terms." : "Try removing a filter.",
                "Filters", () => _ = ShowFiltersAsync()));
        else if (_list.Items.Count == 0)
            // Rows are what ask for the next page, so offer it here.
            view = _currentPage < _totalPages && !_isLoadingMore
                ? UI.UI.EmptyState("eye.slash", "Nothing to show",
                    "Every match so far is hidden or filtered out by your content settings.",
                    "Load more results", () => _ = LoadMoreAsync())
                : UI.UI.EmptyState("eye.slash", "Nothing to show",
                    "Every match is hidden or filtered out by your content settings.");
        else
            view = _list.Element;
        // Leave the list in the tree when it's already showing, so its scroll
        // position survives a visit to a work.
        if (_content.Children.Count != 1 || _content.Children[0] != view)
        {
            _content.Children.Clear();
            _content.Children.Add(view);
        }

        // Re-filtering with results already showing: dim the list and spin so
        // it's clear the search is running.
        var applying = _isLoading && hasWorks;
        _applyingOverlay.Visibility = applying ? Visibility.Visible : Visibility.Collapsed;
        _list.Element.Opacity = applying ? 0.35 : 1;
        _list.Element.IsHitTestVisible = !applying;
        RenderFooter();
    }

    /// <summary>An empty state under the chips, which say which filters left
    /// nothing and remove them (#157).</summary>
    private FrameworkElement WithChips(FrameworkElement emptyState)
    {
        var header = BuildHeader();
        header.Margin = new Thickness(16, 8, 16, 0);
        var grid = UI.UI.Grid(rows: "Auto,*");
        grid.Children.Add(header);
        Grid.SetRow(emptyState, 1);
        grid.Children.Add(emptyState);
        return grid;
    }

    /// <summary>The spinner, plus a note and a way out once AO3 is clearly slow.</summary>
    private FrameworkElement LoadingView()
    {
        var stack = (StackPanel)UI.UI.Loading("Loading…");
        if (_slowNoteVisible)
        {
            var cancel = UI.UI.Button("Cancel", StopLoading);
            cancel.HorizontalAlignment = HorizontalAlignment.Center;
            AutomationProperties.SetAutomationId(cancel, "filtered.cancel");
            AutomationProperties.SetHelpText(cancel, "Stops loading these works");
            stack.Children.Add(UI.UI.VStack(10,
                UI.UI.Secondary("AO3 is slow right now. Big fandoms can take a minute.", Theme.Style.Footnote)
                    .Also(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.TextAlignment = TextAlignment.Center; }),
                cancel));
        }
        stack.Padding = new Thickness(16);
        return stack;
    }

    private void StopLoading()
    {
        NewGeneration();
        _isLoading = false;
        _errorMessage = "Stopped. AO3 is slow right now; try again in a minute.";
        MainWindow.Current.Announce("Stopped loading");
        Render();
    }

    private void RenderFooter()
    {
        if (_isLoadingMore)
        {
            _list.Footer = new ProgressRing { IsActive = true, Width = 22, Height = 22, Margin = new Thickness(0, 12, 0, 12) }
                .A11y("Loading more works");
        }
        else if (_loadMoreError is not null)
        {
            var retry = UI.UI.Button("Try Again", () => _ = LoadMoreAsync());
            var footer = UI.UI.VStack(6, UI.UI.Secondary("Couldn't load more works.", Theme.Style.Footnote), retry);
            footer.HorizontalAlignment = HorizontalAlignment.Center;
            footer.Margin = new Thickness(0, 12, 0, 12);
            _list.Footer = footer;
        }
        else
        {
            _list.Footer = null;
        }
    }

    /// <summary>The chips over the results.</summary>
    private void RefreshHeader()
    {
        _list.Header = BuildHeader();
        InvalidateChrome();
    }

    /// <summary>The sort, which opens the filter panel, then every active filter
    /// as a removable chip, built like Search's so a saved filter's fields all
    /// show and read the same (#157). Removing one loads again.</summary>
    private FrameworkElement BuildHeader()
    {
        var sortLabel = BrowseModels.SortLabel(_filters);
        var sort = new Button
        {
            Content = UI.UI.HStack(6,
                new TextBlock { Text = sortLabel, FontSize = 12, Foreground = Theme.Accent, VerticalAlignment = VerticalAlignment.Center },
                UI.UI.Icon("slider.horizontal.3", 11, Theme.Accent).Also(i => i.VerticalAlignment = VerticalAlignment.Center)),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(8, 3, 8, 4),
            MinHeight = 0,
            MinWidth = 0,
        };
        UI.UI.ApplyKind(sort, UI.UI.ButtonKind.Subtle);
        sort.BorderBrush = Theme.CardStroke;
        sort.BorderThickness = new Thickness(1);
        AutomationProperties.SetName(sort, $"Sorted by {_filters.SortColumn.DisplayName()}, {(_filters.SortDirection == SortDirection.Asc ? "ascending" : "descending")}. Filters");
        AutomationProperties.SetHelpText(sort, "Opens filter options.");
        AutomationProperties.SetAutomationId(sort, "filtered.chips");
        ToolTipService.SetToolTip(sort, "Filters");
        sort.Click += (_, _) => _ = ShowFiltersAsync();

        var flow = UI.UI.Flow(6, 6);
        flow.Children.Add(sort);
        foreach (var chip in BrowseModels.FilterChips(_filters, _subject))
            flow.Children.Add(Search.SearchChips.RemovableChip(chip, hasSearched: true, () => RemoveChip(chip), "filtered.chip"));
        flow.Margin = new Thickness(0, 8, 0, 8);
        return flow;
    }

    private void RemoveChip(ActiveChip chip)
    {
        if (_isLoading) return;
        var edited = _filters.Clone();
        chip.Remove(edited);
        _ = ApplyFiltersAsync(edited);
    }

    // MARK: - Loading

    /// <summary>Resolves typed tags to AO3's canonical names, then searches.</summary>
    private async Task ApplyFiltersAsync(AO3SearchFilters edited)
    {
        _filters = edited;
        RefreshHeader();
        _isLoading = true;
        _errorMessage = null;
        Render();
        var token = NewGeneration();
        MainWindow.Current.Announce("Applying filters…");
        // The fandom is already AO3-canonical (picked from AO3's own lists), so
        // it isn't resolved again — fewer throttled round-trips.
        try
        {
            _filters = await TagResolver.ResolveAsync(_filters, AppHost.Client, resolveFandoms: false, token);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            return;
        }
        RefreshHeader();
        await ReloadAsync(announce: true);
    }

    private CancellationToken NewGeneration()
    {
        _cts.Cancel();
        _cts = new CancellationTokenSource();
        _slowTimer?.Stop();
        _slowNoteVisible = false;
        return _cts.Token;
    }

    /// <summary>Unconditional page-1 fetch. The old results stay up (dimmed)
    /// until the new ones arrive.</summary>
    private async Task ReloadAsync(bool announce = false)
    {
        var token = NewGeneration();
        _isLoading = true;
        _isLoadingMore = false;
        _errorMessage = null;
        Render();
        _slowTimer = new Search.DispatcherQueueTimerHolder(SlowNoteDelay, () =>
        {
            if (token.IsCancellationRequested || !_isLoading) return;
            _slowNoteVisible = true;
            Render();
        });
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(FirstPageDeadline);
        try
        {
            var result = await AppHost.Client.SearchAsync(_filters, 1, deadline.Token);
            if (token.IsCancellationRequested) return;
            _works.Clear();
            _works.AddRange(result.Works);
            _currentPage = result.CurrentPage;
            _totalPages = result.TotalPages;
            _loadMoreError = null;
            _list.Reset(Visible(_works));
            _list.HasMore = _currentPage < _totalPages;
            if (announce) MainWindow.Current.Announce(_list.Items.Count == 0 ? "No works found" : $"{_list.Items.Count} works");
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            return;
        }
        catch (Exception e)
        {
            _errorMessage = deadline.IsCancellationRequested
                ? "AO3 isn't responding right now. This is on AO3's side; try again in a minute."
                : e.Message;
            AppHost.Log($"Browse: works for {Title} failed: {e.Message}");
            if (announce) MainWindow.Current.Announce($"Couldn't load works. {_errorMessage}");
        }
        _slowTimer?.Stop();
        _slowNoteVisible = false;
        _isLoading = false;
        Render();
    }

    /// <summary>The next page, appended. Pages whose every work is hidden are
    /// skipped through (a few at most), so scrolling never stalls on them.</summary>
    private async Task LoadMoreAsync()
    {
        if (_isLoadingMore || _isLoading || _currentPage >= _totalPages) return;
        var token = _cts.Token;
        _isLoadingMore = true;
        _loadMoreError = null;
        RenderFooter();
        Render();
        try
        {
            for (var attempt = 0; attempt < 3 && _currentPage < _totalPages; attempt++)
            {
                var result = await AppHost.Client.SearchAsync(_filters, _currentPage + 1, token);
                if (token.IsCancellationRequested) return;
                var existing = _works.Select(w => w.Id).ToHashSet();
                var fresh = result.Works.Where(w => !existing.Contains(w.Id)).ToList();
                _works.AddRange(fresh);
                _currentPage = Math.Max(result.CurrentPage, _currentPage + 1);
                _totalPages = result.TotalPages;
                var visible = Visible(fresh);
                _list.Append(visible);
                if (visible.Count > 0) break;
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            return;
        }
        catch (Exception e)
        {
            _loadMoreError = e.Message;
            AppHost.Log($"Browse: next page for {Title} failed: {e.Message}");
        }
        finally
        {
            if (!token.IsCancellationRequested)
            {
                _isLoadingMore = false;
                _list.HasMore = _currentPage < _totalPages && _loadMoreError is null;
                RenderFooter();
                // Swaps "Nothing to show" for the list once a page adds rows.
                Render();
            }
        }
    }
}
