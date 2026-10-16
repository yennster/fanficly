using System.Runtime.CompilerServices;
using Fanficly.App.UI;
using Fanficly.Core;

namespace Fanficly.App.Views.Search;

/// <summary>Registers the Search tab and the symbols its suggestions and tips use.</summary>
internal static class SearchModule
{
    [ModuleInitializer]
    internal static void Initialize()
    {
        Tabs.Register(SidebarItem.Search, () => new SearchScreen());
    }

    private static bool _symbolsAdded;

    /// <summary>SF Symbols the search suggestions and Search Tips use that the
    /// shared table doesn't have. Called from the UI thread when the screen is
    /// first made, not from the module initializer: touching
    /// <see cref="Symbols"/> runs its static initializer, which creates a XAML
    /// <c>FontFamily</c>, and that must not happen before the XAML runtime is up.</summary>
    internal static void EnsureSymbols()
    {
        if (_symbolsAdded) return;
        _symbolsAdded = true;
        if (!Symbols.Has("tag")) Symbols.Add("tag", '');           // Tag
        if (!Symbols.Has("1.circle")) Symbols.Add("1.circle", ''); // Page: a single-chapter work
        if (!Symbols.Has("scope")) Symbols.Add("scope", '');       // Bullseye
    }
}
