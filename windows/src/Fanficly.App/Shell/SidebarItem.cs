using Fanficly.Core;
using Windows.System;

namespace Fanficly.App.Shell;

/// <summary>Window-side helpers for Core's <see cref="SidebarItem"/> (sidebar order,
/// raw values and titles live in Core with the routing that uses them).</summary>
public static class SidebarItems
{
    public static readonly SidebarItem[] All = SidebarItemExtensions.All.ToArray();

    public static SidebarItem? FromRaw(string? raw) => raw is null ? null : SidebarItemExtensions.ParseSidebarItem(raw);

    public static string Symbol(this SidebarItem item) => item.SystemImage();

    /// <summary>The "Go" menu shortcuts: Ctrl+1…9 in the Mac app's ⌘1…9 order, Ctrl+, for Settings.</summary>
    public static (VirtualKey Key, VirtualKeyModifiers Modifiers) Shortcut(this SidebarItem item) => item switch
    {
        SidebarItem.Search => (VirtualKey.Number1, VirtualKeyModifiers.Control),
        SidebarItem.Browse => (VirtualKey.Number2, VirtualKeyModifiers.Control),
        SidebarItem.Popular => (VirtualKey.Number3, VirtualKeyModifiers.Control),
        SidebarItem.Library => (VirtualKey.Number4, VirtualKeyModifiers.Control),
        SidebarItem.RecentlyViewed => (VirtualKey.Number5, VirtualKeyModifiers.Control),
        SidebarItem.Authors => (VirtualKey.Number6, VirtualKeyModifiers.Control),
        SidebarItem.Bookmarks => (VirtualKey.Number7, VirtualKeyModifiers.Control),
        SidebarItem.Subscriptions => (VirtualKey.Number8, VirtualKeyModifiers.Control),
        SidebarItem.Stats => (VirtualKey.Number9, VirtualKeyModifiers.Control),
        _ => ((VirtualKey)188, VirtualKeyModifiers.Control), // VK_OEM_COMMA
    };

    public static string ShortcutText(this SidebarItem item) => item == SidebarItem.Settings
        ? "Ctrl+,"
        : $"Ctrl+{Array.IndexOf(All, item) + 1}";
}
