using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Fanficly.App.Views.Search;

/// <summary>The chips' views: removable filter chips (built by Core's
/// <see cref="FilterChips"/>) and suggestion tokens.</summary>
internal static class SearchChips
{
    private static SolidColorBrush? _dangerSubtle;

    /// <summary>The exclude chip's fill: the palette's red at the include chip's
    /// strength, kept in step with light / dark / high contrast.</summary>
    public static SolidColorBrush DangerSubtle
    {
        get
        {
            if (_dangerSubtle is null)
            {
                _dangerSubtle = new SolidColorBrush();
                UpdateDangerSubtle();
                Theme.Changed += UpdateDangerSubtle;
            }
            return _dangerSubtle;
        }
    }

    private static void UpdateDangerSubtle()
    {
        if (_dangerSubtle is null) return;
        if (Theme.IsHighContrast) { _dangerSubtle.Color = Theme.AccentSubtle.Color; return; }
        var c = Theme.Danger.Color;
        _dangerSubtle.Color = Color.FromArgb(Theme.Current == ElementTheme.Dark ? (byte)0x40 : (byte)0x24, c.R, c.G, c.B);
    }

    /// <summary>ChipView: a token (Windows' tokenizing text box style: 4 px
    /// corners and a hairline edge, rather than the Mac's capsule) with the
    /// label and, when removable, a small ✕.
    /// The whole chip is the button (tapping it removes the filter).</summary>
    public static Button RemovableChip(ActiveChip chip, bool hasSearched, Action onRemove, string automationPrefix = "search.chip")
    {
        var foreground = chip.Kind == ChipKind.Include ? Theme.Accent : Theme.Danger;
        var background = chip.Kind == ChipKind.Include ? Theme.AccentSubtle : DangerSubtle;
        var label = new TextBlock
        {
            Text = chip.Label,
            FontSize = 12,
            Foreground = foreground,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 360,
        };
        var x = (FontIcon)UI.UI.Icon("xmark", 9, foreground);
        x.Opacity = 0.6;
        x.FontWeight = FontWeights.Bold;
        x.VerticalAlignment = VerticalAlignment.Center;
        var button = new Button
        {
            Content = UI.UI.HStack(6, label, x),
            Background = background,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(8, 3, 7, 4),
            MinHeight = 0,
            MinWidth = 0,
        };
        AutomationProperties.SetName(button, $"Remove filter: {chip.Label}");
        AutomationProperties.SetHelpText(button, hasSearched ? "Removes this filter and searches again." : "Removes this filter.");
        AutomationProperties.SetAutomationId(button, $"{automationPrefix}.{chip.Id}");
        ToolTipService.SetToolTip(button, $"Remove {chip.Label}");
        button.Click += (_, _) => onRemove();
        return button;
    }

    /// <summary>One suggestion in the row under the box: a tinted token with the
    /// suggestion's icon and label. Clicking it doesn't take focus from the box
    /// (typing carries on); the keyboard still reaches it (↓ from the box, ← →).</summary>
    public static Button SuggestionButton(SuggestionCandidate candidate, Action onApply)
    {
        var s = candidate.Suggestion;
        var content = UI.UI.Label(s.SystemImage, s.Label, Theme.Style.Subheadline, Theme.Accent, spacing: 6, maxLines: UI.UI.LineLimit(1));
        var button = new Button
        {
            Content = content,
            Background = Theme.AccentSubtle,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(8, 4, 9, 5),
            MinHeight = 0,
            MinWidth = 0,
            AllowFocusOnInteraction = false,
        };
        AutomationProperties.SetName(button, $"Add filter: {s.Label}");
        AutomationProperties.SetAutomationId(button, $"search.suggestion.{candidate.Id}");
        button.Click += (_, _) => onApply();
        return button;
    }
}
