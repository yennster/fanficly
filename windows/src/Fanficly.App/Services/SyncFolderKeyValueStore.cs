using System.Text.Json;
using Fanficly.Core;

namespace Fanficly.App.Services;

/// <summary>
/// The iCloud key-value store's stand-in: a small JSON file in the sync folder
/// the user picked (OneDrive, iCloud Drive for Windows, Dropbox…), so reader
/// profiles, last-read progress and the streak follow them across devices.
/// Edits made by another device (the file changing under us) are merged in and
/// raise <see cref="IKeyValueStore.Changed"/> for each key that changed, like
/// NSUbiquitousKeyValueStore's external-change notification.
/// </summary>
public sealed class SyncFolderKeyValueStore : IKeyValueStore, IDisposable
{
    public const string FileName = "fanficly-settings-sync.json";

    private readonly JsonFileKeyValueStore _local;
    private readonly string _localPath;
    private string? _folder;
    private FileSystemWatcher? _watcher;
    private readonly Lock _gate = new();
    private Timer? _pushTimer;

    public event Action<string>? Changed;

    public SyncFolderKeyValueStore(string localPath)
    {
        _localPath = localPath;
        _local = new JsonFileKeyValueStore(localPath);
        _local.Changed += key => Changed?.Invoke(key);
    }

    /// <summary>The sync folder; null keeps everything on this device only.</summary>
    public string? Folder
    {
        get => _folder;
        set
        {
            lock (_gate)
            {
                _watcher?.Dispose();
                _watcher = null;
                _folder = string.IsNullOrWhiteSpace(value) ? null : value;
            }
            if (_folder is null) return;
            PullFromFolder();
            PushToFolder();
            try
            {
                _watcher = new FileSystemWatcher(_folder, FileName) { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size };
                _watcher.Changed += (_, _) => SchedulePull();
                _watcher.Created += (_, _) => SchedulePull();
                _watcher.Renamed += (_, _) => SchedulePull();
                _watcher.EnableRaisingEvents = true;
            }
            catch (Exception e)
            {
                AppHost.Log($"Sync folder watch failed: {e.Message}");
            }
        }
    }

    private string? SharedPath => _folder is null ? null : Path.Combine(_folder, FileName);

    public string? GetString(string key) => _local.GetString(key);

    public void SetString(string key, string? value)
    {
        _local.SetString(key, value);
        SchedulePush();
    }

    public void Remove(string key)
    {
        _local.Remove(key);
        SchedulePush();
    }

    public bool Contains(string key) => _local.Contains(key);

    public IReadOnlyCollection<string> Keys => _local.Keys;

    private Timer? _pullTimer;

    private void SchedulePull()
    {
        _pullTimer?.Dispose();
        _pullTimer = new Timer(_ => PullFromFolder(), null, 500, Timeout.Infinite);
    }

    private void SchedulePush()
    {
        if (_folder is null) return;
        _pushTimer?.Dispose();
        _pushTimer = new Timer(_ => PushToFolder(), null, 1000, Timeout.Infinite);
    }

    /// <summary>Adopts the folder copy's values (last writer wins per key, as KVS does).</summary>
    private void PullFromFolder()
    {
        var path = SharedPath;
        if (path is null || !File.Exists(path)) return;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            foreach (var p in doc.RootElement.EnumerateObject())
                if (p.Value.ValueKind == JsonValueKind.String && _local.GetString(p.Name) != p.Value.GetString())
                    _local.SetString(p.Name, p.Value.GetString());
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            // Mid-sync or locked by the sync client; the next change event retries.
        }
    }

    private void PushToFolder()
    {
        var path = SharedPath;
        if (path is null) return;
        try
        {
            _local.Flush();
            var tmp = path + ".tmp";
            File.Copy(_localPath, tmp, overwrite: true);
            lock (_gate) { if (_watcher is not null) _watcher.EnableRaisingEvents = false; }
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception e)
        {
            AppHost.Log($"Sync folder write failed: {e.Message}");
        }
        finally
        {
            lock (_gate) { if (_watcher is not null) _watcher.EnableRaisingEvents = true; }
        }
    }

    public void Flush()
    {
        _local.Flush();
        if (_folder is not null) PushToFolder();
    }

    public void Dispose()
    {
        Flush();
        _watcher?.Dispose();
        _pushTimer?.Dispose();
        _pullTimer?.Dispose();
        _local.Dispose();
    }
}
