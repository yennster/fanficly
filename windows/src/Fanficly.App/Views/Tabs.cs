using Fanficly.App.Shell;

namespace Fanficly.App.Views;

/// <summary>Builds each sidebar tab's root screen.</summary>
public static class Tabs
{
    public static Screen Root(SidebarItem item) => item switch
    {
        _ => new PlaceholderScreen(item.Title()),
    };
}
