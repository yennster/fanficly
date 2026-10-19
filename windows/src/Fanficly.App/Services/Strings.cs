using Microsoft.Windows.ApplicationModel.Resources;

namespace Fanficly.App.Services;

/// <summary>User-facing text from <c>Strings/en-US/Resources.resw</c> (MRT Core,
/// compiled into the app's PRI by MakePri), the Windows half of the Apple app's
/// String Catalog. English only for now. Keys are <c>Screen_Thing</c> (no dots:
/// MRT reads a dot as a XAML property path).</summary>
public static class Strings
{
    private static readonly ResourceLoader? Loader = CreateLoader();

    private static ResourceLoader? CreateLoader()
    {
        try { return new ResourceLoader(); }
        catch (Exception e)
        {
            // No resources.pri next to the exe (missing or stale; MakePri runs only on Windows).
            AppHost.Log($"Strings: no resource table ({e.GetType().Name})");
            return null;
        }
    }

    /// <summary>The string for <paramref name="key"/>, or the key itself when
    /// the table or the entry is missing, so a gap shows up as a visible key
    /// (and fails the UI tests) instead of a blank.</summary>
    public static string Get(string key)
    {
        if (Loader is null) return key;
        try
        {
            var value = Loader.GetString(key);
            return string.IsNullOrEmpty(value) ? key : value;
        }
        catch (Exception)
        {
            return key;
        }
    }
}
