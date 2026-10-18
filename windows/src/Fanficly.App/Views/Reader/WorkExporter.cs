using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// Drives a work export (WorkExporter + WorkExportButton): downloads the work in
/// the chosen AO3 format through the client (so the throttle applies), then hands
/// the file to Windows' share sheet — or, from "Save a copy as", to a save dialog.
///
/// Owned by the screen, never by menu content (CLAUDE.md: a sheet or alert
/// attached inside a menu has no live anchor once the menu closes). The menu
/// items only start the export; everything presented afterwards — the share
/// sheet, the save dialog, the "Export failed" alert — comes from the window.
/// </summary>
internal sealed class WorkExporter
{
    public bool IsExporting { get; private set; }

    /// <summary>Raised when <see cref="IsExporting"/> changes (the screen swaps its menu icon for a spinner).</summary>
    public event Action? Changed;

    /// <summary>The "Share &amp; export…" submenu: one item per AO3 format to share,
    /// and "Save a copy as" with the same formats.</summary>
    public MenuFlyoutSubItem Menu(int workId, Func<string> title)
    {
        var share = new MenuFlyoutSubItem
        {
            Text = "Share & export…",
            Icon = Symbols.Icon("square.and.arrow.up"),
            IsEnabled = !IsExporting,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(share, "Share and export");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(share, "work.export");
        foreach (var format in WorkExportFormatExtensions.All)
            share.Items.Add(UI.UI.MenuItem(format.DisplayName(), () => Start(workId, title(), format, saveAs: false), format.Icon()));
        share.Items.Add(new MenuFlyoutSeparator());
        var saveAs = new MenuFlyoutSubItem
        {
            Text = "Save a copy as",
            Icon = Symbols.Icon("square.and.arrow.down"),
        };
        foreach (var format in WorkExportFormatExtensions.All)
            saveAs.Items.Add(UI.UI.MenuItem($"{format.DisplayName()}…", () => Start(workId, title(), format, saveAs: true), format.Icon()));
        share.Items.Add(saveAs);
        return share;
    }

    private void Start(int workId, string title, WorkExportFormat format, bool saveAs) =>
        // Let the menu finish closing before anything is presented.
        MainWindow.Current.DispatcherQueue.TryEnqueue(() => _ = ExportAsync(workId, title, format, saveAs));

    public async Task ExportAsync(int workId, string title, WorkExportFormat format, bool saveAs)
    {
        if (IsExporting) return;
        IsExporting = true;
        Changed?.Invoke();
        // The download can take several seconds (AO3's throttle): say something is happening.
        MainWindow.Current.Announce(saveAs
            ? $"Downloading {format.DisplayName()}. The save dialog will open when it's ready."
            : $"Downloading {format.DisplayName()}. The share sheet will open when it's ready.");
        try
        {
            var path = await AppHost.Client.ExportWorkAsync(workId, format, title);
            var file = await StorageFile.GetFileFromPathAsync(path);
            if (saveAs) await SaveCopyAsync(file, title, format);
            else ShareService.Share(file, title);
        }
        catch (Exception e)
        {
            AppHost.Log($"Export failed: {e}");
            await Dialogs.AlertAsync("Export failed", $"Couldn't download the {format.DisplayName()} file: {e.Message}");
        }
        finally
        {
            IsExporting = false;
            Changed?.Invoke();
        }
    }

    private static async Task SaveCopyAsync(StorageFile file, string title, WorkExportFormat format)
    {
        var picker = new FileSavePicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            SuggestedFileName = SafeFileName(title),
        };
        picker.FileTypeChoices.Add(format.DisplayName(), [$".{format.Ext()}"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Current));
        var target = await picker.PickSaveFileAsync();
        if (target is null) return;
        await file.CopyAndReplaceAsync(target);
        MainWindow.Current.ShowMessage("Saved", target.Name);
    }

    private static string SafeFileName(string title)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var cleaned = new string(title.Select(c => invalid.Contains(c) ? ' ' : c).ToArray()).Trim();
        return cleaned.Length == 0 ? "Work" : cleaned;
    }
}

/// <summary>Windows' share sheet for a file, from the app window (ShareSheet).</summary>
internal static class ShareService
{
    private static DataTransferManager? _manager;
    private static (StorageFile File, string Title)? _pending;

    public static void Share(StorageFile file, string title)
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Current);
        if (_manager is null)
        {
            _manager = DataTransferManagerInterop.GetForWindow(hwnd);
            _manager.DataRequested += OnDataRequested;
        }
        _pending = (file, title);
        DataTransferManagerInterop.ShowShareUIForWindow(hwnd);
    }

    private static void OnDataRequested(DataTransferManager sender, DataRequestedEventArgs args)
    {
        if (_pending is not { } pending) return;
        var data = args.Request.Data;
        data.Properties.Title = pending.Title.Length == 0 ? pending.File.Name : pending.Title;
        data.Properties.Description = pending.File.Name;
        data.SetStorageItems([pending.File]);
    }
}
