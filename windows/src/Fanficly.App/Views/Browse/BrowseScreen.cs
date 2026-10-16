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
/// The Browse tab (BrowseView): the saved filters (newest first; open one to
/// run it, Delete / right-click to remove it) above AO3's ten media
/// categories. The categories are a grid of cards that reflows with the window
/// width — arrow keys and a gamepad move between them, Enter / A opens one.
/// </summary>
internal sealed class BrowseScreen : Screen
{
    private const double MinCardWidth = 230;
    private const double CardGap = 12;
    private const double CardHeight = 84;

    private GridView _grid = null!;
    private StackPanel _savedFilters = null!;
    private TextBlock _categoriesHeader = null!;
    private LibraryChanges? _changes;

    protected override FrameworkElement Build()
    {
        Title = "Browse";

        _savedFilters = new StackPanel { Spacing = 2 };
        _categoriesHeader = UI.UI.SectionHeader("Categories");
        var header = UI.UI.VStack(0, _savedFilters, _categoriesHeader);
        header.Margin = new Thickness(0, 0, CardGap, 6);

        _grid = new GridView
        {
            SelectionMode = ListViewSelectionMode.None,
            IsItemClickEnabled = true,
            Padding = new Thickness(24, 4, 24 - CardGap, 24),
            Header = header,
            IsSwipeEnabled = false,
            XYFocusKeyboardNavigation = XYFocusKeyboardNavigationMode.Enabled,
        };
        AutomationProperties.SetName(_grid, "Categories");
        AutomationProperties.SetAutomationId(_grid, "browse.categories");
        foreach (var category in FandomCatalog.All) _grid.Items.Add(CategoryItem(category));
        _grid.ItemClick += (_, e) =>
        {
            var category = e.ClickedItem switch
            {
                FrameworkElement { Tag: FandomCategory c } => c,
                _ => null,
            };
            if (category is not null) Navigator.Push(new CategoryFandomsScreen(category));
        };
        _grid.SizeChanged += (_, _) => LayoutCards();
        _grid.Loaded += (_, _) => LayoutCards();

        RefreshSavedFilters();
        _changes = new LibraryChanges(AppHost.Library, LibraryEntityKinds.SavedFilters, RefreshSavedFilters);
        return _grid;
    }

    public override void OnAppearing()
    {
        if (IsBuilt) RefreshSavedFilters();
    }

    public override void OnRemoved() => _changes?.Dispose();

    // MARK: - Categories

    private static GridViewItem CategoryItem(FandomCategory category)
    {
        var badge = new Border
        {
            Width = 40,
            Height = 40,
            CornerRadius = new CornerRadius(8),
            Background = Theme.AccentSubtle,
            VerticalAlignment = VerticalAlignment.Center,
            Child = UI.UI.Icon(category.Symbol, 20, Theme.Accent).Center(),
        }.A11yHidden();
        var name = UI.UI.Text(category.Name, Theme.Style.Headline, maxLines: 2);
        name.VerticalAlignment = VerticalAlignment.Center;

        var row = UI.UI.Grid("Auto,*,Auto", columnSpacing: 12);
        row.Children.Add(badge.Col(0));
        row.Children.Add(name.Col(1));
        row.Children.Add(UI.UI.Icon("chevron.right", 12, Theme.TextTertiary).Also(i => i.VerticalAlignment = VerticalAlignment.Center).Col(2));

        var card = new Border
        {
            Child = row,
            Padding = new Thickness(14, 10, 14, 10),
            CornerRadius = new CornerRadius(8),
            Background = Theme.CardBackground,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
            Tag = category,
        };

        var item = new GridViewItem
        {
            Content = card,
            Tag = category,
            Margin = new Thickness(0, 0, CardGap, CardGap),
            Padding = new Thickness(0),
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
        };
        AutomationProperties.SetName(item, category.Name);
        AutomationProperties.SetAutomationId(item, $"browse.category.{category.Id}");
        ToolTipService.SetToolTip(item, category.Name);
        return item;
    }

    /// <summary>Sizes the cards so they fill the row: as many columns of at least
    /// <see cref="MinCardWidth"/> as fit, recomputed on every resize.</summary>
    private void LayoutCards()
    {
        if (_grid.ItemsPanelRoot is not ItemsWrapGrid panel) return;
        var available = _grid.ActualWidth - _grid.Padding.Left - _grid.Padding.Right;
        if (available <= 0) return;
        var columns = Math.Max(1, (int)Math.Floor(available / (MinCardWidth + CardGap)));
        var width = Math.Floor(available / columns);
        if (Math.Abs(panel.ItemWidth - width) > 0.5) panel.ItemWidth = width;
        panel.ItemHeight = CardHeight + CardGap;
        panel.Orientation = Orientation.Horizontal;
    }

    // MARK: - Saved filters

    private void RefreshSavedFilters()
    {
        var saved = AppHost.Library.All<SavedFilter>().OrderByDescending(f => f.SavedAt).ToList();
        _savedFilters.Children.Clear();
        _savedFilters.Visibility = saved.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        // Like the Mac list, "Categories" only gets a heading once there's a
        // saved-filters section above it.
        _categoriesHeader.Visibility = saved.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (saved.Count == 0) return;
        _savedFilters.Children.Add(UI.UI.Section("Saved filters", saved.Select(SavedFilterRow).ToList()));
    }

    private UIElement SavedFilterRow(SavedFilter saved)
    {
        var label = UI.UI.Label("line.3.horizontal.decrease.circle", saved.Name, foreground: null);
        var row = UI.UI.NavRow(label, () => Open(saved), saved.Name);
        AutomationProperties.SetAutomationId(row, $"browse.savedFilter.{saved.Name}");
        AutomationProperties.SetHelpText(row, "Press Delete to remove this saved filter.");
        row.ContextFlyout = UI.UI.Menu(UI.UI.MenuItem("Delete", () => Delete(saved), "trash", isDestructive: true));
        row.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Delete) { e.Handled = true; Delete(saved); }
        };
        return row;
    }

    private void Open(SavedFilter saved) =>
        Navigator.Push(new FilteredWorksScreen(BrowseModels.FiltersForSavedFilter(saved), saved.Name));

    private void Delete(SavedFilter saved)
    {
        AppHost.Library.Delete(saved);
        AppHost.Library.TrySave();
        RefreshSavedFilters();
        MainWindow.Current.Announce($"Deleted {saved.Name}");
        _grid.Focus(FocusState.Programmatic);
    }
}
