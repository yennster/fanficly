using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// The reader's colours: its theme's page background and text colour (Core's
/// <see cref="ReaderTheme"/>, the one place the app doesn't use the shared
/// palette) at the opacities the Swift reader draws with, plus the brand accent
/// for the reader's scheme. Shared instances updated in place when the theme
/// changes, so nothing has to be rebuilt.
/// </summary>
internal sealed class ReaderBrushes
{
    public SolidColorBrush Background { get; } = new();
    public SolidColorBrush Foreground { get; } = new();
    public SolidColorBrush Fg85 { get; } = new();
    public SolidColorBrush Fg75 { get; } = new();
    public SolidColorBrush Fg65 { get; } = new();
    public SolidColorBrush Fg60 { get; } = new();
    public SolidColorBrush Fg55 { get; } = new();
    public SolidColorBrush Fg50 { get; } = new();
    public SolidColorBrush Fg45 { get; } = new();
    public SolidColorBrush Fg20 { get; } = new();
    public SolidColorBrush Fg12 { get; } = new();
    public SolidColorBrush Fg10 { get; } = new();
    public SolidColorBrush Fg06 { get; } = new();
    public SolidColorBrush Accent { get; } = new();
    public SolidColorBrush AccentRule { get; } = new();
    /// <summary>The karaoke highlight behind the paragraph being read aloud.</summary>
    public SolidColorBrush Highlight { get; } = new();

    public ReaderColorScheme Scheme { get; private set; } = ReaderColorScheme.Light;

    public void Update(ReaderTheme theme)
    {
        var appScheme = Theme.Current == ElementTheme.Dark ? ReaderColorScheme.Dark : ReaderColorScheme.Light;
        Scheme = theme.PreferredColorScheme() ?? appScheme;
        var fg = ToColor(theme.Foreground(Scheme));
        Background.Color = ToColor(theme.Background(Scheme));
        Foreground.Color = fg;
        Fg85.Color = WithOpacity(fg, 0.85);
        Fg75.Color = WithOpacity(fg, 0.75);
        Fg65.Color = WithOpacity(fg, 0.65);
        Fg60.Color = WithOpacity(fg, 0.60);
        Fg55.Color = WithOpacity(fg, 0.55);
        Fg50.Color = WithOpacity(fg, 0.50);
        Fg45.Color = WithOpacity(fg, 0.45);
        Fg20.Color = WithOpacity(fg, 0.20);
        Fg12.Color = WithOpacity(fg, 0.12);
        Fg10.Color = WithOpacity(fg, 0.10);
        Fg06.Color = WithOpacity(fg, 0.06);
        var accent = Scheme == ReaderColorScheme.Dark ? Theme.BrandDark : Theme.BrandLight;
        Accent.Color = accent;
        AccentRule.Color = WithOpacity(accent, 0.3);
        Highlight.Color = WithOpacity(accent, 0.15);
    }

    /// <summary>The element theme the reader's controls (menus, sliders, focus
    /// rectangles) take: the reader's own scheme — never applied to the window, which
    /// would flip the whole app light ↔ dark (CLAUDE.md).</summary>
    public ElementTheme ElementTheme => Scheme == ReaderColorScheme.Dark ? ElementTheme.Dark : ElementTheme.Light;

    public static Color ToColor(ReaderColor c) => Color.FromArgb(c.A, c.R, c.G, c.B);

    public static Color WithOpacity(Color c, double opacity) =>
        Color.FromArgb((byte)Math.Round(c.A * opacity), c.R, c.G, c.B);

    /// <summary>A flat, borderless button for the reader's own bars: the reader's
    /// text colour, a faint fill on hover and press (Fluent's lightweight styling).</summary>
    public Button BarButton(object content, string label, Action? onClick = null)
    {
        var button = new Button
        {
            Content = content,
            Padding = new Thickness(9, 7, 9, 7),
            MinWidth = 36,
            MinHeight = 34,
            VerticalAlignment = VerticalAlignment.Center,
        };
        StyleFlat(button);
        ToolTipService.SetToolTip(button, label);
        AutomationProperties.SetName(button, label);
        if (onClick is not null) button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>An icon-only bar button (always labelled for Narrator and as a tooltip).</summary>
    public Button IconButton(string sfSymbol, string label, Action? onClick = null, double size = 16) =>
        BarButton(Symbols.Icon(sfSymbol, size).A11yHidden(), label, onClick);

    public void StyleFlat(Button button)
    {
        button.Background = Theme.Transparent;
        button.BorderBrush = Theme.Transparent;
        button.Foreground = Foreground;
        var r = button.Resources;
        r["ButtonBackground"] = Theme.Transparent;
        r["ButtonBackgroundPointerOver"] = Fg10;
        r["ButtonBackgroundPressed"] = Fg06;
        r["ButtonBackgroundDisabled"] = Theme.Transparent;
        r["ButtonForeground"] = Foreground;
        r["ButtonForegroundPointerOver"] = Foreground;
        r["ButtonForegroundPressed"] = Fg75;
        r["ButtonForegroundDisabled"] = Fg45;
        r["ButtonBorderBrush"] = Theme.Transparent;
        r["ButtonBorderBrushPointerOver"] = Theme.Transparent;
        r["ButtonBorderBrushPressed"] = Theme.Transparent;
        r["ButtonBorderBrushDisabled"] = Theme.Transparent;
    }
}
