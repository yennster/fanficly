using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Fanficly.App.Views.Library;

/// <summary>
/// What the Library and folder screens do to saved stories and folders: the
/// row context menus (with every swipe and context-menu action of the Swift
/// views), the "Select Folders" sheet, folder create / rename / delete, and
/// download / remove-download for offline reading.
/// </summary>
internal static class LibraryActions
{
    private static LibraryStore Store => AppHost.Library;

    /// <summary>Works whose offline download is running (so the menu shows
    /// "Downloading…" and a second request is ignored).</summary>
    private static readonly HashSet<int> Downloading = [];

    /// <summary>Raised when something changed that the store's Changed event
    /// doesn't cover (an EPUB file appeared or was deleted).</summary>
    public static event Action? FilesChanged;

    /// <summary>Runs <paramref name="action"/> after the flyout has closed, so a
    /// dialog never presents from inside menu content.</summary>
    private static void AfterMenu(Func<Task> action) =>
        MainWindow.Current.DispatcherQueue.TryEnqueue(() => _ = action());

    private static MenuFlyoutItem Item(string text, string symbol, Action onClick, bool destructive = false,
                                       string? automationId = null, VirtualKey? key = null, string? keyText = null)
    {
        var item = UI.UI.MenuItem(text, onClick, symbol, destructive);
        if (automationId is not null) AutomationProperties.SetAutomationId(item, automationId);
        if (key is { } k)
        {
            // Shown in the menu only; the row handles the key itself.
            item.KeyboardAcceleratorTextOverride = keyText ?? k.ToString();
        }
        return item;
    }

    // MARK: - Row context menus

    /// <summary>The context menu for a saved story. <paramref name="folder"/> is
    /// the folder being shown (folder screens), or null in the Library.</summary>
    public static MenuFlyout WorkMenu(Work work, CustomFolder? folder)
    {
        var flyout = new MenuFlyout();
        flyout.Opening += (_, _) =>
        {
            flyout.Items.Clear();
            if (!work.IsInserted) return;
            flyout.Items.Add(Item("Read Now", "book", () => Routes.OpenSavedWork(work.Ao3Id), keyText: "Enter", key: VirtualKey.Enter));
            if (work.AuthorUsername.Length > 0)
                flyout.Items.Add(Item("More by this author", "person.crop.circle",
                    () => Routes.OpenAuthor(new AuthorRef(work.AuthorUsername, work.AuthorName))));
            flyout.Items.Add(Item(work.IsStarred ? "Unstar" : "Star", work.IsStarred ? "star.slash" : "star", () => ToggleStar(work)));
            flyout.Items.Add(Item(work.IsPinned ? "Unpin" : "Pin", work.IsPinned ? "pin.slash" : "pin", () => TogglePin(work)));
            if (folder is null)
            {
                // Following tracks new chapters, so Unfollow is only offered on
                // in-progress works (nothing new will ever drop on a complete one).
                if (work.IsFollowed && !work.IsComplete)
                    flyout.Items.Add(Item("Unfollow", "bookmark.slash", () => Unfollow(work)));
                flyout.Items.Add(Item("Folders...", "folder", () => AfterMenu(() => ShowFolderSheetAsync(work)), automationId: "library.row.folders"));
            }
            if (Downloading.Contains(work.Ao3Id))
                flyout.Items.Add(new MenuFlyoutItem { Text = "Downloading…", IsEnabled = false, Icon = new FontIcon { Glyph = Symbols.Glyph("arrow.down.circle"), FontFamily = Symbols.Font } });
            else if (WorkPersistence.EpubPath(work.Ao3Id) is not null)
                flyout.Items.Add(Item("Remove Download", "xmark.circle", () => AfterMenu(() => RemoveDownloadAsync(work))));
            else
                flyout.Items.Add(Item("Download for Offline", "arrow.down.circle", () => _ = DownloadAsync(work)));
            flyout.Items.Add(Item("Share Story...", "square.and.arrow.up", () => ShareService.ShareWork(work.Ao3Id, work.Title)));
            flyout.Items.Add(new MenuFlyoutSeparator());
            if (folder is null)
                flyout.Items.Add(Item("Delete from Library", "trash", () => Delete(work), destructive: true,
                    automationId: "library.row.delete", key: VirtualKey.Delete, keyText: "Del"));
            else
                flyout.Items.Add(Item("Remove from Folder", "folder.badge.minus", () => RemoveFromFolder([work], folder), destructive: true,
                    automationId: "folder.row.remove", key: VirtualKey.Delete, keyText: "Del"));
        };
        return flyout;
    }

    /// <summary>The context menu for a folder in the Folders list.</summary>
    public static MenuFlyout FolderMenu(CustomFolder folder, Action open)
    {
        var flyout = new MenuFlyout();
        flyout.Opening += (_, _) =>
        {
            flyout.Items.Clear();
            flyout.Items.Add(Item("Open", "folder", open, keyText: "Enter", key: VirtualKey.Enter));
            flyout.Items.Add(Item("Rename...", "pencil", () => AfterMenu(() => RenameFolderAsync(folder)), key: VirtualKey.F2, keyText: "F2"));
            flyout.Items.Add(new MenuFlyoutSeparator());
            flyout.Items.Add(Item("Delete", "trash", () => AfterMenu(() => DeleteFolderAsync(folder)), destructive: true,
                key: VirtualKey.Delete, keyText: "Del"));
        };
        return flyout;
    }

    // MARK: - Story actions

    public static void ToggleStar(Work work)
    {
        var starred = WorkPersistence.ToggleStar(work, Store);
        MainWindow.Current?.Announce(starred ? $"Starred {work.Title}" : $"Unstarred {work.Title}");
    }

    public static void TogglePin(Work work)
    {
        var pinned = WorkPersistence.TogglePin(work, Store);
        MainWindow.Current?.Announce(pinned ? $"Pinned {work.Title}" : $"Unpinned {work.Title}");
    }

    public static void Unfollow(Work work)
    {
        WorkPersistence.Unfollow(work, Store);
        MainWindow.Current?.Announce($"Unfollowed {work.Title}");
    }

    /// <summary>Removes the work (and its EPUB) from the library.</summary>
    public static void Delete(Work work)
    {
        if (!work.IsInserted) return;
        var title = work.Title;
        WorkPersistence.DeleteWork(work, Store);
        FilesChanged?.Invoke();
        MainWindow.Current?.Announce($"Deleted {title} from Library");
    }

    public static void Delete(IEnumerable<Work> works)
    {
        var list = works.Where(w => w.IsInserted).ToList();
        if (list.Count == 0) return;
        foreach (var w in list) WorkPersistence.DeleteWork(w, Store);
        FilesChanged?.Invoke();
        MainWindow.Current?.Announce(list.Count == 1 ? $"Deleted {list[0].Title} from Library" : $"Deleted {list.Count} stories from Library");
    }

    public static void RemoveFromFolder(IReadOnlyList<Work> works, CustomFolder folder)
    {
        if (works.Count == 0) return;
        WorkPersistence.RemoveFromFolder(works, folder, Store);
        MainWindow.Current?.Announce(works.Count == 1
            ? $"Removed {works[0].Title} from {folder.Name}"
            : $"Removed {works.Count} stories from {folder.Name}");
    }

    /// <summary>Saves the full work (chapters) and its EPUB for offline reading,
    /// like the reader's "Save offline".</summary>
    public static async Task DownloadAsync(Work work)
    {
        var id = work.Ao3Id;
        var title = work.Title;
        if (!Downloading.Add(id)) return;
        MainWindow.Current?.Announce($"Downloading {title} for offline reading.");
        FilesChanged?.Invoke();
        try
        {
            // Make sure the chapters are stored too, so it reads offline.
            try
            {
                var payload = await AppHost.Client.FetchWorkAsync(id);
                if (work.IsInserted) WorkPersistence.Upsert(payload, Store);
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                AppHost.Log($"Fetching {id} before download failed: {e.Message}");
            }
            await AppHost.Client.DownloadEpubAsync(id);
            MainWindow.Current?.ShowMessage("Downloaded for offline reading", title);
        }
        catch (Exception e)
        {
            MainWindow.Current?.ShowMessage("Couldn't download for offline", e.Message, InfoBarSeverity.Error);
        }
        finally
        {
            Downloading.Remove(id);
            FilesChanged?.Invoke();
        }
    }

    /// <summary>Deletes the offline copy (EPUB and stored chapters); the story
    /// stays in the Library and reads on demand.</summary>
    public static async Task RemoveDownloadAsync(Work work)
    {
        var ok = await Dialogs.ConfirmAsync(
            $"Remove the download of “{work.Title}”?",
            "The story stays in your Library and loads from AO3 when you read it.",
            "Remove Download", destructive: true);
        if (!ok || !work.IsInserted) return;
        if (WorkPersistence.EpubPath(work.Ao3Id) is { } path)
        {
            try { File.Delete(path); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { AppHost.Log($"Removing {path} failed: {e.Message}"); }
        }
        foreach (var chapter in work.Chapters.ToList()) Store.Delete(chapter);
        Store.TrySave();
        LibrarySyncManager.QueueBackupShared(Store);
        FilesChanged?.Invoke();
        MainWindow.Current?.Announce($"Removed the download of {work.Title}");
    }

    // MARK: - Folders

    /// <summary>"New Folder": name prompt, then create (optionally with a work in it).</summary>
    public static async Task<CustomFolder?> CreateFolderAsync(Work? work = null)
    {
        var name = await Dialogs.PromptAsync("New Folder", "Folder Name", "Create", message: "Enter a name for the new folder.");
        if (name is null) return null;
        return CreateFolder(name, work);
    }

    public static CustomFolder? CreateFolder(string name, Work? work = null)
    {
        var trimmed = name.Trim();
        if (trimmed.Length == 0) return null;
        if (Store.GetFolder(trimmed) is { } existing)
        {
            MainWindow.Current?.ShowMessage($"A folder named “{trimmed}” already exists", severity: InfoBarSeverity.Warning);
            if (work is not null && !work.Folders.Contains(existing)) WorkPersistence.ToggleFolder(work, existing, Store);
            return existing;
        }
        var folder = WorkPersistence.CreateFolder(trimmed, Store, work);
        LibraryHooks.UpdateWidgetData?.Invoke(Store);
        if (folder is not null) MainWindow.Current?.Announce($"Created folder {folder.Name}");
        return folder;
    }

    /// <summary>Renames a folder (a folder's name is its identity, so this makes
    /// a new folder with the same works and creation date). Returns the new
    /// name, or null when nothing changed.</summary>
    public static async Task<string?> RenameFolderAsync(CustomFolder folder)
    {
        if (!folder.IsInserted) return null;
        var name = await Dialogs.PromptAsync("Rename Folder", "Folder Name", "Rename", initial: folder.Name);
        if (name is null || name == folder.Name || !folder.IsInserted) return null;
        if (Store.GetFolder(name) is not null)
        {
            await Dialogs.AlertAsync("Name Already Used", $"There's already a folder named “{name}”.");
            return null;
        }
        var renamed = new CustomFolder(name, folder.CreatedAt);
        Store.Insert(renamed);
        foreach (var work in folder.Works.ToList()) work.Folders.Add(renamed);
        Store.Delete(folder);
        Store.TrySave();
        LibrarySyncManager.QueueBackupShared(Store);
        LibraryHooks.UpdateWidgetData?.Invoke(Store);
        MainWindow.Current?.Announce($"Renamed folder to {name}");
        return name;
    }

    /// <summary>Deletes a folder; its stories stay in the Library.</summary>
    public static async Task<bool> DeleteFolderAsync(CustomFolder folder)
    {
        if (!folder.IsInserted) return false;
        var ok = await Dialogs.ConfirmAsync($"Delete “{folder.Name}”?",
            "The stories in it stay in your Library.", "Delete Folder", destructive: true);
        if (!ok || !folder.IsInserted) return false;
        var name = folder.Name;
        WorkPersistence.DeleteFolder(folder, Store);
        LibraryHooks.UpdateWidgetData?.Invoke(Store);
        MainWindow.Current?.Announce($"Deleted folder {name}");
        return true;
    }

    /// <summary>The "Select Folders" sheet (FolderSelectionSheet): toggle the
    /// work in and out of any number of folders, remove it from all of them, or
    /// make a new folder with it inside. A dialog can't open over a dialog on
    /// Windows, so "New Folder" is an inline name box here.</summary>
    public static async Task ShowFolderSheetAsync(Work work)
    {
        if (!work.IsInserted) return;
        var content = UI.UI.VStack(8);
        content.MinWidth = 340;

        var removeAll = UI.UI.Button("Remove from All Folders", () => { }, "folder.badge.minus", UI.UI.ButtonKind.Destructive);
        removeAll.HorizontalAlignment = HorizontalAlignment.Stretch;
        removeAll.HorizontalContentAlignment = HorizontalAlignment.Left;
        AutomationProperties.SetAutomationId(removeAll, "folders.removeAll");

        var list = UI.UI.VStack(2);
        AutomationProperties.SetName(list, "All Folders");

        void Rebuild()
        {
            list.Children.Clear();
            var folders = Store.Folders();
            if (folders.Count == 0)
                list.Children.Add(UI.UI.Secondary("No folders yet. Name one below to create it.", Theme.Style.Footnote).Margin(4, 4, 4, 4));
            foreach (var folder in folders)
            {
                var box = new CheckBox
                {
                    Content = UI.UI.Label("folder", folder.Name),
                    IsChecked = work.Folders.Contains(folder),
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    Padding = new Thickness(8, 6, 8, 6),
                };
                AutomationProperties.SetName(box, folder.Name);
                AutomationProperties.SetAutomationId(box, $"folders.toggle.{folder.Name}");
                var target = folder;
                box.Click += (_, _) =>
                {
                    var nowIn = WorkPersistence.ToggleFolder(work, target, Store);
                    box.IsChecked = nowIn;
                    removeAll.IsEnabled = work.Folders.Count > 0;
                    MainWindow.Current?.Announce(nowIn ? $"Added to {target.Name}" : $"Removed from {target.Name}");
                };
                list.Children.Add(box);
            }
            removeAll.IsEnabled = work.Folders.Count > 0;
        }

        removeAll.Click += (_, _) =>
        {
            WorkPersistence.ClearFolders(work, Store);
            Rebuild();
            MainWindow.Current?.Announce("Removed from all folders");
        };

        var nameBox = new TextBox { PlaceholderText = "Folder Name", MinWidth = 200 };
        AutomationProperties.SetName(nameBox, "New folder name");
        AutomationProperties.SetAutomationId(nameBox, "folders.newName");
        var create = UI.UI.Button("Create", () => { }, "folder.badge.plus");
        AutomationProperties.SetName(create, "New folder");
        AutomationProperties.SetAutomationId(create, "folders.create");
        create.IsEnabled = false;
        void CreateFromBox()
        {
            if (nameBox.Text.Trim().Length == 0) return;
            CreateFolder(nameBox.Text, work);
            nameBox.Text = "";
            Rebuild();
        }
        create.Click += (_, _) => CreateFromBox();
        nameBox.TextChanged += (_, _) => create.IsEnabled = nameBox.Text.Trim().Length > 0;
        nameBox.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter) { e.Handled = true; CreateFromBox(); }
        };
        var newRow = UI.UI.Grid("*,Auto", columnSpacing: 8);
        newRow.Children.Add(nameBox.Col(0));
        newRow.Children.Add(create.Col(1));

        content.Children.Add(UI.UI.Secondary(work.Title, Theme.Style.Subheadline, maxLines: 2));
        content.Children.Add(removeAll);
        content.Children.Add(UI.UI.SectionHeader("All Folders"));
        content.Children.Add(list);
        content.Children.Add(UI.UI.SectionHeader("New Folder"));
        content.Children.Add(newRow);
        Rebuild();

        await Dialogs.SheetAsync("Select Folders", content, close: "Done", width: 480);
    }

    // MARK: - Keyboard on rows

    /// <summary>Delete removes, F2 renames (folders), Enter opens (native for buttons).</summary>
    public static void HandleRowKeys(UIElement row, Action? onDelete, Action? onRename = null)
    {
        row.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Delete && onDelete is not null && MainWindow.CurrentModifiers() == VirtualKeyModifiers.None)
            {
                e.Handled = true;
                onDelete();
            }
            else if (e.Key == VirtualKey.F2 && onRename is not null)
            {
                e.Handled = true;
                onRename();
            }
        };
    }

    /// <summary>Moves keyboard focus into a list after it rebuilds.</summary>
    public static void FocusFirst(DependencyObject root)
    {
        if (FocusManager.FindFirstFocusableElement(root) is Control c) c.Focus(FocusState.Keyboard);
    }

    /// <summary>Whether keyboard focus is inside <paramref name="container"/> — a
    /// rebuilt list puts focus back on the same row when it was.</summary>
    public static bool IsFocusWithin(FrameworkElement container)
    {
        if (container.XamlRoot is null) return false;
        var node = FocusManager.GetFocusedElement(container.XamlRoot) as DependencyObject;
        while (node is not null)
        {
            if (ReferenceEquals(node, container)) return true;
            node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node);
        }
        return false;
    }
}
