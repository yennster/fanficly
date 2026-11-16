using System.Text.Json;
using Fanficly.Core;
using Xunit;

namespace Fanficly.Core.Tests;

/// <summary>The synced settings file: a pull from the folder must never undo a
/// change made here that hasn't been pushed yet, and a push must not drop what
/// another device wrote (#210).</summary>
public sealed class SyncFolderKeyValueStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "fanficly-syncstore-" + Guid.NewGuid().ToString("N"));
    private string Folder => Path.Combine(_dir, "folder");
    private string SharedFile => Path.Combine(Folder, SyncFolderKeyValueStore.FileName);
    private readonly List<SyncFolderKeyValueStore> _stores = [];

    public SyncFolderKeyValueStoreTests() => Directory.CreateDirectory(Folder);

    public void Dispose()
    {
        foreach (var s in _stores) s.Dispose();
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }

    private SyncFolderKeyValueStore MakeStore(bool withFolder = true)
    {
        var store = new SyncFolderKeyValueStore(Path.Combine(_dir, "synced.json")) { AutoSync = false };
        _stores.Add(store);
        if (withFolder) store.Folder = Folder;
        return store;
    }

    private void WriteFolder(params (string Key, string Value)[] values) =>
        File.WriteAllText(SharedFile, JsonSerializer.Serialize(values.ToDictionary(v => v.Key, v => v.Value)));

    private Dictionary<string, string> ReadFolder() =>
        JsonDocument.Parse(File.ReadAllText(SharedFile)).RootElement.EnumerateObject()
            .ToDictionary(p => p.Name, p => p.Value.GetString()!);

    [Fact]
    public void APullBeforeThePushKeepsTheChangeJustMade()
    {
        WriteFolder(("profile", "old"));
        var store = MakeStore();
        Assert.Equal("old", store.GetString("profile"));

        store.SetString("profile", "new");
        // OneDrive touches the file (or another device writes it) inside the push's second.
        WriteFolder(("profile", "old"), ("streak", "5"));
        store.PullNow();

        Assert.Equal("new", store.GetString("profile"));
        Assert.Equal("5", store.GetString("streak"));

        store.PushNow();
        Assert.Equal("new", ReadFolder()["profile"]);
        Assert.Empty(store.UnpushedKeys);
    }

    [Fact]
    public void APushKeepsWhatAnotherDeviceWroteSinceTheLastPull()
    {
        WriteFolder(("profile", "a"));
        var store = MakeStore();
        store.SetString("lastRead", "here");
        WriteFolder(("profile", "b"));

        store.PushNow();

        var folder = ReadFolder();
        Assert.Equal("b", folder["profile"]);
        Assert.Equal("here", folder["lastRead"]);
        Assert.Equal("b", store.GetString("profile"));
    }

    [Fact]
    public void OncePushedAKeyTakesTheFoldersLaterValues()
    {
        var store = MakeStore();
        store.SetString("profile", "mine");
        store.PushNow();

        WriteFolder(("profile", "theirs"));
        store.PullNow();

        Assert.Equal("theirs", store.GetString("profile"));
    }

    [Fact]
    public void ARemovedKeyIsNotBroughtBackBeforeItsPush()
    {
        WriteFolder(("profile", "x"));
        var store = MakeStore();
        store.Remove("profile");
        store.PullNow();

        Assert.Null(store.GetString("profile"));
        store.PushNow();
        Assert.False(ReadFolder().ContainsKey("profile"));
    }

    [Fact]
    public void TurningSyncOnAdoptsTheFoldersValues()
    {
        var store = MakeStore(withFolder: false);
        store.SetString("profile", "local");
        WriteFolder(("profile", "folder"));

        store.Folder = Folder;

        Assert.Equal("folder", store.GetString("profile"));
        Assert.Equal("folder", ReadFolder()["profile"]);
    }

    [Fact]
    public void ADamagedFolderFileIsWrittenOver()
    {
        var store = MakeStore();
        File.WriteAllText(SharedFile, "{ not json");
        store.SetString("profile", "mine");

        store.PushNow();

        Assert.Equal("mine", ReadFolder()["profile"]);
    }

    [Fact]
    public void ChangeHandlersRunOutsideTheStoresLock()
    {
        // The profile observer takes its own lock in its handler while the UI
        // thread, holding that lock, writes the store: the store's lock must be
        // free by then, or the two threads wait on each other.
        WriteFolder(("profile", "old"));
        var store = MakeStore();
        var otherThreadWrote = false;
        store.Changed += key =>
        {
            if (key != "profile") return;
            otherThreadWrote = Task.Run(() => store.SetString("echo", "x")).Wait(TimeSpan.FromSeconds(5));
        };

        WriteFolder(("profile", "theirs"));
        store.PullNow();
        Assert.True(otherThreadWrote);

        otherThreadWrote = false;
        store.SetString("profile", "mine");
        Assert.True(otherThreadWrote);
    }
}
