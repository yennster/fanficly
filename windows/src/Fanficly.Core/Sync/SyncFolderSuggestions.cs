using System.Text.Json;

namespace Fanficly.Core;

/// <summary>A sync folder Settings → Sync can offer: the service's name and
/// the Fanficly folder inside it (created when the user picks it).</summary>
public sealed record SyncFolderSuggestion(string Label, string Path);

/// <summary>
/// Finds the cloud services this PC already syncs, so Settings → Sync can offer
/// a one-click folder in each: OneDrive (personal and work), Google Drive for
/// desktop, Dropbox, Box and iCloud Drive (iCloud for Windows). There's no
/// Swift counterpart: the Apple apps always use their iCloud container. Any
/// other synced folder works too, through the folder picker.
///
/// Pure over a <see cref="Machine"/> snapshot so it can be tested with a fake
/// home folder; <see cref="Find()"/> reads the real one.
/// </summary>
public static class SyncFolderSuggestions
{
    /// <summary>The Apple apps' iCloud container as iCloud for Windows names it.</summary>
    public const string AppleContainerFolder = "iCloud~io~github~yennster~fanficly";

    /// <summary>The folder made inside each service.</summary>
    public const string FolderName = "Fanficly";

    /// <summary>Where to look. <paramref name="Environment"/> holds the
    /// OneDrive variables; <paramref name="DriveRoots"/> are local drive roots
    /// (Google Drive for desktop streams to a drive of its own).</summary>
    public sealed record Machine(
        string UserProfile,
        string AppData,
        string LocalAppData,
        IReadOnlyDictionary<string, string?> Environment,
        IReadOnlyList<string> DriveRoots);

    public static IReadOnlyList<SyncFolderSuggestion> Find() => Find(Current());

    /// <summary>The services found, OneDrive first (the default), each once.</summary>
    public static IReadOnlyList<SyncFolderSuggestion> Find(Machine machine)
    {
        var result = new List<SyncFolderSuggestion>();
        void Add(string label, string serviceRoot, string? folder = null)
        {
            var path = System.IO.Path.Combine(serviceRoot, folder ?? FolderName);
            if (result.Any(r => string.Equals(r.Path, path, StringComparison.OrdinalIgnoreCase))) return;
            result.Add(new SyncFolderSuggestion(label, path));
        }

        // OneDrive sets these for the signed-in accounts.
        foreach (var variable in (string[])["OneDrive", "OneDriveConsumer", "OneDriveCommercial"])
        {
            if (machine.Environment.TryGetValue(variable, out var root) && !string.IsNullOrEmpty(root) && Directory.Exists(root))
                Add(variable == "OneDriveCommercial" ? "OneDrive (work or school)" : "OneDrive", root);
        }

        // Google Drive for desktop: "My Drive" on its own drive letter when
        // streaming, or in the user folder when mirroring.
        foreach (var root in machine.DriveRoots.Append(machine.UserProfile))
        {
            var myDrive = System.IO.Path.Combine(root, "My Drive");
            if (Directory.Exists(myDrive)) Add("Google Drive", myDrive);
        }

        // Dropbox records its folders in info.json; older installs use ~/Dropbox.
        var dropboxFound = false;
        foreach (var dataRoot in (string[])[machine.AppData, machine.LocalAppData])
        {
            foreach (var (account, path) in DropboxFolders(System.IO.Path.Combine(dataRoot, "Dropbox", "info.json")))
            {
                if (!Directory.Exists(path)) continue;
                Add(account == "business" ? "Dropbox (business)" : "Dropbox", path);
                dropboxFound = true;
            }
        }
        var defaultDropbox = System.IO.Path.Combine(machine.UserProfile, "Dropbox");
        if (!dropboxFound && Directory.Exists(defaultDropbox)) Add("Dropbox", defaultDropbox);

        var box = System.IO.Path.Combine(machine.UserProfile, "Box");
        if (Directory.Exists(box)) Add("Box", box);

        // iCloud for Windows. The Apple apps' own container, when it shows,
        // holds the iPhone's and Mac's backup: the one to share.
        var iCloud = System.IO.Path.Combine(machine.UserProfile, "iCloudDrive");
        if (Directory.Exists(iCloud))
        {
            var container = System.IO.Path.Combine(iCloud, AppleContainerFolder);
            if (Directory.Exists(System.IO.Path.Combine(container, "Documents")))
                Add("iCloud Drive (your iPhone and Mac's Fanficly folder)", container, "Documents");
            else
                Add("iCloud Drive", iCloud);
        }
        return result;
    }

    /// <summary>Each account's folder in Dropbox's info.json
    /// (<c>{"personal": {"path": …}, "business": {"path": …}}</c>).</summary>
    internal static IEnumerable<(string Account, string Path)> DropboxFolders(string infoPath)
    {
        var found = new List<(string, string)>();
        try
        {
            if (!File.Exists(infoPath)) return found;
            using var document = JsonDocument.Parse(File.ReadAllText(infoPath));
            if (document.RootElement.ValueKind != JsonValueKind.Object) return found;
            foreach (var account in document.RootElement.EnumerateObject())
            {
                if (account.Value.ValueKind == JsonValueKind.Object
                    && account.Value.TryGetProperty("path", out var path)
                    && path.ValueKind == JsonValueKind.String
                    && path.GetString() is { Length: > 0 } value)
                    found.Add((account.Name, value));
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            // A damaged or locked file just means no suggestion.
        }
        return found;
    }

    private static Machine Current()
    {
        var environment = new Dictionary<string, string?>();
        foreach (var variable in (string[])["OneDrive", "OneDriveConsumer", "OneDriveCommercial"])
            environment[variable] = System.Environment.GetEnvironmentVariable(variable);
        var drives = new List<string>();
        try
        {
            // Fixed drives only: asking a disconnected network drive can hang.
            foreach (var drive in DriveInfo.GetDrives())
                if (drive.DriveType == DriveType.Fixed && drive.IsReady)
                    drives.Add(drive.RootDirectory.FullName);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
        return new Machine(
            System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile),
            System.Environment.GetFolderPath(System.Environment.SpecialFolder.ApplicationData),
            System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData),
            environment,
            drives);
    }
}
