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

    private Grid _grid = null!;
    private readonly List<Button> _cards = [];
    private int _columns;
    private StackPanel _savedFilters = null!;
    private TextBlock _categoriesHeader = null!;
    private LibraryChanges? _changes;

    protected override FrameworkElement Build()
    {
        Title = "Browse";

        _savedFilters = new StackPanel { Spacing = 2 };
        _categoriesHeader = UI.UI.SectionHeader("Categories");

        // A plain grid laid out here rather than a GridView: its wrap panel
        // kept the card width from an earlier window size, so in a narrow
        // window the one column of cards stopped short of the edge.
        _grid = new Grid
        {
            ColumnSpacing = CardGap,
            RowSpacing = CardGap,
            XYFocusKeyboardNavigation = XYFocusKeyboardNavigationMode.Enabled,
            TabFocusNavigation = KeyboardNavigationMode.Once,
        };
        AutomationProperties.SetName(_grid, "Categories");
        AutomationProperties.SetAutomationId(_grid, "browse.categories");
        foreach (var category in FandomCatalog.All)
        {
            var card = CategoryCard(category);
            _cards.Add(card);
            _grid.Children.Add(card);
        }
        _grid.SizeChanged += (_, e) => LayoutCards(e.NewSize.Width);

        RefreshSavedFilters();
        _changes = new LibraryChanges(AppHost.Library, LibraryEntityKinds.SavedFilters, RefreshSavedFilters);
        var content = UI.UI.VStack(0, _savedFilters, _categoriesHeader.Margin(0, 0, 0, 6), _grid);
        return UI.UI.Scroll(content);
    }

    public override void OnAppearing()
    {
        if (IsBuilt) RefreshSavedFilters();
    }

    public override void OnRemoved() => _changes?.Dispose();

    // MARK: - Categories

    private Button CategoryCard(FandomCategory category)
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
        row.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(badge.Col(0));
        row.Children.Add(name.Col(1));
        row.Children.Add(UI.UI.Icon("chevron.right", 12, Theme.TextTertiary).Also(i => i.VerticalAlignment = VerticalAlignment.Center).Col(2));

        var card = new Button
        {
            Content = row,
            Padding = new Thickness(14, 10, 14, 10),
            CornerRadius = new CornerRadius(8),
            Background = Theme.CardBackground,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Center,
            MinHeight = CardHeight,
            Tag = category,
        };
        card.Click += (_, _) => Navigator.Push(new CategoryFandomsScreen(category));
        AutomationProperties.SetName(card, category.Name);
        AutomationProperties.SetAutomationId(card, $"browse.category.{category.Id}");
        ToolTipService.SetToolTip(card, category.Name);
        return card;
    }

    /// <summary>Sizes the cards so they fill the row: as many equal columns of
    /// at least <see cref="MinCardWidth"/> as fit, recomputed on every resize.</summary>
    private void LayoutCards(double width)
    {
        if (width <= 0) return;
        var columns = Math.Max(1, (int)Math.Floor((width + CardGap) / (MinCardWidth + CardGap)));
        if (columns == _columns) return;
        _columns = columns;
        _grid.ColumnDefinitions.Clear();
        _grid.RowDefinitions.Clear();
        for (var c = 0; c < columns; c++)
            _grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var rows = (_cards.Count + columns - 1) / columns;
        for (var r = 0; r < rows; r++)
            _grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var i = 0; i < _cards.Count; i++)
        {
            Grid.SetColumn(_cards[i], i % columns);
            Grid.SetRow(_cards[i], i / columns);
        }
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
        var label = UI.UI.Label("line.3.horizontal.decrease.circle", saved.Name, foreground: null, maxLines: UI.UI.LineLimit(1));
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
        LibrarySyncManager.RecordDeletionShared(DeletionKind.Filter, saved.Name);
        AppHost.Library.Delete(saved);
        AppHost.Library.TrySave();
        RefreshSavedFilters();
        MainWindow.Current.Announce($"Deleted {saved.Name}");
        _cards.FirstOrDefault()?.Focus(FocusState.Programmatic);
    }
}
