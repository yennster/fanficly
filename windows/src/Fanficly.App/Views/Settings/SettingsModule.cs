using System.Runtime.CompilerServices;
using Fanficly.App.UI;
using Fanficly.Core;

namespace Fanficly.App.Views.Settings;

/// <summary>Registers the Settings tab and the icons only Settings uses.</summary>
internal static class SettingsModule
{
#pragma warning disable CA2255 // Module initializers register features with the shell by design.
    [ModuleInitializer]
#pragma warning restore CA2255
    internal static void Register()
    {
        Tabs.Register(SidebarItem.Settings, () => new SettingsScreen());

        Symbols.Add("circle.lefthalf.filled", '\uE790');        // Color
        Symbols.Add("hand.raised", '\uEA18');                   // Shield
        Symbols.Add("arrow.triangle.2.circlepath", '\uE895');   // Sync
        Symbols.Add("icloud.and.arrow.up", '\uE898');           // Upload
        Symbols.Add("icloud.and.arrow.down", '\uEBD3');         // CloudDownload
        Symbols.Add("arrow.up.right.square", '\uE8A7');         // OpenInNewWindow
        Symbols.Add("stop.fill", '\uE71A');                     // Stop
        Symbols.Add("pencil", '\uE70F');                        // Edit
        Symbols.Add("plus", '\uE710');                          // Add
        Symbols.Add("square.and.arrow.down", '\uE74E');         // Save
        Symbols.Add("folder.fill", '\uE8B7');                   // Folder
    }
}
