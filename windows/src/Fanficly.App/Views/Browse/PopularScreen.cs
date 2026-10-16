using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Fanficly.App.Views.Browse;

/// <summary>
/// The Popular tab (PopularView): popular fandoms, ships and characters. Pick a
/// list, pick a tag, and see its works sorted by kudos. The lists are live —
/// ranked from AO3's work counts (<see cref="PopularStore"/>, cached about
/// daily) — and fall back to the curated <see cref="PopularTags"/> seed
/// whenever a list is empty, so the tab is never blank (offline included).
/// </summary>
internal sealed class PopularScreen : Screen
{
    private PopularTagKind _segment = PopularTagKind.Fandom;
    private PopularSnapshot? _snapshot = PopularStore.Cached();
    private bool _refreshing;

    private SelectorBar _selector = null!;
    private StackPanel _rows = null!;
    private ScrollViewer _scroll = null!;

    protected override FrameworkElement Build()
    {
        Title = "Popular";

        _selector = new SelectorBar { Margin = new Thickness(20, 0, 20, 4) };
        AutomationProperties.SetName(_selector, "Category");
        foreach (var kind in PopularTagKinds.All)
        {
            var item = new SelectorBarItem
            {
                Text = kind.Title(),
                Icon = Symbols.Icon(kind.Symbol()),
                Tag = kind,
                IsSelected = kind == _segment,
            };
            AutomationProperties.SetAutomationId(item, $"popular.{kind.Title().ToLowerInvariant()}");
            _selector.Items.Add(item);
        }
        _selector.SelectionChanged += (_, _) =>
        {
            if (_selector.SelectedItem is { Tag: PopularTagKind kind } && kind != _segment)
            {
                _segment = kind;
                RenderList(scrollToTop: true);
            }
        };

        _rows = new StackPanel { XYFocusKeyboardNavigation = XYFocusKeyboardNavigationMode.Enabled };
        var card = new Border
        {
            Child = _rows,
            CornerRadius = new CornerRadius(8),
            Background = Theme.CardBackground,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
            MaxWidth = 900,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        _scroll = UI.UI.Scroll(card);
        AutomationProperties.SetAutomationId(_scroll, "popular.list");

        var root = UI.UI.Grid("*", "Auto,*");
        root.Children.Add(_selector.Row(0));
        root.Children.Add(_scroll.Row(1));
        RenderList(scrollToTop: false);
        return root;
    }

    public override void OnAppearing()
    {
        // Refresh in the background (at most once a day); the cached / curated
        // lists show at once and swap to live data when the fetch lands.
        _ = RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        if (_refreshing) return;
        _refreshing = true;
        try
        {
            var fresh = await PopularStore.RefreshIfStaleAsync(AppHost.Client);
            if (fresh is not null && !ReferenceEquals(fresh, _snapshot) && fresh != _snapshot)
            {
                _snapshot = fresh;
                if (IsBuilt) RenderList(scrollToTop: false);
            }
        }
        catch (Exception e)
        {
            AppHost.Log($"Popular: refresh failed: {e.Message}");
        }
        finally
        {
            _refreshing = false;
        }
    }

    private void RenderList(bool scrollToTop)
    {
        var names = PopularStore.Names(_snapshot, _segment);
        _rows.Children.Clear();
        AutomationProperties.SetName(_scroll, $"Popular {_segment.Title().ToLowerInvariant()}");
        for (var i = 0; i < names.Count; i++)
        {
            if (i > 0) _rows.Children.Add(UI.UI.Divider(48));
            _rows.Children.Add(TagRow(new PopularTag(_segment, names[i]), i));
        }
        if (scrollToTop) _scroll.ChangeView(null, 0, null, disableAnimation: true);
    }

    private static UIElement TagRow(PopularTag tag, int index)
    {
        var icon = UI.UI.Icon(tag.Symbol, 16, Theme.Accent);
        icon.Width = 22;
        icon.VerticalAlignment = VerticalAlignment.Center;
        var name = UI.UI.Text(tag.DisplayName);
        name.VerticalAlignment = VerticalAlignment.Center;
        var content = UI.UI.HStack(12, icon, name);
        var row = UI.UI.NavRow(content, () => Routes.OpenFilteredWorks(tag.Filters(), tag.Name), tag.DisplayName);
        AutomationProperties.SetAutomationId(row, $"popular.tag.{index}");
        if (tag.DisplayName != tag.Name) ToolTipService.SetToolTip(row, tag.Name);
        return row;
    }
}
