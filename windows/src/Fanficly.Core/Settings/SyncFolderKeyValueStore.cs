using System.Text.Json;

namespace Fanficly.Core;

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
    private volatile bool _pushAfterWrite;
    // Pulls and pushes run one at a time (timer threads).
    private readonly Lock _syncGate = new();
    // Keys changed here since they last reached the folder, each with a change
    // count: a pull leaves them alone, so a watcher event in the second before
    // the push can't undo a change made a moment ago (#210).
    private readonly Dictionary<string, long> _unpushed = new(StringComparer.Ordinal);
    private long _changeCount;
    // The keys changed on this thread while it holds the lock: the observers
    // take locks of their own (the profile store's), so they must not run under it.
    private readonly ThreadLocal<List<string>?> _deferred = new();
    private bool _pushFailing;

    public event Action<string>? Changed;

    /// <summary>The app's local log (the folder write failures).</summary>
    public Action<string>? Log { get; init; }

    /// <summary>This PC's own copy (<c>synced.json</c>), for the launch's report
    /// of a damaged or locked settings file.</summary>
    public JsonFileKeyValueStore LocalStore => _local;

    /// <summary>False in tests: pushes and pulls run only through
    /// <see cref="PushNow"/> and <see cref="PullNow"/>.</summary>
    internal bool AutoSync { get; init; } = true;

    public SyncFolderKeyValueStore(string localPath)
    {
        _localPath = localPath;
        _local = new JsonFileKeyValueStore(localPath);
        // Changes made under the lock are announced once it's released (below).
        _local.Changed += key =>
        {
            if (_deferred.Value is { } held) held.Add(key);
            else Changed?.Invoke(key);
        };
        _local.Written += () =>
        {
            if (!_pushAfterWrite) return;
            _pushAfterWrite = false;
            SchedulePush();
        };
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
            // Turning sync on adopts the folder's values first, as before: only
            // changes made while it's on win over the folder's.
            lock (_unpushed) _unpushed.Clear();
            if (_folder is null) return;
            PullFromFolder();
            PushToFolder();
            try
            {
                if (!AutoSync) return;
                _watcher = new FileSystemWatcher(_folder, FileName) { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size };
                _watcher.Changed += (_, _) => SchedulePull();
                _watcher.Created += (_, _) => SchedulePull();
                _watcher.Renamed += (_, _) => SchedulePull();
                _watcher.EnableRaisingEvents = true;
            }
            catch (Exception e)
            {
                Log?.Invoke($"Sync folder watch failed: {e.Message}");
            }
        }
    }

    private string? SharedPath => _folder is null ? null : Path.Combine(_folder, FileName);

    public string? GetString(string key) => _local.GetString(key);

    // Marking a key and writing it, and a pull's check and write, happen under
    // the one (re-entrant) lock, so a pull can't slip the folder's value in
    // between a change's mark and its write. Change handlers that write back
    // (the profile and streak observers) run on the same thread.
    public void SetString(string key, string? value)
    {
        UnderLock(() =>
        {
            MarkUnpushedLocked(key);
            _local.SetString(key, value);
        });
        SchedulePush();
    }

    public void Remove(string key)
    {
        UnderLock(() =>
        {
            MarkUnpushedLocked(key);
            _local.Remove(key);
        });
        SchedulePush();
    }

    /// <summary>Runs a change to the local copy under the lock, then raises
    /// <see cref="Changed"/> for what it changed once the lock is released.</summary>
    private void UnderLock(Action change)
    {
        var outer = _deferred.Value;
        var changed = new List<string>();
        _deferred.Value = changed;
        try
        {
            lock (_unpushed) change();
        }
        finally
        {
            _deferred.Value = outer;
        }
        foreach (var key in changed) Changed?.Invoke(key);
    }

    private void MarkUnpushedLocked(string key)
    {
        if (_folder is not null) _unpushed[key] = ++_changeCount;
    }

    /// <summary>Keys changed here that haven't reached the folder yet (tests).</summary>
    internal IReadOnlyCollection<string> UnpushedKeys
    {
        get { lock (_unpushed) return _unpushed.Keys.ToList(); }
    }

    public bool Contains(string key) => _local.Contains(key);

    public IReadOnlyCollection<string> Keys => _local.Keys;

    private Timer? _pullTimer;

    private void SchedulePull()
    {
        if (!AutoSync) return;
        _pullTimer?.Dispose();
        _pullTimer = new Timer(_ => PullFromFolder(), null, 500, Timeout.Infinite);
    }

    private const int BusyRetryMs = 5000;

    private void SchedulePush(int delayMs = 1000)
    {
        if (_folder is null || !AutoSync) return;
        _pushTimer?.Dispose();
        _pushTimer = new Timer(_ => PushToFolder(), null, delayMs, Timeout.Infinite);
    }

    /// <summary>Adopts the folder copy's values (last writer wins per key, as KVS
    /// does), except for keys changed here that haven't been pushed yet: those
    /// are newer than anything the folder holds (#210).</summary>
    private void PullFromFolder()
    {
        lock (_syncGate) PullLocked();
    }

    /// <summary>Returns false only when the sync client holds the folder's file:
    /// one that doesn't parse is written over by the next push, as before.</summary>
    private bool PullLocked()
    {
        var path = SharedPath;
        if (path is null || !File.Exists(path)) return true;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            UnderLock(() =>
            {
                foreach (var p in doc.RootElement.EnumerateObject())
                    if (p.Value.ValueKind == JsonValueKind.String && !_unpushed.ContainsKey(p.Name)
                        && _local.GetString(p.Name) != p.Value.GetString())
                        _local.SetString(p.Name, p.Value.GetString());
            });
            return true;
        }
        catch (JsonException)
        {
            // Mid-upload or damaged: the next change event (or our push) fixes it.
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Locked by the sync client; the next change event retries.
            return false;
        }
    }

    private void PushToFolder()
    {
        lock (_syncGate) PushLocked();
    }

    /// <summary>The debounced push and the watcher's pull, run at once (tests).</summary>
    internal void PushNow() => PushToFolder();

    internal void PullNow() => PullFromFolder();

    private void PushLocked()
    {
        var path = SharedPath;
        if (path is null) return;
        try
        {
            // Take in what other devices wrote first (leaving this PC's unpushed
            // keys alone), so copying the file over the folder's doesn't drop
            // their changes. A file the sync client holds is retried later.
            if (!PullLocked()) { SchedulePush(BusyRetryMs); return; }
            Dictionary<string, long> pushing;
            lock (_unpushed) pushing = new(_unpushed);
            // The local write failed (it retries itself, backing off): pushing
            // now would copy the old file over the folder's, so push once that
            // retry has written it.
            if (!_local.Flush()) { _pushAfterWrite = true; return; }
            // Nothing synced has been set on this PC yet, so there's no file to copy.
            if (!File.Exists(_localPath)) return;
            var tmp = path + ".tmp";
            File.Copy(_localPath, tmp, overwrite: true);
            lock (_gate) { if (_watcher is not null) _watcher.EnableRaisingEvents = false; }
            File.Move(tmp, path, overwrite: true);
            _pushFailing = false;
            // Keys changed again since the copy stay unpushed for the next push.
            lock (_unpushed)
                foreach (var (key, count) in pushing)
                    if (_unpushed.TryGetValue(key, out var now) && now == count) _unpushed.Remove(key);
        }
        catch (Exception e)
        {
            // Once until a push gets through: a folder that stays unwritable retries every 5 s.
            if (!_pushFailing) Log?.Invoke($"Sync folder write failed: {e.Message}");
            _pushFailing = true;
            // Usually the sync client holding the file mid-upload: try again, or
            // the unpushed keys would wait for the next change (#210).
            if (e is IOException or UnauthorizedAccessException) SchedulePush(BusyRetryMs);
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
