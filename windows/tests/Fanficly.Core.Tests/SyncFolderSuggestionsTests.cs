using Fanficly.Core;
using Xunit;

namespace Fanficly.Core.Tests;

public sealed class SyncFolderSuggestionsTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "fanficly-sync-" + Guid.NewGuid().ToString("N"));
    private string Home => Path.Combine(_root, "home");
    private string AppData => Path.Combine(_root, "roaming");
    private string LocalAppData => Path.Combine(_root, "local");

    public SyncFolderSuggestionsTests() => Directory.CreateDirectory(Home);

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch (IOException) { }
    }

    private string Make(params string[] parts)
    {
        var path = Path.Combine([_root, .. parts]);
        Directory.CreateDirectory(path);
        return path;
    }

    private IReadOnlyList<SyncFolderSuggestion> Find(Dictionary<string, string?>? env = null, params string[] drives) =>
        SyncFolderSuggestions.Find(new SyncFolderSuggestions.Machine(Home, AppData, LocalAppData,
            env ?? new Dictionary<string, string?>(), drives));

    private static string Json(string text) => "\"" + text.Replace("\\", "\\\\") + "\"";

    [Fact]
    public void NothingInstalledSuggestsNothing() => Assert.Empty(Find());

    [Fact]
    public void OneDriveComesFirstAndPersonalIsListedOnce()
    {
        var personal = Make("home", "OneDrive");
        var work = Make("home", "OneDrive - Contoso");
        Make("home", "Dropbox");
        var found = Find(new Dictionary<string, string?>
        {
            ["OneDrive"] = personal, ["OneDriveConsumer"] = personal, ["OneDriveCommercial"] = work,
        });
        Assert.Equal(["OneDrive", "OneDrive (work or school)", "Dropbox"], found.Select(f => f.Label));
        Assert.Equal(Path.Combine(personal, "Fanficly"), found[0].Path);
    }

    [Fact]
    public void OneDriveVariableForAMissingFolderIsIgnored() =>
        Assert.Empty(Find(new Dictionary<string, string?> { ["OneDrive"] = Path.Combine(_root, "gone") }));

    [Fact]
    public void GoogleDriveOnItsOwnDriveOrMirroredInHome()
    {
        var drive = Make("G");
        Make("G", "My Drive");
        Assert.Equal(Path.Combine(drive, "My Drive", "Fanficly"), Assert.Single(Find(null, drive)).Path);

        Make("home", "My Drive");
        Assert.Equal(["Google Drive", "Google Drive"], Find(null, drive).Select(f => f.Label));
    }

    [Fact]
    public void DropboxFoldersComeFromInfoJson()
    {
        var personal = Make("D", "Dropbox (Personal)");
        var business = Make("D", "Dropbox (Acme)");
        Directory.CreateDirectory(Path.Combine(LocalAppData, "Dropbox"));
        File.WriteAllText(Path.Combine(LocalAppData, "Dropbox", "info.json"),
            "{\"personal\": {\"path\": " + Json(personal) + ", \"host\": 1}, \"business\": {\"path\": " + Json(business) + "}}");
        Make("home", "Dropbox"); // an old default folder isn't listed when info.json names the real ones

        var found = Find();
        Assert.Equal(["Dropbox", "Dropbox (business)"], found.Select(f => f.Label));
        Assert.Equal(Path.Combine(personal, "Fanficly"), found[0].Path);
    }

    [Fact]
    public void DamagedDropboxInfoFallsBackToTheDefaultFolder()
    {
        Directory.CreateDirectory(Path.Combine(AppData, "Dropbox"));
        File.WriteAllText(Path.Combine(AppData, "Dropbox", "info.json"), "{not json");
        var dropbox = Make("home", "Dropbox");
        Assert.Equal(Path.Combine(dropbox, "Fanficly"), Assert.Single(Find()).Path);
    }

    [Fact]
    public void ICloudDrivePrefersTheAppleAppsContainer()
    {
        var iCloud = Make("home", "iCloudDrive");
        Make("home", "Box");
        Assert.Equal(["Box", "iCloud Drive"], Find().Select(f => f.Label));
        Assert.Equal(Path.Combine(iCloud, "Fanficly"), Find()[1].Path);

        var documents = Make("home", "iCloudDrive", SyncFolderSuggestions.AppleContainerFolder, "Documents");
        var apple = Find()[1];
        Assert.StartsWith("iCloud Drive (", apple.Label);
        Assert.Equal(documents, apple.Path);
    }
}
