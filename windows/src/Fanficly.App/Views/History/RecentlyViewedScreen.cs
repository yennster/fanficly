using System.Runtime.CompilerServices;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.App.Views.Browse;
using Fanficly.App.Views.Shared;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Fanficly.App.Views.History;

internal static class HistoryRegistration
{
    [ModuleInitializer]
    internal static void Register() =>
        Tabs.Register(SidebarItem.RecentlyViewed, () => new RecentlyViewedScreen());
}

/// <summary>
/// The Recently Viewed tab (RecentlyViewedView): fics the user has opened,
/// newest first (entries are written when a work page opens), in result rows
/// like AO3 History's. Click a row to
/// open the work; remove one with Delete or its context menu (the Mac's swipe
/// action); <b>Edit</b> switches to multi-select to remove several at once
/// (the Mac's EditButton); <b>Clear</b> empties the history after a
/// confirmation. Removing history never touches AO3 or the Library.
/// </summary>
internal sealed class RecentlyViewedScreen : Screen
{
    private ListView _list = null!;
    private Grid _root = null!;
    private FrameworkElement _empty = null!;
    private LibraryChanges? _changes;
    private List<RecentlyViewed> _recents = [];
    private bool _editing;

    protected override FrameworkElement Build()
    {
        Title = "Recently Viewed";

        _list = new ListView
        {
            SelectionMode = ListViewSelectionMode.None,
            IsItemClickEnabled = true,
            Padding = new Thickness(16, 0, 16, 24),
            MaxWidth = 1000,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetName(_list, "Recently viewed");
        AutomationProperties.SetAutomationId(_list, "history.list");
        _list.ItemClick += (_, e) =>
        {
            if (Entry(e.ClickedItem) is { } item) Routes.OpenWork(item.Ao3Id);
        };
        _list.SelectionChanged += (_, _) => { if (_editing) InvalidateChrome(); };
        _list.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Delete) return;
            e.Handled = true;
            if (_editing) RemoveSelected();
            else if (FocusManager.GetFocusedElement(_list.XamlRoot) is ListViewItem container && Entry(container) is { } item)
                Remove([item]);
        };

        _empty = UI.UI.EmptyState("clock.arrow.circlepath", "Nothing here yet", "Fics you open will appear here, newest first.");
        _root = new Grid();
        Reload();
        _changes = new LibraryChanges(AppHost.Library, LibraryEntityKinds.RecentlyViewed, Reload);
        return _root;
    }

    public override void OnAppearing()
    {
        if (IsBuilt) Reload();
    }

    public override void OnRemoved() => _changes?.Dispose();

    public override bool HandleBack()
    {
        if (!_editing) return false;
        SetEditing(false);
        return true;
    }

    // MARK: - Toolbar

    public override IEnumerable<ICommandBarElement> PrimaryCommands()
    {
        if (_recents.Count == 0) yield break;
        if (_editing)
        {
            var selected = _list.SelectedItems.Count;
            var delete = UI.UI.ToolbarButton("trash", selected > 0 ? $"Remove {selected}" : "Remove", RemoveSelected, showLabel: true);
            delete.IsEnabled = selected > 0;
            delete.Foreground = Theme.Danger;
            AutomationProperties.SetAutomationId(delete, "history.removeSelected");
            yield return delete;
            var done = UI.UI.ToolbarButton("checkmark", "Done", () => SetEditing(false), showLabel: true);
            AutomationProperties.SetAutomationId(done, "history.edit");
            yield return done;
            yield break;
        }
        var edit = UI.UI.ToolbarButton("checkmark.circle", "Edit", () => SetEditing(true), showLabel: true);
        AutomationProperties.SetAutomationId(edit, "history.edit");
        ToolTipService.SetToolTip(edit, "Select entries to remove");
        yield return edit;
        var clear = UI.UI.ToolbarButton("trash", "Clear", () => _ = ConfirmClearAsync(), showLabel: true);
        clear.Foreground = Theme.Danger;
        AutomationProperties.SetAutomationId(clear, "history.clear");
        ToolTipService.SetToolTip(clear, "Clear recently viewed");
        yield return clear;
    }

    private void SetEditing(bool editing)
    {
        _editing = editing;
        _list.SelectionMode = editing ? ListViewSelectionMode.Multiple : ListViewSelectionMode.None;
        _list.IsItemClickEnabled = !editing;
        InvalidateChrome();
        MainWindow.Current.Announce(editing ? "Select entries to remove" : "Done editing");
    }

    // MARK: - Rows

    private void Reload()
    {
        _recents = AppHost.Library.RecentlyViewedNewestFirst().ToList();
        if (_recents.Count == 0 && _editing) { _editing = false; _list.SelectionMode = ListViewSelectionMode.None; _list.IsItemClickEnabled = true; }

        var selectedIds = _list.SelectedItems.Select(Entry).Where(e => e is not null).Select(e => e!.Ao3Id).ToHashSet();
        _list.Items.Clear();
        foreach (var item in _recents)
        {
            var container = Row(item);
            _list.Items.Add(container);
            if (_editing && selectedIds.Contains(item.Ao3Id)) _list.SelectedItems.Add(container);
        }

        _root.Children.Clear();
        _root.Children.Add(_recents.Count == 0 ? _empty : _list);
        InvalidateChrome();
    }

    /// <summary>A result row (WorkRow's content), like AO3 History's: reading
    /// badge, rating, words, reading time, chapters, kudos, summary and the
    /// bookmark button. An entry recorded before the history kept details
    /// borrows the Library's copy; with neither it shows title, author and
    /// fandom, and no bookmark button, since saving it would put an empty
    /// record in the Library.</summary>
    private ListViewItem Row(RecentlyViewed item)
    {
        var saved = item.HasDetails ? null : AppHost.Library.GetWork(item.Ao3Id);
        var summary = saved?.ToSummary() ?? item.ToSummary();
        ListViewItem? container = null;
        var (view, refresh) = WorkRow.Parts(summary,
            name => { if (container is not null) AutomationProperties.SetName(container, name); },
            showsBookmark: item.HasDetails || saved is not null);
        view.Margin = new Thickness(0, 8, 0, 8);
        view.Tag = item;

        container = new ListViewItem
        {
            Content = view,
            Tag = item,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        refresh();
        container.Loaded += (_, _) => refresh(); // follow state and reading may change elsewhere
        AutomationProperties.SetAutomationId(container, $"history.{item.Ao3Id}");
        AutomationProperties.SetHelpText(container, "Press Delete to remove it from Recently Viewed.");
        container.ContextFlyout = UI.UI.Menu(
            UI.UI.MenuItem("Open", () => Routes.OpenWork(item.Ao3Id), "book"),
            new MenuFlyoutSeparator(),
            UI.UI.MenuItem("Remove", () => Remove([item]), "trash", isDestructive: true));
        return container;
    }

    private static RecentlyViewed? Entry(object? element) => element switch
    {
        FrameworkElement { Tag: RecentlyViewed item } => item,
        _ => null,
    };

    // MARK: - Removing

    private void RemoveSelected()
    {
        var items = _list.SelectedItems.Select(Entry).OfType<RecentlyViewed>().ToList();
        if (items.Count == 0) return;
        Remove(items);
        SetEditing(false);
    }

    private void Remove(IReadOnlyList<RecentlyViewed> items)
    {
        var index = _recents.IndexOf(items[0]);
        foreach (var item in items) AppHost.Library.Delete(item);
        AppHost.Library.TrySave();
        Reload();
        MainWindow.Current.Announce(items.Count == 1 ? $"Removed {items[0].Title}" : $"Removed {items.Count} entries");
        // Keep keyboard focus in the list, on the row that took the removed one's place.
        if (_list.Items.Count > 0)
        {
            var next = _list.Items[Math.Clamp(index, 0, _list.Items.Count - 1)] as ListViewItem;
            next?.Focus(FocusState.Keyboard);
        }
    }

    private async Task ConfirmClearAsync()
    {
        var count = _recents.Count;
        if (count == 0) return;
        var confirmed = await Dialogs.ConfirmAsync("Clear recently viewed?",
            $"This removes all {count} entries. It won't delete anything from AO3 or your library.",
            "Clear All", destructive: true);
        if (!confirmed) return;
        foreach (var item in AppHost.Library.RecentlyViewedNewestFirst()) AppHost.Library.Delete(item);
        AppHost.Library.TrySave();
        _editing = false;
        _list.SelectionMode = ListViewSelectionMode.None;
        _list.IsItemClickEnabled = true;
        Reload();
        MainWindow.Current.Announce("Recently viewed cleared");
    }
}
