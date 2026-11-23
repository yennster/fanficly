using Fanficly.App.Services;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace Fanficly.App.Views.Library;

/// <summary>Imports EPUB files into the Library (Swift: <c>EPUBImportCenter</c>):
/// from the Library's Import EPUB and Import Folder buttons, files or folders
/// dropped on the window, or a file opened with Fanficly from File Explorer.
/// A folder brings in every EPUB under it (#418, <see cref="EpubFolderImport"/>),
/// with progress and Cancel in <see cref="EpubImportBanner"/>. Parsing
/// (<see cref="EpubImport.Parse"/>) runs on the pool; saving runs on the UI
/// thread (<see cref="RecordsThread"/>). A dialog says how it went.</summary>
internal static class EpubImporter
{
    public static bool IsImporting { get; private set; }

    /// <summary>Raised on the UI thread when an import starts or ends.</summary>
    public static event Action? IsImportingChanged;

    /// <summary>A folder import's place (files read, EPUBs found); null when none runs.</summary>
    public static (int Done, int Total)? FolderProgress { get; private set; }

    /// <summary>Raised on the UI thread when <see cref="FolderProgress"/> changes.</summary>
    public static event Action? FolderProgressChanged;

    private static CancellationTokenSource? _folderCancel;

    /// <summary>Stops a folder import after the file it's on. What it saved stays.</summary>
    public static void CancelFolderImport() => _folderCancel?.Cancel();

    /// <summary>The Library's Import Folder button: picks a folder and imports
    /// every EPUB in it and its subfolders.</summary>
    public static async Task PickFolderAndImportAsync()
    {
        if (IsImporting) return;
        StorageFolder? folder;
        try
        {
            var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.Downloads };
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Current));
            folder = await picker.PickSingleFolderAsync();
        }
        catch (Exception e)
        {
            AppHost.Log($"Folder picker failed: {e.Message}");
            await Dialogs.AlertAsync("Couldn't Choose a Folder", e.Message);
            return;
        }
        if (folder is null) return;
        if (string.IsNullOrEmpty(folder.Path))
        {
            // A phone over USB (MTP) or another virtual location has no path to read.
            await Dialogs.AlertAsync("Couldn't Import That Folder",
                "Fanficly can only read folders on this PC's drives. Copy the EPUBs to a folder here first.");
            return;
        }
        await ImportFolderAsync([folder.Path], []);
    }

    public static async Task PickAndImportAsync()
    {
        if (IsImporting) return;
        IReadOnlyList<StorageFile> files;
        try
        {
            var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Downloads };
            picker.FileTypeFilter.Add(".epub");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Current));
            files = await picker.PickMultipleFilesAsync();
        }
        catch (Exception e)
        {
            AppHost.Log($"File picker failed: {e.Message}");
            await Dialogs.AlertAsync("Couldn't Choose a File", e.Message);
            return;
        }
        await ImportAsync(files);
    }

    /// <summary>Imports each .epub file in turn; other files are ignored. Folders
    /// (dropped on the window) bring in every EPUB under them, with the files
    /// beside them, as a folder import.</summary>
    public static async Task ImportAsync(IEnumerable<IStorageItem> items)
    {
        var list = items.ToList();
        var folders = list.OfType<StorageFolder>().Select(f => f.Path).Where(p => !string.IsNullOrEmpty(p)).ToList();
        if (folders.Count > 0)
        {
            var loose = list.OfType<StorageFile>()
                .Where(f => string.Equals(f.FileType, ".epub", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrEmpty(f.Path))
                .Select(f => f.Path).ToList();
            await ImportFolderAsync(folders, loose);
            return;
        }
        var files = list.OfType<StorageFile>()
            .Where(f => string.Equals(f.FileType, ".epub", StringComparison.OrdinalIgnoreCase)).ToList();
        if (files.Count == 0 || IsImporting) return;
        SetImporting(true);
        MainWindow.Current.Announce(files.Count == 1 ? "Importing EPUB" : $"Importing {files.Count} EPUBs");
        var saved = new List<string>();
        var failures = new List<string>();
        foreach (var file in files)
        {
            try
            {
                var data = (await FileIO.ReadBufferAsync(file)).ToArray();
                var payload = await Task.Run(() => EpubImport.Parse(data));
                // Importing a work deleted a moment ago keeps it (#169).
                UndoQueue.Shared.Cancel(UndoQueue.Keys.Work(payload.Summary.Id));
                var work = EpubImport.Save(payload, data, AppHost.Library);
                saved.Add(work.Title);
            }
            catch (EpubImportException e)
            {
                failures.Add($"{file.DisplayName}: {e.Message}");
            }
            catch (Exception e)
            {
                AppHost.Log($"EPUB import failed: {e.Message}");
                failures.Add($"{file.DisplayName}: {e.Message}");
            }
        }
        SetImporting(false);
        if (saved.Count > 0) LibraryActions.NotifyFilesChanged();
        var (title, message) = Outcome(saved, failures);
        await Dialogs.AlertAsync(title, message);
    }

    /// <summary>Imports every EPUB under <paramref name="folders"/> (subfolders
    /// included) plus <paramref name="files"/>, one at a time, with progress,
    /// Cancel, Narrator updates and one backup at the end.</summary>
    private static async Task ImportFolderAsync(IReadOnlyList<string> folders, IReadOnlyList<string> files)
    {
        if (IsImporting) return;
        SetImporting(true);
        using var cancel = new CancellationTokenSource();
        _folderCancel = cancel;
        SetFolderProgress((0, 0));
        EpubFolderImportResult result;
        try
        {
            var found = await Task.Run(() => folders.SelectMany(EpubFolderImport.FindEpubs)
                .Concat(files).Distinct(StringComparer.OrdinalIgnoreCase).ToList());
            var previous = 0;
            result = await EpubFolderImport.ImportAsync(found, AppHost.Library, (done, total) =>
            {
                SetFolderProgress((done, total));
                // Narrator hears the count at the start and every tenth of the way.
                if (total > 0 && (done == 0 || (total >= 10 && done * 10 / total > previous * 10 / total && done < total)))
                    MainWindow.Current.Announce($"Importing {done} of {total}");
                previous = done;
            }, cancel.Token);
        }
        catch (Exception e)
        {
            AppHost.Log($"Folder import failed: {e.Message}");
            result = new EpubFolderImportResult { Found = 1, Failures = [e.Message] };
        }
        finally
        {
            _folderCancel = null;
            SetFolderProgress(null);
            SetImporting(false);
        }
        if (result.Imported + result.Updated > 0) LibraryActions.NotifyFilesChanged();
        // Narrator reads the dialog itself.
        var (title, message) = EpubFolderImport.Outcome(result);
        await Dialogs.AlertAsync(title, message);
    }

    private static void SetFolderProgress((int Done, int Total)? value)
    {
        FolderProgress = value;
        FolderProgressChanged?.Invoke();
    }

    /// <summary>The dialog an import ends with (Swift: <c>EPUBImportCenter.outcome</c>).</summary>
    internal static (string Title, string Message) Outcome(IReadOnlyList<string> saved, IReadOnlyList<string> failures)
    {
        var failed = string.Join("\n", failures);
        return (saved.Count, failures.Count == 0) switch
        {
            (0, _) => ("Couldn't import", failed),
            (1, true) => ("Imported", $"“{saved[0]}” is in your Library and reads offline."),
            (_, true) => ("Imported", $"{saved.Count} stories are in your Library and read offline."),
            _ => ($"Imported {saved.Count} of {saved.Count + failures.Count}", failed),
        };
    }

    private static void SetImporting(bool value)
    {
        IsImporting = value;
        IsImportingChanged?.Invoke();
    }
}
