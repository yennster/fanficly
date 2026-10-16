using Windows.System;

namespace Fanficly.App.Shell;

/// <summary>The sidebar tabs, in sidebar order (RootView's SidebarItem).</summary>
public enum SidebarItem
{
    Search, Browse, Popular, Library, RecentlyViewed, Authors, Bookmarks, Subscriptions, Stats, Settings,
}

public static class SidebarItems
{
    public static readonly SidebarItem[] All = Enum.GetValues<SidebarItem>();

    /// <summary>Stored under "app.selectedTabRaw" with the Swift app's raw values.</summary>
    public static string RawValue(this SidebarItem item) => item switch
    {
        SidebarItem.Search => "search",
        SidebarItem.Browse => "browse",
        SidebarItem.Popular => "popular",
        SidebarItem.Library => "library",
        SidebarItem.RecentlyViewed => "recentlyViewed",
        SidebarItem.Authors => "authors",
        SidebarItem.Bookmarks => "bookmarks",
        SidebarItem.Subscriptions => "subscriptions",
        SidebarItem.Stats => "stats",
        _ => "settings",
    };

    public static SidebarItem? FromRaw(string? raw) =>
        All.Select(i => (SidebarItem?)i).FirstOrDefault(i => i!.Value.RawValue() == raw);

    public static string Title(this SidebarItem item) => item switch
    {
        SidebarItem.Search => "Search",
        SidebarItem.Browse => "Browse",
        SidebarItem.Popular => "Popular",
        SidebarItem.Library => "Library",
        SidebarItem.RecentlyViewed => "Recently Viewed",
        SidebarItem.Authors => "Followed Authors",
        SidebarItem.Bookmarks => "Bookmarks",
        SidebarItem.Subscriptions => "Subscriptions",
        SidebarItem.Stats => "Stats",
        _ => "Settings",
    };

    public static string Symbol(this SidebarItem item) => item switch
    {
        SidebarItem.Search => "magnifyingglass",
        SidebarItem.Browse => "rectangle.stack",
        SidebarItem.Popular => "flame",
        SidebarItem.Library => "books.vertical",
        SidebarItem.RecentlyViewed => "clock.arrow.circlepath",
        SidebarItem.Authors => "person.2",
        SidebarItem.Bookmarks => "bookmark",
        SidebarItem.Subscriptions => "bell",
        SidebarItem.Stats => "chart.bar.xaxis",
        _ => "gearshape",
    };

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
