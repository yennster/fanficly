using Fanficly.App.UI;
using Fanficly.App.Views.Shared;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Account;

/// <summary>Texts for the states of a <see cref="PagedWorksList"/>.</summary>
internal sealed record PagedWorksTexts(
    string Loading,
    string ErrorTitle,
    string EmptySymbol,
    string EmptyTitle,
    string EmptyMessage,
    string FilteredMessage);

/// <summary>
/// A live-fetched, paginated list of AO3 works with infinite scroll — the body
/// shared by AuthorWorksView and BookmarksView: a loading state, an error
/// state, "no works", "everything is filtered out" (hidden works and the
/// Mature/Explicit filter), and <see cref="WorkRow"/> rows that pull the next
/// page as the end comes into view.
/// </summary>
internal sealed class PagedWorksList
{
    private readonly Func<int, CancellationToken, Task<AO3SearchResults>> _fetch;
    private readonly PagedWorksTexts _texts;
    private readonly VirtualList<AO3WorkSummary> _list;
    private readonly Grid _host = new();
    private readonly List<AO3WorkSummary> _works = [];
    private CancellationTokenSource? _cts;
    private int _currentPage = 1;
    private int _totalPages = 1;
    private bool _isLoadingMore;
    private string? _errorMessage;
    private string? _loadMoreError;
    private List<int> _shownIds = [];

    public PagedWorksList(Func<int, CancellationToken, Task<AO3SearchResults>> fetch, PagedWorksTexts texts, string automationId, string listName)
    {
        _fetch = fetch;
        _texts = texts;
        _list = new VirtualList<AO3WorkSummary>((work, _) => WorkRow.Build(work), spacing: 2, maxWidth: 980)
        {
            LoadMore = LoadMoreAsync,
        };
        _list.Element.Id(automationId);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_list.Element, listName);
    }

    /// <summary>The element to put on screen.</summary>
    public FrameworkElement Element => _host;

    public bool IsLoading { get; private set; }

    /// <summary>Raised when <see cref="IsLoading"/> changes (the toolbar's refresh button).</summary>
    public event Action? LoadingChanged;

    /// <summary>The ids of every work fetched so far (seeds an author follow).</summary>
    public IReadOnlyList<int> WorkIds => _works.Select(w => w.Id).ToList();

    public bool HasWorks => _works.Count > 0;

    /// <summary>Loads page 1 unless works are already on screen (returning from a
    /// work must not refetch).</summary>
    public async Task LoadFirstAsync()
    {
        if (_works.Count > 0 || IsLoading) { Render(); return; }
        _cts?.Cancel();
        var cts = _cts = new CancellationTokenSource();
        SetLoading(true);
        _errorMessage = null;
        _loadMoreError = null;
        Render();
        try
        {
            var result = await _fetch(1, cts.Token);
            if (cts.IsCancellationRequested) return;
            _works.Clear();
            AppendUnique(result.Works);
            _currentPage = result.CurrentPage;
            _totalPages = result.TotalPages;
        }
        catch (OperationCanceledException) when (cts.IsCancellationRequested)
        {
            // A torn-down load is benign, not a failure: don't surface it.
            return;
        }
        catch (Exception e)
        {
            if (cts.IsCancellationRequested) return;
            _errorMessage = e.Message;
        }
        finally
        {
            if (_cts == cts) SetLoading(false);
        }
        Render(force: true);
    }

    /// <summary>Drops everything and loads page 1 again (the toolbar's Refresh).</summary>
    public Task RefreshAsync()
    {
        Clear();
        return LoadFirstAsync();
    }

    /// <summary>Forgets the works (sign-out, a different account).</summary>
    public void Clear()
    {
        _cts?.Cancel();
        _cts = null;
        SetLoading(false);
        _works.Clear();
        _currentPage = 1;
        _totalPages = 1;
        _errorMessage = null;
        _loadMoreError = null;
        _shownIds = [];
        _list.Reset([]);
    }

    public void Cancel()
    {
        _cts?.Cancel();
    }

    private void SetLoading(bool value)
    {
        if (IsLoading == value) return;
        IsLoading = value;
        LoadingChanged?.Invoke();
    }

    private void AppendUnique(IEnumerable<AO3WorkSummary> works)
    {
        var existing = _works.Select(w => w.Id).ToHashSet();
        foreach (var w in works)
            if (existing.Add(w.Id)) _works.Add(w);
    }

    /// <summary>Re-applies the content filter (it can change in Settings while
    /// this screen is underneath) and picks the state to show.</summary>
    public void Render(bool force = false)
    {
        FrameworkElement content;
        if (IsLoading && _works.Count == 0)
        {
            content = UI.UI.Loading(_texts.Loading);
        }
        else if (_errorMessage is not null && _works.Count == 0)
        {
            content = UI.UI.EmptyState("exclamationmark.triangle", _texts.ErrorTitle, _errorMessage,
                                       "Retry", () => _ = LoadFirstAsync());
        }
        else if (_works.Count == 0)
        {
            content = UI.UI.EmptyState(_texts.EmptySymbol, _texts.EmptyTitle, _texts.EmptyMessage);
        }
        else
        {
            var visible = AccountKit.Visible(_works);
            if (visible.Count == 0)
            {
                content = UI.UI.EmptyState("eye.slash", "Nothing to show", _texts.FilteredMessage);
                _shownIds = [];
            }
            else
            {
                var ids = visible.Select(w => w.Id).ToList();
                if (force || !ids.SequenceEqual(_shownIds))
                {
                    // Appending keeps the scroll position; anything else resets.
                    if (_shownIds.Count > 0 && ids.Count >= _shownIds.Count && ids.Take(_shownIds.Count).SequenceEqual(_shownIds))
                        _list.Append(visible.Skip(_shownIds.Count));
                    else
                        _list.Reset(visible);
                    _shownIds = ids;
                }
                _list.HasMore = _currentPage < _totalPages;
                UpdateFooter();
                content = _list.Element;
            }
        }
        if (_host.Children.Count != 1 || _host.Children[0] != content)
        {
            _host.Children.Clear();
            _host.Children.Add(content);
        }
    }

    private void UpdateFooter()
    {
        if (_isLoadingMore)
            _list.Footer = new ProgressRing { IsActive = true, Width = 24, Height = 24, Margin = new Thickness(0, 8, 0, 8) }
                .Also(r => Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(r, "Loading more"));
        else if (_loadMoreError is not null)
            _list.Footer = UI.UI.VStack(6,
                    UI.UI.Secondary(_loadMoreError, Theme.Style.Footnote).Also(t => t.TextAlignment = TextAlignment.Center),
                    UI.UI.Button("Retry", () => _ = LoadMoreAsync()).Also(b => b.HorizontalAlignment = HorizontalAlignment.Center))
                .Also(s => { s.HorizontalAlignment = HorizontalAlignment.Center; s.Margin = new Thickness(0, 8, 0, 8); });
        else
            _list.Footer = null;
    }

    /// <summary>Infinite scroll: the next page, appended without duplicates. A
    /// page whose works are all filtered out loads the one after (up to three),
    /// so the list can't stall with nothing new to scroll to.</summary>
    private async Task LoadMoreAsync()
    {
        if (_isLoadingMore || IsLoading || _currentPage >= _totalPages) return;
        var cts = _cts ??= new CancellationTokenSource();
        _isLoadingMore = true;
        _loadMoreError = null;
        UpdateFooter();
        try
        {
            for (var attempt = 0; attempt < 3 && _currentPage < _totalPages; attempt++)
            {
                var before = AccountKit.Visible(_works).Count;
                var result = await _fetch(_currentPage + 1, cts.Token);
                if (cts.IsCancellationRequested) return;
                AppendUnique(result.Works);
                _currentPage = result.CurrentPage;
                _totalPages = result.TotalPages;
                if (AccountKit.Visible(_works).Count > before) break;
            }
        }
        catch (Exception) when (cts.IsCancellationRequested)
        {
            return;
        }
        catch (Exception e)
        {
            _loadMoreError = $"Couldn't load more: {e.Message}";
        }
        finally
        {
            _isLoadingMore = false;
        }
        Render();
        UpdateFooter();
    }
}
