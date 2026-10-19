namespace Fanficly.Core;

/// <summary>The app's top-level tabs, in sidebar order (Swift's <c>SidebarItem</c>).
/// The raw value is what <c>app.selectedTabRaw</c> stores.</summary>
public enum SidebarItem { Search, Browse, Popular, Library, RecentlyViewed, Authors, Bookmarks, MarkedForLater, AO3History, Subscriptions, Stats, Settings }

public static class SidebarItemExtensions
{
    public static IReadOnlyList<SidebarItem> All { get; } =
    [
        SidebarItem.Search, SidebarItem.Browse, SidebarItem.Popular, SidebarItem.Library, SidebarItem.RecentlyViewed,
        SidebarItem.Authors, SidebarItem.Bookmarks, SidebarItem.MarkedForLater, SidebarItem.AO3History, SidebarItem.Subscriptions,
        SidebarItem.Stats, SidebarItem.Settings,
    ];

    /// <summary>"search", "recentlyViewed", … — the Swift raw values.</summary>
    public static string RawValue(this SidebarItem item) => item switch
    {
        SidebarItem.Search => "search",
        SidebarItem.Browse => "browse",
        SidebarItem.Popular => "popular",
        SidebarItem.Library => "library",
        SidebarItem.RecentlyViewed => "recentlyViewed",
        SidebarItem.Authors => "authors",
        SidebarItem.Bookmarks => "bookmarks",
        SidebarItem.MarkedForLater => "markedForLater",
        SidebarItem.AO3History => "ao3History",
        SidebarItem.Subscriptions => "subscriptions",
        SidebarItem.Stats => "stats",
        _ => "settings",
    };

    public static SidebarItem? ParseSidebarItem(string raw) =>
        All.Cast<SidebarItem?>().FirstOrDefault(i => i!.Value.RawValue() == raw);

    public static string Title(this SidebarItem item) => item switch
    {
        SidebarItem.Search => "Search",
        SidebarItem.Browse => "Browse",
        SidebarItem.Popular => "Popular",
        SidebarItem.Library => "Library",
        SidebarItem.Stats => "Stats",
        SidebarItem.RecentlyViewed => "Recently Viewed",
        SidebarItem.Authors => "Followed Authors",
        SidebarItem.Bookmarks => "Bookmarks",
        SidebarItem.MarkedForLater => "Marked for Later",
        SidebarItem.AO3History => "AO3 History",
        SidebarItem.Subscriptions => "Subscriptions",
        _ => "Settings",
    };

    /// <summary>Icon id (SF Symbol name; the app maps it to a Fluent glyph).</summary>
    public static string SystemImage(this SidebarItem item) => item switch
    {
        SidebarItem.Search => "magnifyingglass",
        SidebarItem.Browse => "rectangle.stack",
        SidebarItem.Popular => "flame",
        SidebarItem.Library => "books.vertical",
        SidebarItem.Stats => "chart.bar.xaxis",
        SidebarItem.RecentlyViewed => "clock.arrow.circlepath",
        SidebarItem.Authors => "person.2",
        SidebarItem.Bookmarks => "bookmark",
        SidebarItem.MarkedForLater => "clock",
        SidebarItem.AO3History => "calendar.badge.clock",
        SidebarItem.Subscriptions => "bell",
        _ => "gearshape",
    };
}
