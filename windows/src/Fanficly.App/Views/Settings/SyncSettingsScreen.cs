using Fanficly.App.Services;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace Fanficly.App.Views.Settings;

/// <summary>
/// Settings → Sync across devices: the Windows form of SettingsView's "iCloud
/// Sync" section. There's no iCloud container on Windows, so the library backup
/// (<c>library_backup.json</c>, the Apple apps' format) and the synced settings
/// file live in a folder the user picks — OneDrive (the default), Google Drive,
/// Dropbox, Box, iCloud Drive (iCloud for Windows) or any other synced folder —
/// and that folder's own app carries them to other devices.
/// Pointed at the same folder an iPhone or Mac uses, they share one backup.
///
/// The toggle is the Apple key (<c>settings.iCloudSyncEnabled</c>). Backups
/// merge with the file already there and restores are forward-only merges
/// (<see cref="LibrarySyncManager"/>), so nothing here can lose data.
/// </summary>
public sealed class SyncSettingsScreen : Screen
{
    private readonly Grid _host = new();
    private bool _isRestoring;

    public SyncSettingsScreen() => Title = "Sync";

    private static LibrarySyncManager Sync => AppHost.Sync;
    private static bool IsEnabled => KeyValueStores.Default.GetBool(LibrarySyncManager.SyncEnabledKey);

    protected override FrameworkElement Build()
    {
        Render();
        return _host;
    }

    public override void OnAppearing()
    {
        if (IsBuilt) Render();
    }

    private void Render()
    {
        var offset = _host.Children.Count > 0 && _host.Children[0] is ScrollViewer old ? old.VerticalOffset : 0;
        var page = SettingsKit.Page(UI.UI.VStack(18, MainSection(), FolderSection()), "settings.sync.page");
        if (offset > 0) page.Loaded += (_, _) => page.ChangeView(null, offset, null, disableAnimation: true);
        _host.Children.Clear();
        _host.Children.Add(page);
    }

    // MARK: - Sections

    private StackPanel MainSection()
    {
        var enabled = IsEnabled;
        var toggle = UI.UI.Toggle(enabled, on => _ = SetEnabledAsync(on), "Sync across devices");
        toggle.IsEnabled = !_isRestoring;
        AutomationProperties.SetAutomationId(toggle, "settings.sync.toggle");
        var rows = new List<UIElement>
        {
            UI.UI.SettingsRow("Sync across devices", toggle,
                "Back up your library and reader settings to a sync folder", "arrow.triangle.2.circlepath"),
        };

        if (enabled)
        {
            var last = Sync.LastBackupDate;
            rows.Add(UI.UI.SettingsRow("Last synced",
                UI.UI.Secondary(last is { } d ? d.ToLocalTime().ToString("g") : "Never", Theme.Style.Body)));
            rows.Add(SettingsKit.ActionRow("Back Up Now", BackUpNow, "icloud.and.arrow.up", automationId: "settings.sync.backup")
                .Also(b => b.IsEnabled = !_isRestoring && Sync.SyncFolder is not null));
            if (Sync.IsBackupAvailable || _isRestoring)
                rows.Add(RestoreRow("Restore Now", enableAfter: false));
            rows.Add(SettingsKit.ActionRow("Clear Synced Data", () => _ = ClearAsync(), "trash", destructive: true,
                automationId: "settings.sync.clear").Also(b => b.IsEnabled = !_isRestoring && Sync.IsBackupAvailable));
        }
        else
        {
            rows.Add(RestoreRow("Restore Library from Sync Folder", enableAfter: true));
        }

        return UI.UI.Section("Sync", rows,
            footer: "Fanficly has no servers, so it syncs through a folder you already sync: OneDrive, Google Drive, Dropbox, iCloud Drive or any other. Your library — saved works, downloaded chapters, folders, reading positions and stats — and your reader profiles are written there, and that service's app carries them to your other devices. Point an iPhone, iPad or Mac and this PC at the same backup and they share one library. Backups merge with what's already in the folder and restores only ever move things forward, so a device with less can never erase another's.");
    }

    private Button RestoreRow(string title, bool enableAfter)
    {
        Button row;
        if (_isRestoring)
        {
            var grid = UI.UI.Grid("*,Auto", columnSpacing: 8);
            grid.Children.Add(UI.UI.Text("Restoring…", foreground: Theme.Accent).Col(0));
            grid.Children.Add(new ProgressRing { IsActive = true, Width = 18, Height = 18 }.Col(1));
            row = UI.UI.NavRow(grid, () => { }, "Restoring", chevron: false);
            row.IsEnabled = false;
        }
        else
        {
            row = SettingsKit.ActionRow(title, () => _ = RestoreAsync(enableAfter), "icloud.and.arrow.down");
        }
        AutomationProperties.SetAutomationId(row, "settings.sync.restore");
        return row;
    }

    private StackPanel FolderSection()
    {
        var folder = Sync.SyncFolder;
        var choose = UI.UI.Button("Choose…", () => _ = ChooseFolderAsync(), "folder");
        choose.IsEnabled = !_isRestoring;
        AutomationProperties.SetAutomationId(choose, "settings.sync.chooseFolder");
        AutomationProperties.SetName(choose, "Choose sync folder");
        var suggestions = SuggestedFolders();
        var subtitle = folder
            ?? (suggestions.Count > 0 ? $"Not chosen yet. Turning on sync uses {suggestions[0].Label}." : "Not chosen");
        var folderRow = UI.UI.SettingsRow("Sync folder", choose, subtitle, "folder");

        var rows = new List<UIElement> { folderRow };
        foreach (var (label, path) in suggestions)
        {
            if (string.Equals(path, folder, StringComparison.OrdinalIgnoreCase)) continue;
            rows.Add(SettingsKit.ActionRow($"Use {label}", () => _ = UseFolderAsync(path, create: true), "folder.fill",
                tooltip: path).Also(b => b.IsEnabled = !_isRestoring));
        }
        if (folder is not null)
        {
            rows.Add(SettingsKit.ActionRow("Open Sync Folder", () => _ = OpenFolderAsync(folder), "arrow.up.right.square",
                automationId: "settings.sync.openFolder"));
        }
        return UI.UI.Section("Sync folder", rows,
            footer: "Any folder that a sync app keeps up to date works: OneDrive, Google Drive, Dropbox, Box, iCloud Drive or another. Fanficly lists the ones it finds on this PC; Choose… picks any other. To share a library with an iPhone, iPad or Mac, use the same service on every device. The backup is library_backup.json; reader profiles and your last-read story go in fanficly-settings-sync.json beside it.");
    }

    /// <summary>The cloud services this PC syncs (<see cref="SyncFolderSuggestions"/>).</summary>
    private static IReadOnlyList<SyncFolderSuggestion> SuggestedFolders()
    {
        try
        {
            return SyncFolderSuggestions.Find();
        }
        catch (Exception e)
        {
            AppHost.Log($"Sync folder suggestions failed: {e.Message}");
            return [];
        }
    }

    // MARK: - Actions

    private static async Task OpenFolderAsync(string folder)
    {
        try
        {
            if (!await Windows.System.Launcher.LaunchFolderPathAsync(folder))
                await Dialogs.AlertAsync("Couldn't Open the Folder", folder);
        }
        catch (Exception e)
        {
            AppHost.Log($"Opening the sync folder failed: {e.Message}");
            await Dialogs.AlertAsync("Couldn't Open the Folder", e.Message);
        }
    }

    private static void ApplyFolderToStores(string? folder)
    {
        Sync.SyncFolder = folder;
        if (KeyValueStores.Synced is SyncFolderKeyValueStore synced)
            synced.Folder = IsEnabled ? folder : null;
    }

    private async Task SetEnabledAsync(bool on)
    {
        if (on == IsEnabled) return;
        if (!on)
        {
            KeyValueStores.Default.SetBool(LibrarySyncManager.SyncEnabledKey, false);
            ApplyFolderToStores(Sync.SyncFolder);
            MainWindow.Current.Announce("Sync turned off");
            Render();
            return;
        }
        if (Sync.SyncFolder is null && !UseDefaultFolder() && !await PickFolderAsync())
        {
            Render(); // no folder chosen: the toggle goes back off
            return;
        }
        KeyValueStores.Default.SetBool(LibrarySyncManager.SyncEnabledKey, true);
        ApplyFolderToStores(Sync.SyncFolder);
        MainWindow.Current.Announce("Sync turned on");
        await MergeFromFolderAsync();
    }

    /// <summary>After sync is turned on or the folder changes: bring in what's
    /// already there (a forward-only merge, as launch does), then back up.</summary>
    private async Task MergeFromFolderAsync()
    {
        if (Sync.IsBackupAvailable)
        {
            await RestoreAsync(enableAfter: false);
        }
        else
        {
            Sync.QueueBackup(AppHost.Library);
            Render();
        }
    }

    /// <summary>With no folder chosen yet, sync goes to the first service found
    /// (OneDrive when it's set up, as it is on most PCs). False when there's
    /// none, or its folder can't be made.</summary>
    private static bool UseDefaultFolder()
    {
        if (SuggestedFolders() is not [var first, ..]) return false;
        try
        {
            Directory.CreateDirectory(first.Path);
        }
        catch (Exception e)
        {
            AppHost.Log($"Default sync folder failed: {e.Message}");
            return false;
        }
        SetFolder(first.Path);
        return true;
    }

    private async Task ChooseFolderAsync()
    {
        if (await PickFolderAsync() && IsEnabled) await MergeFromFolderAsync();
        else Render();
    }

    private async Task UseFolderAsync(string path, bool create)
    {
        try
        {
            if (create) Directory.CreateDirectory(path);
        }
        catch (Exception e)
        {
            await Dialogs.AlertAsync("Couldn't Use That Folder", e.Message);
            return;
        }
        SetFolder(path);
        if (IsEnabled) await MergeFromFolderAsync();
        else Render();
    }

    private static void SetFolder(string path)
    {
        KeyValueStores.Default.SetString(AppHost.SyncFolderKey, path);
        ApplyFolderToStores(path);
        MainWindow.Current.Announce($"Sync folder set to {path}");
    }

    /// <summary>Shows the folder picker; true when a folder was chosen.</summary>
    private static async Task<bool> PickFolderAsync()
    {
        try
        {
            var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Current));
            var folder = await picker.PickSingleFolderAsync();
            if (folder is null || string.IsNullOrEmpty(folder.Path)) return false;
            SetFolder(folder.Path);
            return true;
        }
        catch (Exception e)
        {
            AppHost.Log($"Folder picker failed: {e.Message}");
            await Dialogs.AlertAsync("Couldn't Choose a Folder", e.Message);
            return false;
        }
    }

    private void BackUpNow()
    {
        try
        {
            Sync.Backup(AppHost.Library);
            MainWindow.Current.ShowMessage("Backed Up", "Your library was saved to the sync folder.");
        }
        catch (Exception e)
        {
            AppHost.Log($"Backup failed: {e.Message}");
            _ = Dialogs.AlertAsync("Backup Failed", "Couldn't write to the sync folder. Make sure it's available and try again.");
        }
        Render();
    }

    private async Task RestoreAsync(bool enableAfter)
    {
        if (_isRestoring) return;
        if (Sync.SyncFolder is null && !await PickFolderAsync())
        {
            Render();
            return;
        }
        _isRestoring = true;
        Render();
        MainWindow.Current.Announce("Restoring library");
        bool success;
        try
        {
            success = await Sync.RestoreAsync(AppHost.Library);
        }
        catch (Exception e)
        {
            AppHost.Log($"Restore failed: {e}");
            success = false;
        }
        _isRestoring = false;
        if (success)
        {
            if (enableAfter)
            {
                KeyValueStores.Default.SetBool(LibrarySyncManager.SyncEnabledKey, true);
                ApplyFolderToStores(Sync.SyncFolder);
            }
            RestoreDownloadCenter.Shared.ProposeRedownload(AppHost.Library);
            Render();
            await Dialogs.AlertAsync("Library Restored", "Your library and settings have been successfully restored from the sync folder.");
        }
        else
        {
            Render();
            await Dialogs.AlertAsync("Restore Failed", "Could not restore a backup from the sync folder. Make sure the folder is available (and finished syncing) and try again.");
        }
    }

    private async Task ClearAsync()
    {
        if (!await Dialogs.ConfirmAsync("Clear Synced Data?",
                "This deletes the library backup from the sync folder, for every device that uses it. Your library on this PC is not affected.",
                "Clear", destructive: true))
            return;
        if (Sync.Clear()) MainWindow.Current.Announce("Synced data cleared");
        Render();
    }
}
