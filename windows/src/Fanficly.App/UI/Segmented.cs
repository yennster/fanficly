using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Fanficly.App.UI;

/// <summary>
/// A segmented control, SwiftUI's <c>Picker</c> with <c>.segmented</c> style:
/// equal segments in a tinted track, the chosen one raised on a card with a
/// hairline edge (the look of the Windows Community Toolkit's Segmented
/// control and Windows 11's own pickers). Each segment is a button; Narrator
/// hears its position and whether it's selected, and the arrow keys move
/// between segments.
/// </summary>
internal sealed partial class Segmented : Grid
{
    private readonly List<Button> _segments = [];
    private readonly List<string> _titles = [];
    private int _selectedIndex = -1;

    /// <summary>Raised with the new index when the user picks a segment
    /// (not when <see cref="SelectedIndex"/> is set in code).</summary>
    public event Action<int>? SelectionChanged;

    public Segmented(string name, IReadOnlyList<(string Title, string? Symbol, string AutomationId)> items, int selectedIndex = 0)
    {
        Background = Theme.SubtleFill;
        BorderBrush = Theme.CardStroke;
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(6);
        Padding = new Thickness(2);
        AutomationProperties.SetName(this, name);

        XYFocusKeyboardNavigation = XYFocusKeyboardNavigationMode.Enabled;
        ColumnSpacing = 2;
        for (var i = 0; i < items.Count; i++)
        {
            var (title, symbol, id) = items[i];
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var label = new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
            var content = symbol is null ? (UIElement)label : UI.HStack(6, UI.Icon(symbol, 14), label);
            var button = new Button
            {
                Content = content,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Center,
                Padding = new Thickness(12, 5, 12, 6),
                MinHeight = 0,
                CornerRadius = new CornerRadius(4),
                BorderThickness = new Thickness(1),
            };
            AutomationProperties.SetName(button, title);
            AutomationProperties.SetAutomationId(button, id);
            AutomationProperties.SetPositionInSet(button, i + 1);
            AutomationProperties.SetSizeOfSet(button, items.Count);
            var index = i;
            button.Click += (_, _) =>
            {
                if (index == _selectedIndex) return;
                SelectedIndex = index;
                SelectionChanged?.Invoke(index);
            };
            Grid.SetColumn(button, i);
            Children.Add(button);
            _segments.Add(button);
            _titles.Add(title);
        }
        SelectedIndex = selectedIndex;
    }

    public int SelectedIndex
    {
        get => _selectedIndex;
        set
        {
            _selectedIndex = Math.Clamp(value, 0, _segments.Count - 1);
            for (var i = 0; i < _segments.Count; i++) Paint(_segments[i], i == _selectedIndex);
        }
    }

    private static void Paint(Button button, bool selected)
    {
        var background = selected ? Theme.CardBackground : Theme.Transparent;
        var border = selected ? Theme.CardStroke : Theme.Transparent;
        var foreground = selected ? Theme.TextPrimary : Theme.TextSecondary;
        button.Background = background;
        button.BorderBrush = border;
        button.Foreground = foreground;
        button.FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal;
        var r = button.Resources;
        r["ButtonBackgroundPointerOver"] = selected ? Theme.CardBackground : Theme.SubtleFill;
        r["ButtonBackgroundPressed"] = selected ? Theme.CardBackground : Theme.SubtleFill;
        r["ButtonBorderBrushPointerOver"] = border;
        r["ButtonBorderBrushPressed"] = border;
        r["ButtonForegroundPointerOver"] = Theme.TextPrimary;
        r["ButtonForegroundPressed"] = Theme.TextSecondary;
        AutomationProperties.SetItemStatus(button, selected ? "Selected" : "");
    }
}
