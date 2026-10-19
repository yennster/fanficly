using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Settings;

/// <summary>Settings → Keyboard shortcuts: the Mac app's Go menu and zoom
/// commands as Windows shortcuts, plus window, navigation and reader keys,
/// and the Xbox controller's buttons.</summary>
public sealed class ShortcutsScreen : Screen
{
    public ShortcutsScreen() => Title = "Keyboard Shortcuts";

    protected override FrameworkElement Build()
    {
        // Tabs without a shortcut (Marked for Later, AO3 History) are left out, not shown as "Ctrl+10".
        var go = SidebarItems.All.Where(item => item.ShortcutText() is not null)
            .Select(item => (item.ShortcutText()!, $"Go to {item.Title()}")).ToList();

        var page = UI.UI.VStack(18,
            Group("Go", go),
            Group("View",
            [
                ("Ctrl+Plus or Ctrl+Shift+Plus", "Zoom in"),
                ("Ctrl+Minus or Ctrl+Shift+Minus", "Zoom out"),
                ("Ctrl+0", "Actual size"),
                ("F11", "Full screen"),
            ]),
            Group("Navigation",
            [
                ("Alt+Left", "Back"),
                ("Esc", "Back, or close a dialog or menu"),
                ("Mouse back button", "Back"),
                ("Tab / Shift+Tab", "Move between controls"),
                ("Enter or Space", "Activate the focused control"),
                ("Shift+F10 or Menu key", "Open the focused item's context menu"),
                ("Ctrl+V", "Open a copied AO3 link (outside a text box; or drop the link on the window)"),
            ]),
            Group("Reader",
            [
                ("Left / Right", "Previous / next page (in swipe by chapter: previous / next chapter)"),
                ("Page Up / Page Down", "Previous / next page"),
                ("Space / Shift+Space", "Next / previous page"),
                ("Ctrl+Left / Ctrl+Right", "Previous / next chapter"),
                ("Home / End", "Start / end of the chapter"),
                ("Ctrl+L", "Listen to the chapter, or stop"),
                ("Esc", "Leave full screen, or show the reader controls"),
                ("F11", "Full screen"),
            ]),
            Group("Xbox controller", SettingsScreen.ControllerMap));
        return SettingsKit.Page(page, "settings.shortcuts.page");
    }

    private static StackPanel Group(string title, IEnumerable<(string Keys, string Action)> rows) =>
        UI.UI.Section(title, rows.Select(r => (UIElement)Row(r.Keys, r.Action)));

    private static Grid Row(string keys, string action)
    {
        var grid = UI.UI.Grid("*,Auto", columnSpacing: 16);
        grid.Padding = new Thickness(14, 10, 14, 10);
        grid.Children.Add(UI.UI.Text(action).Also(t => t.VerticalAlignment = VerticalAlignment.Center).Col(0));
        var keyCap = new Border
        {
            Child = UI.UI.Text(keys, Theme.Style.Subheadline),
            Background = Theme.SubtleFill,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(8, 2, 8, 3),
            VerticalAlignment = VerticalAlignment.Center,
        };
        // At most 45 % of the row: at large text sizes a long key cap
        // ("Ctrl+Left / Ctrl+Right") wraps instead of squeezing its action.
        grid.Children.Add(keyCap.MaxWidthOf(grid, 0.45).Col(1));
        return grid;
    }
}
