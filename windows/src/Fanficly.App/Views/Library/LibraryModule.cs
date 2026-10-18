using System.Runtime.CompilerServices;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;

namespace Fanficly.App.Views.Library;

/// <summary>Registers the Library and Stats tabs, the folder route, the
/// post-restore re-download prompt, and the few symbols only these screens use.</summary>
internal static class LibraryModule
{
    [ModuleInitializer]
    internal static void Register()
    {
        Tabs.Register(SidebarItem.Library, () => new LibraryScreen());
        Tabs.Register(SidebarItem.Stats, () => new Stats.StatsScreen());

        // fanficly://library?folder=<name> (a folder widget): AppRouting has
        // already selected the Library tab, so the folder opens on top of it.
        Routes.LibraryFolder = name =>
        {
            var window = MainWindow.Current;
            if (window is null) return;
            window.RootScreen<LibraryScreen>(SidebarItem.Library)?.ShowFoldersFilter();
            window.Navigator.Push(new FolderScreen(name));
        };

        RestoreBanner.Install();

        Symbols.Add("pin", '');                // Pin
        Symbols.Add("pencil", '');             // Edit
        Symbols.Add("doc.on.doc", '');         // Copy
        Symbols.Add("square.and.arrow.down", ''); // SaveAs
        Symbols.Add("checklist", '');          // MultiSelect
        Symbols.Add("xmark.circle", '');       // Cancel
        Symbols.Add("checkmark.square", '');   // SelectAll
    }
}
