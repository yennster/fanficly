using Fanficly.App.Shell;
using Fanficly.Core;

namespace Fanficly.App.Views;

/// <summary>
/// Builds each sidebar tab's root screen. Each feature registers its own tab
/// from a module initializer in its folder (<c>Tabs.Register(SidebarItem.Search,
/// () =&gt; new SearchScreen())</c>), so features stay independent of each other.
/// </summary>
public static class Tabs
{
    private static readonly Dictionary<SidebarItem, Func<Screen>> Factories = [];

    public static void Register(SidebarItem item, Func<Screen> factory) => Factories[item] = factory;

    public static Screen Root(SidebarItem item) =>
        Factories.TryGetValue(item, out var factory) ? factory() : new PlaceholderScreen(item.Title());
}
