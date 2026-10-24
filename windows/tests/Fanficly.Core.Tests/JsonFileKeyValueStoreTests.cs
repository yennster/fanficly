using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class JsonFileKeyValueStoreTests
{
    private static string TempFolder()
    {
        var dir = Path.Combine(Path.GetTempPath(), "fanficly-kvs-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return dir;
    }

    [Fact]
    public void Flush_WritesAndReadsBack()
    {
        var dir = TempFolder();
        try
        {
            var path = Path.Combine(dir, "settings.json");
            using (var store = new JsonFileKeyValueStore(path))
            {
                store.SetString("reader.fontSize", "18");
                store.Flush();
            }
            using var reopened = new JsonFileKeyValueStore(path);
            Assert.Equal("18", reopened.GetString("reader.fontSize"));
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    /// <summary>A write that can't replace the file (another process has it
    /// open, so Windows refuses the move) must not throw: Flush runs on a timer
    /// thread, where an exception ends the app. The change stays pending and is
    /// written on a later try.</summary>
    [Fact]
    public void Flush_WhenTheFileCantBeReplaced_DoesNotThrowAndRetriesLater()
    {
        var dir = TempFolder();
        var previousDelay = JsonFileKeyValueStore.RetryDelayMs;
        JsonFileKeyValueStore.RetryDelayMs = 50;
        try
        {
            var path = Path.Combine(dir, "group.json");
            // A folder where the file goes makes the move fail on every OS.
            Directory.CreateDirectory(path);
            using var store = new JsonFileKeyValueStore(path);
            store.SetString("widget.lastRead", "42");

            var error = Record.Exception(store.Flush);
            Assert.Null(error);
            Assert.False(File.Exists(path));

            // The blocker goes away; the retry timer writes the pending change.
            Directory.Delete(path);
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (!File.Exists(path) && DateTime.UtcNow < deadline) Thread.Sleep(20);
            Assert.True(File.Exists(path));
            Assert.Contains("\"42\"", File.ReadAllText(path));
        }
        finally
        {
            JsonFileKeyValueStore.RetryDelayMs = previousDelay;
            Directory.Delete(dir, recursive: true);
        }
    }
}
