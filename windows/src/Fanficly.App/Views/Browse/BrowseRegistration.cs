using System.Runtime.CompilerServices;
using Fanficly.Core;

namespace Fanficly.App.Views.Browse;

/// <summary>Registers the Browse and Popular tabs and the filtered-works screen
/// other features open (a fandom, a saved filter, a popular tag, a tag link).</summary>
internal static class BrowseRegistration
{
    [ModuleInitializer]
    internal static void Register()
    {
        Tabs.Register(SidebarItem.Browse, () => new BrowseScreen());
        Tabs.Register(SidebarItem.Popular, () => new PopularScreen());
        Routes.FilteredWorks = (filters, title) => new FilteredWorksScreen(filters, title);
    }
}
