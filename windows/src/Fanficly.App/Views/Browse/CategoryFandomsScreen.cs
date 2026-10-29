using System.Globalization;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Fanficly.App.Views.Browse;

/// <summary>
/// One media category's fandoms (CategoryFandomsView): AO3's full live list
/// from <c>/media/&lt;category&gt;/fandoms</c>, searchable from the box at the
/// top, with each fandom's work count. When the live list can't load
/// (offline, AO3 down) it falls back to the category's curated seed under a
/// warning. Picking a fandom opens its works.
/// </summary>
internal sealed class CategoryFandomsScreen(FandomCategory category) : Screen
{
    private readonly CancellationTokenSource _cts = new();
    private IReadOnlyList<BrowseFandom> _live = [];
    private bool _isLoading;
    private string? _errorMessage;
    private string _query = "";

    private Grid _body = null!;
    private TextBox _search = null!;
    private VirtualList<BrowseFandom> _list = null!;
    private TextBlock _countHeader = null!;
    private FrameworkElement _errorNote = null!;
    private TextBlock _errorText = null!;
    private FrameworkElement? _loading;

    protected override FrameworkElement Build()
    {
        Title = category.Name;

        _search = new TextBox
        {
            PlaceholderText = "Search fandoms",
            Margin = new Thickness(24, 4, 24, 8),
            MaxWidth = 900,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetName(_search, "Search fandoms");
        AutomationProperties.SetAutomationId(_search, "browse.fandomSearch");
        _search.TextChanged += (_, _) =>
        {
            _query = _search.Text;
            ShowList();
        };
        _search.PreviewKeyDown += (_, e) =>
        {
            // ↓ / Enter from the box moves into the list, like tabbing.
            if (e.Key is VirtualKey.Down or VirtualKey.Enter && _list.Items.Count > 0)
            {
                e.Handled = FocusManager.TryMoveFocus(FocusNavigationDirection.Next, new FindNextElementOptions { SearchRoot = _body.XamlRoot.Content });
            }
            else if (e.Key == VirtualKey.Escape && _search.Text.Length > 0)
            {
                e.Handled = true;
                _search.Text = "";
            }
        };

        _countHeader = UI.UI.Secondary("", Theme.Style.Footnote).A11yHeading();
        _countHeader.Margin = new Thickness(4, 10, 0, 4);
        _errorText = UI.UI.Text("", Theme.Style.Caption, Theme.Warning);
        _errorNote = UI.UI.Card(UI.UI.HStack(8,
            UI.UI.Icon("exclamationmark.triangle.fill", 13, Theme.Warning).Also(i => i.VerticalAlignment = VerticalAlignment.Center),
            _errorText), padding: 12);
        _errorNote.Margin = new Thickness(0, 4, 0, 4);

        _list = new VirtualList<BrowseFandom>(FandomRow, spacing: 0, padding: new Thickness(24, 0, 24, 24), maxWidth: 900)
        {
            Header = UI.UI.VStack(0, _errorNote, _countHeader),
        };
        _list.HasMore = false;
        _list.Element.XYFocusKeyboardNavigation = XYFocusKeyboardNavigationMode.Enabled;
        AutomationProperties.SetName(_list.Element, $"{category.Name} fandoms");
        AutomationProperties.SetAutomationId(_list.Element, "browse.fandoms");

        _body = new Grid();
        var root = UI.UI.Grid("*", "Auto,*");
        root.Children.Add(_search.Row(0));
        root.Children.Add(_body.Row(1));

        Render();
        _ = LoadLiveAsync();
        return root;
    }

    public override void OnRemoved() => _cts.Cancel();

    private IReadOnlyList<BrowseFandom> Source => BrowseModels.FandomSource(_live, _errorMessage is not null, category);

    private void Render()
    {
        _body.Children.Clear();
        if (Source.Count == 0 && _isLoading)
        {
            _loading ??= UI.UI.Loading("Loading fandoms…");
            _body.Children.Add(_loading);
            return;
        }
        _body.Children.Add(_list.Element);
        ShowList();
    }

    private void ShowList()
    {
        if (_list is null) return;
        var displayed = BrowseModels.FilterFandoms(Source, _query);
        _countHeader.Text = BrowseModels.FandomHeader(displayed.Count, _live.Count); // not upper-cased: textCase(nil)
        _errorNote.Visibility = _errorMessage is null ? Visibility.Collapsed : Visibility.Visible;
        _errorText.Text = _errorMessage ?? "";
        _list.Reset(displayed);
    }

    private UIElement FandomRow(BrowseFandom fandom, int index)
    {
        var name = UI.UI.Text(fandom.DisplayName);
        name.VerticalAlignment = VerticalAlignment.Center;
        var content = UI.UI.Grid("*,Auto", columnSpacing: 12);
        content.Children.Add(name.Col(0));
        string accessible = fandom.DisplayName;
        if (fandom.WorkCount is { } count)
        {
            var works = count.ToString("N0", CultureInfo.CurrentCulture);
            content.Children.Add(UI.UI.Caption(works).Also(c => c.VerticalAlignment = VerticalAlignment.Center).Col(1));
            accessible = $"{fandom.DisplayName}, {works} {(count == 1 ? "work" : "works")}";
        }
        var row = UI.UI.NavRow(content, () => Open(fandom), accessible);
        AutomationProperties.SetAutomationId(row, $"browse.fandom.{index}");
        return UI.UI.VStack(0, row, UI.UI.Divider(14));
    }

    private void Open(BrowseFandom fandom) =>
        Navigator.Push(new FilteredWorksScreen(BrowseModels.FiltersForFandom(fandom), fandom.DisplayName, subject: fandom.CanonicalName));

    private async Task LoadLiveAsync()
    {
        if (_live.Count > 0) return;
        _isLoading = true;
        Render();
        try
        {
            _live = await AppHost.Client.FetchFandomsInCategoryAsync(category.AO3CanonicalName, _cts.Token);
        }
        catch (OperationCanceledException) when (_cts.IsCancellationRequested)
        {
            return;
        }
        catch (Exception e)
        {
            _errorMessage = BrowseModels.FandomLoadError(e);
            AppHost.Log($"Browse: fandoms in {category.Name} failed: {e.Message}");
        }
        finally
        {
            _isLoading = false;
        }
        Render();
        MainWindow.Current.Announce(_errorMessage ?? BrowseModels.FandomHeader(BrowseModels.FilterFandoms(Source, _query).Count, _live.Count));
    }
}
