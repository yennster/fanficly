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

    private Grid _content = null!;
    private VirtualList<AO3WorkSummary> _list = null!;
    private FrameworkElement _applyingOverlay = null!;
    private FrameworkElement? _loadingView;

    public FilteredWorksScreen(AO3SearchFilters filters, string title)
    {
        _filters = filters.Clone();
        Title = title;
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
        var count = BrowseModels.ActiveFilterCount(_filters);
        var button = UI.UI.ToolbarButton(count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
            "Filters", () => _ = ShowFiltersAsync());
        AutomationProperties.SetItemStatus(button, count > 0 ? $"{count} active" : "None");
        AutomationProperties.SetAutomationId(button, "filtered.filters");
        yield return button;
    }

    private async Task ShowFiltersAsync()
    {
        if (await WorkFilterDialog.ShowAsync(_filters) is { } edited) await ApplyFiltersAsync(edited);
    }

    // MARK: - Visible works

    private IReadOnlyList<AO3WorkSummary> Visible(IEnumerable<AO3WorkSummary> works) =>
        ContentFilter.Apply(works, HiddenWorkStore.Ids(AppHost.Library),
            KeyValueStores.Default.GetBool(Core.ContentControl.FilterMatureKey, true));

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
            view = _loadingView ??= UI.UI.Loading("Loading…");
        else if (_errorMessage is not null && !hasWorks)
            view = UI.UI.EmptyState("exclamationmark.triangle", "Couldn't load works", _errorMessage,
                "Try Again", () => _ = ReloadAsync());
        else if (!hasWorks)
            view = UI.UI.EmptyState("magnifyingglass", "No works found",
                "Try adjusting your filters or search terms.", "Filters", () => _ = ShowFiltersAsync());
        else if (_list.Items.Count == 0)
            view = UI.UI.EmptyState("eye.slash", "Nothing to show",
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

    /// <summary>The chips over the results; clicking them opens the filter panel.</summary>
    private void RefreshHeader()
    {
        var chips = BrowseModels.FilterChips(_filters);
        var flow = UI.UI.Flow(6, 6);
        foreach (var chip in chips) flow.Children.Add(UI.UI.Chip(chip, fontSize: 11).A11yHidden());
        flow.Children.Add(UI.UI.Icon("slider.horizontal.3", 11, Theme.Accent).Also(i => i.VerticalAlignment = VerticalAlignment.Center));
        var button = new Button
        {
            Content = flow,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Padding = new Thickness(6, 6, 6, 6),
            Margin = new Thickness(0, 4, 0, 4),
        };
        UI.UI.ApplyKind(button, UI.UI.ButtonKind.Subtle);
        AutomationProperties.SetName(button, $"Active filters: {string.Join(", ", chips)}");
        AutomationProperties.SetHelpText(button, "Opens filter options.");
        AutomationProperties.SetAutomationId(button, "filtered.chips");
        ToolTipService.SetToolTip(button, "Filters");
        button.Click += (_, _) => _ = ShowFiltersAsync();
        _list.Header = button;
        InvalidateChrome();
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
        try
        {
            var result = await AppHost.Client.SearchAsync(_filters, 1, token);
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
            _errorMessage = e.Message;
            AppHost.Log($"Browse: works for {Title} failed: {e.Message}");
            if (announce) MainWindow.Current.Announce($"Couldn't load works. {e.Message}");
        }
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
            }
        }
    }
}
