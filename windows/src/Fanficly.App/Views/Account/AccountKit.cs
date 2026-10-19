using System.Globalization;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Account;

/// <summary>Small helpers shared by the account, authors and import screens.</summary>
internal static class AccountKit
{
    /// <summary>UI-test handle (AutomationProperties.AutomationId).</summary>
    public static T Id<T>(this T e, string automationId) where T : DependencyObject
    {
        AutomationProperties.SetAutomationId(e, automationId);
        return e;
    }

    /// <summary>"5 minutes", "2 hours", "3 days" — SwiftUI's <c>Text(date, style: .relative)</c>,
    /// which the rows read as "checked 5 minutes ago".</summary>
    public static string RelativeSpan(DateTimeOffset date, DateTimeOffset? now = null)
    {
        var span = (now ?? DateTimeOffset.Now) - date;
        if (span < TimeSpan.Zero) span = TimeSpan.Zero;
        static string Unit(int n, string one) => $"{n.ToString(CultureInfo.CurrentCulture)} {one}{(n == 1 ? "" : "s")}";
        if (span.TotalMinutes < 1) return Unit(Math.Max(0, (int)span.TotalSeconds), "second");
        if (span.TotalHours < 1) return Unit((int)span.TotalMinutes, "minute");
        if (span.TotalDays < 1) return Unit((int)span.TotalHours, "hour");
        if (span.TotalDays < 7) return Unit((int)span.TotalDays, "day");
        if (span.TotalDays < 31) return Unit((int)(span.TotalDays / 7), "week");
        if (span.TotalDays < 365) return Unit((int)(span.TotalDays / 30.44), "month");
        return Unit((int)(span.TotalDays / 365.25), "year");
    }

    /// <summary>Foundation's <c>.relative(presentation: .named)</c>: "now", "yesterday",
    /// "3 days ago".</summary>
    public static string RelativeNamed(DateTimeOffset date, DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.Now;
        var span = current - date;
        if (span < TimeSpan.Zero) span = TimeSpan.Zero;
        if (span.TotalMinutes < 1) return "now";
        var days = (current.LocalDateTime.Date - date.LocalDateTime.Date).Days;
        if (span.TotalDays < 1 && days == 0) return $"{RelativeSpan(date, current)} ago";
        if (days == 1) return "yesterday";
        if (span.TotalDays < 7) return $"{Math.Max(days, 1)} days ago";
        if (span.TotalDays < 14) return "last week";
        return $"{RelativeSpan(date, current)} ago";
    }

    /// <summary>"checked 5 minutes ago" caption (SubscriptionRow / FollowedAuthorRow).</summary>
    public static string CheckedAgo(DateTimeOffset checkedAt) => $"checked {RelativeSpan(checkedAt)} ago";

    /// <summary>A caption with a decorative leading symbol ("person  Author").</summary>
    public static Grid KindLabel(string sfSymbol, string text)
    {
        var icon = UI.UI.Icon(sfSymbol, 10, Theme.TextSecondary);
        // By the first line when the caption wraps.
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 2, 0, 0);
        var label = UI.UI.Caption(text);
        label.VerticalAlignment = VerticalAlignment.Center;
        // A grid, not a horizontal stack, so a long caption (a fandom) wraps
        // at large text sizes instead of running past the row's edge.
        var grid = UI.UI.Grid("Auto,*", columnSpacing: 4);
        grid.Children.Add(icon.Col(0));
        grid.Children.Add(label.Col(1));
        return grid;
    }

    /// <summary>Opens an AO3 page in the default browser (SafariView on iOS).</summary>
    public static void OpenInBrowser(Uri uri) => _ = OpenInBrowserAsync(uri);

    private static async Task OpenInBrowserAsync(Uri uri)
    {
        try { await Windows.System.Launcher.LaunchUriAsync(uri); }
        catch (Exception e) { AppHost.Log($"Couldn't open {uri}: {e.Message}"); }
    }

    /// <summary>A full-width list row (the iOS NavigationLink row) that opens on
    /// click / Enter / Space, with a context menu (right-click, press-and-hold,
    /// Shift+F10, the Menu key).</summary>
    public static Button ListRow(UIElement content, Action onOpen, string accessibleName, MenuFlyout? contextMenu = null)
    {
        var row = new Button
        {
            Content = content,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = Theme.Transparent,
            BorderBrush = Theme.Transparent,
            Padding = new Thickness(14, 10, 14, 10),
            CornerRadius = new CornerRadius(6),
        };
        AutomationProperties.SetName(row, accessibleName);
        row.Click += (_, _) => onOpen();
        if (contextMenu is not null) row.ContextFlyout = contextMenu;
        return row;
    }

    /// <summary>The section caption used between groups of rows in a list.</summary>
    public static TextBlock ListSectionHeader(string text) =>
        UI.UI.SectionHeader(text).Also(t => t.Margin = new Thickness(14, 16, 0, 4));

    /// <summary>The rows' own content filter (Search/Browse/Author/Bookmarks share it).</summary>
    public static IReadOnlyList<AO3WorkSummary> Visible(IEnumerable<AO3WorkSummary> works) =>
        ContentFilter.Apply(works, HiddenWorkStore.Ids(AppHost.Library),
                            KeyValueStores.Default.GetBool(Core.ContentControl.FilterMatureKey, true));

    /// <summary>Runs <paramref name="action"/> on the UI thread (library change
    /// events arrive on whichever thread saved).</summary>
    public static void OnUIThread(Action action)
    {
        var queue = Shell.MainWindow.Current?.DispatcherQueue;
        if (queue is null) return;
        if (queue.HasThreadAccess) action();
        else queue.TryEnqueue(() => action());
    }
}
