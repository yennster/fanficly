using System.Text.Json;
using Fanficly.Core;
using Xunit;

namespace Fanficly.Core.Tests;

/// <summary>The settings file must survive being briefly locked or damaged at
/// launch: never started empty and then written over.</summary>
public sealed class JsonFileKeyValueStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "fanficly-kv-" + Guid.NewGuid().ToString("N"));
    private string SettingsPath => Path.Combine(_dir, "settings.json");

    public JsonFileKeyValueStoreTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }

    private void WriteSettings(params (string Key, string Value)[] values)
    {
        using var store = new JsonFileKeyValueStore(SettingsPath);
        foreach (var (k, v) in values) store.SetString(k, v);
        store.Flush();
    }

    private static Dictionary<string, string> ReadFile(string path)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        return doc.RootElement.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString()!);
    }

    private FileStream Lock() => new(SettingsPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None);

    [Fact]
    public void FlushKeepsACopyOfTheLastGoodFile()
    {
        WriteSettings(("ageGate", "true"), ("syncFolder", @"C:\Sync"));

        Assert.Equal(ReadFile(SettingsPath), ReadFile(SettingsPath + ".bak"));
    }

    [Fact]
    public void LockedFileIsRetriedUntilItReads()
    {
        WriteSettings(("ageGate", "true"));
        var held = Lock();
        // A dedicated thread: the pool can be starved while the test thread sleeps.
        var release = new Thread(() => { Thread.Sleep(150); held.Dispose(); });
        release.Start();

        using var store = new JsonFileKeyValueStore(SettingsPath, readOnly: false, attempts: 200, retryDelay: TimeSpan.FromMilliseconds(50));
        release.Join();

        Assert.Equal(SettingsFileProblem.None, store.Problem);
        Assert.Equal("true", store.GetString("ageGate"));
    }

    [Fact]
    public void FileStillLockedIsNeverOverwrittenAndGetsThisRunsChangesOnceItReads()
    {
        WriteSettings(("ageGate", "true"), ("syncFolder", @"C:\Sync"), ("theme", "dark"));
        File.Delete(SettingsPath + ".bak");
        var before = File.ReadAllText(SettingsPath);

        JsonFileKeyValueStore store;
        using (Lock())
        {
            store = new JsonFileKeyValueStore(SettingsPath, readOnly: false, attempts: 2, retryDelay: TimeSpan.FromMilliseconds(10));
            Assert.Equal(SettingsFileProblem.Unreadable, store.Problem);
            Assert.Null(store.GetString("ageGate"));

            store.SetString("theme", "sepia");
            store.SetString("fontSize", "18");
            store.Flush();
        }
        Assert.Equal(before, File.ReadAllText(SettingsPath));

        store.Flush();
        store.Dispose();

        var after = ReadFile(SettingsPath);
        Assert.Equal("true", after["ageGate"]);
        Assert.Equal(@"C:\Sync", after["syncFolder"]);
        Assert.Equal("sepia", after["theme"]);
        Assert.Equal("18", after["fontSize"]);
    }

    [Fact]
    public void FileStillLockedRunsOnTheLastGoodCopy()
    {
        WriteSettings(("ageGate", "true"));

        using (Lock())
        {
            using var store = new JsonFileKeyValueStore(SettingsPath, readOnly: false, attempts: 2, retryDelay: TimeSpan.FromMilliseconds(10));
            Assert.Equal(SettingsFileProblem.Unreadable, store.Problem);
            Assert.True(store.LoadedFromBackup);
            Assert.Equal("true", store.GetString("ageGate"));
        }
    }

    [Fact]
    public void RemovalWhileLockedIsAppliedOnceTheFileReads()
    {
        WriteSettings(("ageGate", "true"), ("syncFolder", @"C:\Sync"));

        JsonFileKeyValueStore store;
        using (Lock())
        {
            store = new JsonFileKeyValueStore(SettingsPath, readOnly: false, attempts: 1, retryDelay: TimeSpan.Zero);
            store.Remove("syncFolder");
        }
        store.Dispose();

        var after = ReadFile(SettingsPath);
        Assert.Equal("true", after["ageGate"]);
        Assert.False(after.ContainsKey("syncFolder"));
    }

    [Fact]
    public void FileDeletedWhileUnreadableKeepsTheFallbackAndTheBackup()
    {
        WriteSettings(("ageGate", "true"), ("syncFolder", @"C:\Sync"));

        JsonFileKeyValueStore store;
        using (Lock())
        {
            store = new JsonFileKeyValueStore(SettingsPath, readOnly: false, attempts: 1, retryDelay: TimeSpan.Zero);
            store.SetString("theme", "sepia");
        }
        File.Delete(SettingsPath);
        store.Dispose();

        foreach (var path in new[] { SettingsPath, SettingsPath + ".bak" })
        {
            var after = ReadFile(path);
            Assert.Equal("true", after["ageGate"]);
            Assert.Equal(@"C:\Sync", after["syncFolder"]);
            Assert.Equal("sepia", after["theme"]);
        }
    }

    [Fact]
    public void RecoveryRaisesChangedForValuesTheFileHeld()
    {
        WriteSettings(("ageGate", "true"));
        File.Delete(SettingsPath + ".bak");

        JsonFileKeyValueStore store;
        var changed = new List<string>();
        using (Lock())
        {
            store = new JsonFileKeyValueStore(SettingsPath, readOnly: false, attempts: 1, retryDelay: TimeSpan.Zero);
            store.SetString("theme", "sepia");
            store.Changed += changed.Add;
        }
        store.Flush();

        Assert.False(store.IsWaitingForFile);
        Assert.Equal("true", store.GetString("ageGate"));
        Assert.Equal(["ageGate"], changed);
        store.Dispose();
    }

    [Fact]
    public void MissingFileLoadsTheBackup()
    {
        WriteSettings(("ageGate", "true"));
        File.Delete(SettingsPath);

        using var store = new JsonFileKeyValueStore(SettingsPath);

        Assert.True(store.LoadedFromBackup);
        Assert.Equal("true", store.GetString("ageGate"));
    }

    [Fact]
    public void BackupThatCantBeReadIsNeverWrittenOver()
    {
        WriteSettings(("ageGate", "true"));
        File.WriteAllText(SettingsPath, "not json");
        var backup = SettingsPath + ".bak";
        var before = File.ReadAllText(backup);

        using (new FileStream(backup, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            using var store = new JsonFileKeyValueStore(SettingsPath, readOnly: false, attempts: 1, retryDelay: TimeSpan.Zero);
            Assert.False(store.LoadedFromBackup);
            store.SetString("theme", "dark");
            store.Flush();
        }

        Assert.Equal(before, File.ReadAllText(backup));
        Assert.Equal("dark", ReadFile(SettingsPath)["theme"]);
    }

    [Fact]
    public void DeferredFlushRetriesOnItsOwn()
    {
        WriteSettings(("ageGate", "true"));

        JsonFileKeyValueStore store;
        using (Lock())
        {
            store = new JsonFileKeyValueStore(SettingsPath, readOnly: false, attempts: 1, retryDelay: TimeSpan.Zero)
            {
                RetryFlushAfter = TimeSpan.FromMilliseconds(50),
            };
            store.SetString("theme", "sepia");
            store.Flush();
        }

        // No further change and no explicit flush: the retry timer saves it.
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (store.IsWaitingForFile && DateTime.UtcNow < deadline) Thread.Sleep(20);
        Assert.False(store.IsWaitingForFile);
        store.Dispose();
        Assert.Equal("sepia", ReadFile(SettingsPath)["theme"]);
        Assert.Equal("true", ReadFile(SettingsPath)["ageGate"]);
    }

    [Theory]
    [InlineData("{\"ageGate\": \"tr")]
    [InlineData("[1, 2, 3]")]
    [InlineData("")]
    public void DamagedFileIsRenamedAsideAndTheBackupLoaded(string damaged)
    {
        WriteSettings(("ageGate", "true"), ("syncFolder", @"C:\Sync"));
        File.WriteAllText(SettingsPath, damaged);

        using (var store = new JsonFileKeyValueStore(SettingsPath))
        {
            Assert.Equal(SettingsFileProblem.Damaged, store.Problem);
            Assert.True(store.LoadedFromBackup);
            Assert.Equal("true", store.GetString("ageGate"));
            Assert.NotNull(store.DamagedCopyPath);
            Assert.Equal(damaged, File.ReadAllText(store.DamagedCopyPath!));
            store.Flush();
        }

        Assert.Equal(@"C:\Sync", ReadFile(SettingsPath)["syncFolder"]);
    }

    [Fact]
    public void DamagedFileWithoutABackupIsStillKept()
    {
        File.WriteAllText(SettingsPath, "not json");

        using var store = new JsonFileKeyValueStore(SettingsPath);

        Assert.Equal(SettingsFileProblem.Damaged, store.Problem);
        Assert.False(store.LoadedFromBackup);
        Assert.Equal("not json", File.ReadAllText(store.DamagedCopyPath!));
    }

    [Fact]
    public void ReadOnlyStoreNeverRenamesOrWrites()
    {
        WriteSettings(("ageGate", "true"));
        File.WriteAllText(SettingsPath, "not json");

        using (var store = new JsonFileKeyValueStore(SettingsPath, readOnly: true))
        {
            Assert.Equal(SettingsFileProblem.Damaged, store.Problem);
            Assert.Equal("true", store.GetString("ageGate"));
            Assert.Null(store.DamagedCopyPath);
            store.SetString("theme", "dark");
            store.Flush();
        }

        Assert.Equal("not json", File.ReadAllText(SettingsPath));
        Assert.Single(Directory.GetFiles(_dir, "settings.json*"), f => f.EndsWith(".bak"));
    }
}
