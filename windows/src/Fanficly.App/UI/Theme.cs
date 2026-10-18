using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.Text;
using Windows.UI.ViewManagement;

namespace Fanficly.App.UI;

/// <summary>
/// The app's palette and type ramp. Built-in controls theme themselves; the
/// brushes here are for our own drawing (secondary text, chips, cards). They
/// are shared instances whose colours are swapped in place when the window's
/// light/dark/high-contrast theme changes, so nothing has to be rebuilt.
/// </summary>
public static class Theme
{
    /// <summary>The brand indigo (the Mac app's AccentColor): light / dark.</summary>
    public static readonly Color BrandLight = Color.FromArgb(0xFF, 0x3B, 0x2E, 0x8C);
    public static readonly Color BrandDark = Color.FromArgb(0xFF, 0x84, 0x72, 0xE6);

    public static readonly SolidColorBrush TextPrimary = new();
    public static readonly SolidColorBrush TextSecondary = new();
    public static readonly SolidColorBrush TextTertiary = new();
    public static readonly SolidColorBrush Accent = new();
    public static readonly SolidColorBrush AccentSubtle = new();
    public static readonly SolidColorBrush OnAccent = new(Colors.White);
    public static readonly SolidColorBrush CardBackground = new();
    public static readonly SolidColorBrush CardStroke = new();
    public static readonly SolidColorBrush Divider = new();
    public static readonly SolidColorBrush SubtleFill = new();
    public static readonly SolidColorBrush Danger = new();
    public static readonly SolidColorBrush Success = new();
    public static readonly SolidColorBrush Warning = new();
    public static readonly SolidColorBrush Transparent = new(Colors.Transparent);

    public static ElementTheme Current { get; private set; } = ElementTheme.Light;
    public static bool IsHighContrast { get; private set; }

    /// <summary>Raised after the palette changes (light ↔ dark, high contrast).</summary>
    public static event Action? Changed;

    public static FontFamily UIFont { get; } = new("Segoe UI Variable Text,Segoe UI");
    public static FontFamily DisplayFont { get; } = new("Segoe UI Variable Display,Segoe UI");
    /// <summary>The serif used where the Mac app uses New York (titles, reader).</summary>
    public static FontFamily SerifFont { get; } = new("Sitka Text,Georgia,Cambria");
    public static FontFamily SerifDisplayFont { get; } = new("Sitka Heading,Sitka Text,Georgia");

    public static void Apply(ElementTheme theme)
    {
        Current = theme == ElementTheme.Default ? ElementTheme.Light : theme;
        var access = new Windows.UI.ViewManagement.AccessibilitySettings();
        IsHighContrast = access.HighContrast;
        var dark = Current == ElementTheme.Dark;
        if (IsHighContrast)
        {
            var ui = new UISettings();
            Color Sys(UIElementType t) => ui.UIElementColor(t);
            TextPrimary.Color = Sys(UIElementType.WindowText);
            TextSecondary.Color = Sys(UIElementType.WindowText);
            TextTertiary.Color = Sys(UIElementType.GrayText);
            Accent.Color = Sys(UIElementType.Hotlight);
            AccentSubtle.Color = Sys(UIElementType.Window);
            OnAccent.Color = Sys(UIElementType.HighlightText);
            CardBackground.Color = Sys(UIElementType.Window);
            CardStroke.Color = Sys(UIElementType.WindowText);
            Divider.Color = Sys(UIElementType.WindowText);
            SubtleFill.Color = Sys(UIElementType.Window);
            Danger.Color = Sys(UIElementType.WindowText);
            Success.Color = Sys(UIElementType.WindowText);
            Warning.Color = Sys(UIElementType.WindowText);
        }
        else
        {
            TextPrimary.Color = dark ? Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0xE4, 0, 0, 0);
            TextSecondary.Color = dark ? Color.FromArgb(0xC5, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x9E, 0, 0, 0);
            TextTertiary.Color = dark ? Color.FromArgb(0x8B, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x72, 0, 0, 0);
            Accent.Color = dark ? BrandDark : BrandLight;
            AccentSubtle.Color = dark ? Color.FromArgb(0x40, 0x84, 0x72, 0xE6) : Color.FromArgb(0x1F, 0x3B, 0x2E, 0x8C);
            OnAccent.Color = dark ? Color.FromArgb(0xFF, 0x10, 0x0C, 0x24) : Colors.White;
            CardBackground.Color = dark ? Color.FromArgb(0x0D, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0xB3, 0xFF, 0xFF, 0xFF);
            CardStroke.Color = dark ? Color.FromArgb(0x19, 0, 0, 0) : Color.FromArgb(0x0F, 0, 0, 0);
            Divider.Color = dark ? Color.FromArgb(0x15, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x0F, 0, 0, 0);
            SubtleFill.Color = dark ? Color.FromArgb(0x0F, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x09, 0, 0, 0);
            Danger.Color = dark ? Color.FromArgb(0xFF, 0xFF, 0x99, 0xA4) : Color.FromArgb(0xFF, 0xC4, 0x2B, 0x1C);
            Success.Color = dark ? Color.FromArgb(0xFF, 0x6C, 0xCB, 0x5F) : Color.FromArgb(0xFF, 0x0F, 0x7B, 0x0F);
            Warning.Color = dark ? Color.FromArgb(0xFF, 0xFC, 0xE1, 0x00) : Color.FromArgb(0xFF, 0x9D, 0x5D, 0x00);
        }
        Changed?.Invoke();
    }

    /// <summary>Overrides the system accent with the brand indigo so accent
    /// buttons, toggles, selection and focus visuals all match the Mac app.</summary>
    public static void InstallAccent(ResourceDictionary resources)
    {
        resources["SystemAccentColor"] = Color.FromArgb(0xFF, 0x4B, 0x3B, 0xC0);
        resources["SystemAccentColorLight1"] = Color.FromArgb(0xFF, 0x63, 0x52, 0xD3);
        resources["SystemAccentColorLight2"] = BrandDark;
        resources["SystemAccentColorLight3"] = Color.FromArgb(0xFF, 0xA9, 0x9C, 0xF0);
        resources["SystemAccentColorDark1"] = Color.FromArgb(0xFF, 0x43, 0x34, 0xA8);
        resources["SystemAccentColorDark2"] = BrandLight;
        resources["SystemAccentColorDark3"] = Color.FromArgb(0xFF, 0x2A, 0x20, 0x66);
    }

    // MARK: - Type ramp (the iOS text styles, on Windows' type ramp)

    public enum Style
    {
        LargeTitle, Title, Title2, Title3, Headline, Body, Callout, Subheadline, Footnote, Caption, Caption2,
    }

    public static (double Size, FontWeight Weight, FontFamily Family) Metrics(Style style) => style switch
    {
        Style.LargeTitle => (30, FontWeights.SemiBold, DisplayFont),
        Style.Title => (26, FontWeights.SemiBold, DisplayFont),
        Style.Title2 => (21, FontWeights.SemiBold, DisplayFont),
        Style.Title3 => (18, FontWeights.SemiBold, UIFont),
        Style.Headline => (14, FontWeights.SemiBold, UIFont),
        Style.Body => (14, FontWeights.Normal, UIFont),
        Style.Callout => (13.5, FontWeights.Normal, UIFont),
        Style.Subheadline => (13, FontWeights.Normal, UIFont),
        Style.Footnote => (12, FontWeights.Normal, UIFont),
        Style.Caption => (12, FontWeights.Normal, UIFont),
        _ => (11, FontWeights.Normal, UIFont),
    };
}
