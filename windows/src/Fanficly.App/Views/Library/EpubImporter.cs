using Fanficly.App.Services;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace Fanficly.App.Views.Library;

/// <summary>Imports EPUB files into the Library (Swift: <c>EPUBImportCenter</c>):
/// from the Library's Import EPUB button, a file opened with Fanficly from
/// File Explorer, or EPUBs dropped on the window. Parsing
/// (<see cref="EpubImport.Parse"/>) runs on the pool; saving runs on the UI
/// thread (<see cref="RecordsThread"/>). A dialog says how it went.</summary>
internal static class EpubImporter
{
    public static bool IsImporting { get; private set; }

    /// <summary>Raised on the UI thread when an import starts or ends.</summary>
    public static event Action? IsImportingChanged;

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

    /// <summary>Imports each .epub file in turn; other files are ignored.</summary>
    public static async Task ImportAsync(IEnumerable<IStorageItem> items)
    {
        var files = items.OfType<StorageFile>()
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
