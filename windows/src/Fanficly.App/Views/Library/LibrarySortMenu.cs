using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Fanficly.App.Views.Library;

/// <summary>
/// The sort control for saved-story lists (LibrarySortMenu). It lives in the
/// content — first in the Library's filter row, atop a folder's list — rather
/// than the toolbar, and is tinted while a non-default sort is active so a
/// custom order is never a surprise. Picking a new key starts it in its
/// natural direction (newest, A to Z, longest), like Files.
/// </summary>
public static class LibrarySortMenu
{
    /// <summary>Raised after the sort changes (any screen's menu).</summary>
    public static event Action? Changed;

    public static LibrarySort Current => LibrarySort.Load(KeyValueStores.Default);

    public static Button Create(string automationId = "library.sort")
    {
        var icon = UI.UI.Icon("arrow.up.arrow.down", 14);
        var button = new Button
        {
            Content = icon,
            Width = 36,
            Height = 36,
            MinWidth = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(18),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(button, "Sort");
        AutomationProperties.SetAutomationId(button, automationId);
        ToolTipService.SetToolTip(button, "Sort stories");

        void Refresh()
        {
            var sort = Current;
            button.Background = sort.IsDefault ? Theme.SubtleFill : Theme.AccentSubtle;
            icon.Foreground = sort.IsDefault ? Theme.TextPrimary : Theme.Accent;
            // SwiftUI's accessibilityValue: "Title, A to Z".
            AutomationProperties.SetItemStatus(button, $"{sort.Key.Title()}, {sort.Key.DirectionLabel(sort.Ascending)}");
        }

        var flyout = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
        flyout.Opening += (_, _) =>
        {
            flyout.Items.Clear();
            var sort = Current;
            foreach (var key in LibrarySortKeyExtensions.All)
            {
                var item = new RadioMenuFlyoutItem
                {
                    Text = key.Title(),
                    GroupName = "library.sortKey",
                    IsChecked = key == sort.Key,
                    Icon = new FontIcon { Glyph = Symbols.Glyph(key.SystemImage()), FontFamily = Symbols.Font },
                };
                AutomationProperties.SetAutomationId(item, $"library.sort.{key.RawValue()}");
                var picked = key;
                item.Click += (_, _) =>
                {
                    if (picked == Current.Key) return;
                    Apply(new LibrarySort(picked, picked.DefaultAscending()));
                };
                flyout.Items.Add(item);
            }
            flyout.Items.Add(new MenuFlyoutSeparator());
            // The key's natural direction first: "A to Z" above "Z to A".
            var natural = sort.Key.DefaultAscending();
            foreach (var asc in new[] { natural, !natural })
            {
                var item = new RadioMenuFlyoutItem
                {
                    Text = sort.Key.DirectionLabel(asc),
                    GroupName = "library.sortOrder",
                    IsChecked = sort.Ascending == asc,
                };
                AutomationProperties.SetAutomationId(item, asc ? "library.sort.ascending" : "library.sort.descending");
                var ascending = asc;
                item.Click += (_, _) =>
                {
                    var now = Current;
                    if (now.Ascending == ascending) return;
                    Apply(now with { Ascending = ascending });
                };
                flyout.Items.Add(item);
            }
        };
        button.Flyout = flyout;

        void OnChanged() => Refresh();
        button.Loaded += (_, _) => { Changed -= OnChanged; Changed += OnChanged; Refresh(); };
        button.Unloaded += (_, _) => Changed -= OnChanged;
        Refresh();
        return button;
    }

    private static void Apply(LibrarySort sort)
    {
        sort.Store(KeyValueStores.Default);
        Changed?.Invoke();
        Shell.MainWindow.Current?.Announce($"Sorted by {sort.Key.Title()}, {sort.Key.DirectionLabel(sort.Ascending)}");
    }
}
