using Fanficly.App.Shell;
using Fanficly.Core;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace Fanficly.App.Views.Settings;

/// <summary>
/// The app-wide light / dark choice (Settings → Appearance), stored under
/// <c>app.theme</c>: "system" follows Windows, "light" / "dark" pin it. It is
/// applied to the window's root element, never per screen, and never touches
/// the reader's own page themes. The shell calls <see cref="Apply"/> once at
/// startup; Settings calls it again on every change so it takes effect at once.
/// </summary>
public static class AppearanceSettings
{
    public const string ThemeKey = "app.theme";

    public static readonly IReadOnlyList<(string Raw, string Name)> Options =
    [
        ("system", "Use system setting"),
        ("light", "Light"),
        ("dark", "Dark"),
    ];

    /// <summary>The stored choice ("system" when unset or unknown).</summary>
    public static string Current
    {
        get
        {
            var raw = KeyValueStores.Default.GetString(ThemeKey);
            return Options.Any(o => o.Raw == raw) ? raw! : "system";
        }
        set
        {
            KeyValueStores.Default.SetString(ThemeKey, value);
            Apply();
        }
    }

    public static ElementTheme ElementTheme => Current switch
    {
        "light" => ElementTheme.Light,
        "dark" => ElementTheme.Dark,
        _ => ElementTheme.Default,
    };

    /// <summary>Applies the stored theme to the main window (content and caption buttons).</summary>
    public static void Apply()
    {
        var window = MainWindow.Current;
        if (window is null) return;
        var theme = ElementTheme;
        window.RootElement.RequestedTheme = theme;
        try
        {
            window.AppWindow.TitleBar.PreferredTheme = theme switch
            {
                ElementTheme.Light => TitleBarTheme.Light,
                ElementTheme.Dark => TitleBarTheme.Dark,
                _ => TitleBarTheme.UseDefaultAppMode,
            };
        }
        catch (Exception e)
        {
            AppHost.Log($"Title bar theme failed: {e.Message}");
        }
    }
}
