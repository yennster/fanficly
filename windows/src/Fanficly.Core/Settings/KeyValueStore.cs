using System.Globalization;
using System.Text.Json;

namespace Fanficly.Core;

/// <summary>A flat key/value settings store — the Windows stand-in for
/// <c>UserDefaults</c> / <c>@AppStorage</c>. Values are stored as strings;
/// typed accessors parse them.</summary>
public interface IKeyValueStore
{
    string? GetString(string key);
    void SetString(string key, string? value);
    void Remove(string key);
    bool Contains(string key);
    IReadOnlyCollection<string> Keys { get; }
    /// <summary>Raised (on the writing thread) with the key that changed.</summary>
    event Action<string>? Changed;
}

public static class KeyValueStoreExtensions
{
    public static bool GetBool(this IKeyValueStore s, string key, bool fallback = false) =>
        s.GetString(key) is { } v ? v == "1" || v.Equals("true", StringComparison.OrdinalIgnoreCase) : fallback;
    public static void SetBool(this IKeyValueStore s, string key, bool value) => s.SetString(key, value ? "true" : "false");

    public static double GetDouble(this IKeyValueStore s, string key, double fallback = 0) =>
        s.GetString(key) is { } v && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : fallback;
    public static void SetDouble(this IKeyValueStore s, string key, double value) =>
        s.SetString(key, value.ToString("R", CultureInfo.InvariantCulture));

    public static int GetInt(this IKeyValueStore s, string key, int fallback = 0) =>
        s.GetString(key) is { } v && int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out var i) ? i : fallback;
    public static void SetInt(this IKeyValueStore s, string key, int value) =>
        s.SetString(key, value.ToString(CultureInfo.InvariantCulture));

    public static DateTimeOffset? GetDate(this IKeyValueStore s, string key) =>
        s.GetString(key) is { } v && DateTimeOffset.TryParse(v, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var d) ? d : null;
    public static void SetDate(this IKeyValueStore s, string key, DateTimeOffset? value) =>
        s.SetString(key, value?.ToString("O", CultureInfo.InvariantCulture));
}

/// <summary>The process-wide settings store (Swift's <c>UserDefaults.standard</c>).
/// The app installs a <see cref="JsonFileKeyValueStore"/> at launch; tests get a
/// fresh <see cref="InMemoryKeyValueStore"/>.</summary>
public static class KeyValueStores
{
    public static IKeyValueStore Default { get; set; } = new InMemoryKeyValueStore();

    /// <summary>The cross-device store (Swift's <c>NSUbiquitousKeyValueStore</c>,
    /// iCloud key-value storage). On Windows the app backs it with a small JSON
    /// file in the user's chosen sync folder (OneDrive, iCloud Drive, …);
    /// <see cref="IKeyValueStore.Changed"/> also fires when another device's
    /// change arrives. Tests get an in-memory one.</summary>
    public static IKeyValueStore Synced { get; set; } = new InMemoryKeyValueStore();
}

public class InMemoryKeyValueStore : IKeyValueStore
{
    protected readonly Dictionary<string, string> Values = new();
    protected readonly Lock Gate = new();

    public event Action<string>? Changed;

    public string? GetString(string key)
    {
        lock (Gate) return Values.TryGetValue(key, out var v) ? v : null;
    }

    public void SetString(string key, string? value)
    {
        if (value is null) { Remove(key); return; }
        lock (Gate)
        {
            if (Values.TryGetValue(key, out var old) && old == value) return;
            Values[key] = value;
            OnMutated(key);
        }
        Changed?.Invoke(key);
    }

    public void Remove(string key)
    {
        lock (Gate)
        {
            if (!Values.Remove(key)) return;
            OnMutated(key);
        }
        Changed?.Invoke(key);
    }

    public bool Contains(string key)
    {
        lock (Gate) return Values.ContainsKey(key);
    }

    public IReadOnlyCollection<string> Keys
    {
        get { lock (Gate) return Values.Keys.ToArray(); }
    }

    /// <summary>Raises <see cref="IKeyValueStore.Changed"/>; call it outside the lock.</summary>
    protected void RaiseChanged(string key) => Changed?.Invoke(key);

    /// <summary>Called under the lock after every change, with the key that changed.</summary>
    protected virtual void OnMutated(string key) { }
}

/// <summary>What went wrong reading a <see cref="JsonFileKeyValueStore"/>'s file at launch.</summary>
public enum SettingsFileProblem
{
    None,
    /// <summary>Still locked or unreadable after the retries (a backup tool,
    /// antivirus, OneDrive or another copy of the app holding it). The store
    /// runs on the last good copy and never writes over the file it couldn't
    /// read; once a later flush can read it, this run's changes are applied on
    /// top of it.</summary>
    Unreadable,
    /// <summary>The file wasn't valid JSON. It was renamed aside to
    /// <see cref="JsonFileKeyValueStore.DamagedCopyPath"/> and the last good
    /// copy (if any) loaded in its place. When it couldn't be moved, the store
    /// treats it like an unreadable file and never writes over it.</summary>
    Damaged,
}

/// <summary>Settings persisted as one JSON object in a file (written atomically,
/// debounced). Used by the app for everything <c>@AppStorage</c> held.
/// Every good flush also leaves a copy in <c>&lt;file&gt;.bak</c>, the fallback
/// when the file is damaged, missing or can't be read.</summary>
public sealed class JsonFileKeyValueStore : InMemoryKeyValueStore, IDisposable
{
    private readonly string _path;
    private readonly bool _readOnly;
    private readonly int _attempts;
    private readonly TimeSpan _retryDelay;
    private readonly Timer _flushTimer;
    private readonly Lock _writeGate = new();
    private bool _dirty;
    private bool _disposed;
    private int _retryDelayMs;
    /// <summary>Set while the file on disk couldn't be read: keys changed this
    /// run, applied on top of the file once a flush can read it.</summary>
    private HashSet<string>? _changedWhileUnreadable;
    /// <summary>The .bak existed but couldn't be read: never copy over it this run.</summary>
    private bool _keepBackup;

    /// <summary>How long the first retry of a failed or deferred write waits;
    /// each later one waits twice as long, up to <see cref="MaxRetryDelayMs"/>.</summary>
    internal static int RetryDelayMs { get; set; } = 1000;
    internal const int MaxRetryDelayMs = 60_000;

    /// <summary>Told (on the writing thread) when a write fails, once per run of
    /// failures; the app logs it. Core has no log of its own.</summary>
    public static Action<string>? WriteFailed { get; set; }

    /// <summary>Opens the store over <paramref name="path"/>. A read-only store
    /// (the widget server's copy of a file another process owns) never writes,
    /// and never renames a damaged file aside.</summary>
    public JsonFileKeyValueStore(string path, bool readOnly = false)
        : this(path, readOnly, attempts: 3, retryDelay: TimeSpan.FromMilliseconds(200)) { }

    internal JsonFileKeyValueStore(string path, bool readOnly, int attempts, TimeSpan retryDelay)
    {
        _path = path;
        _readOnly = readOnly;
        _attempts = attempts;
        _retryDelay = retryDelay;
        _flushTimer = new Timer(_ => Flush(), null, Timeout.Infinite, Timeout.Infinite);
        Load();
    }

    public string BackupPath => _path + ".bak";

    /// <summary>What went wrong reading the file at launch, if anything.</summary>
    public SettingsFileProblem Problem { get; private set; }

    /// <summary>The read error behind <see cref="Problem"/>.</summary>
    public string? ProblemDetail { get; private set; }

    /// <summary>Where a damaged file was moved, when it was.</summary>
    public string? DamagedCopyPath { get; private set; }

    /// <summary>True when this run's values came from <see cref="BackupPath"/>.</summary>
    public bool LoadedFromBackup { get; private set; }

    /// <summary>True while the file couldn't be read and nothing has been written
    /// over it; false again once a flush could read it and apply this run's changes.</summary>
    public bool IsWaitingForFile
    {
        get { lock (Gate) return _changedWhileUnreadable is not null; }
    }

    private enum ReadOutcome { Missing, Read, Damaged, Unreadable }

    private static ReadOutcome TryRead(string path, out Dictionary<string, string> values, out string? error)
    {
        values = new Dictionary<string, string>();
        error = null;
        try
        {
            if (!File.Exists(path)) return ReadOutcome.Missing;
            // Share delete too: the widget server re-reads group.json before
            // every render, and Windows refuses to replace a file someone has
            // open without it, so the app's next write would fail.
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var doc = JsonDocument.Parse(stream);
            if (doc.RootElement.ValueKind != JsonValueKind.Object)
            {
                error = $"Expected a JSON object, found {doc.RootElement.ValueKind}.";
                return ReadOutcome.Damaged;
            }
            foreach (var p in doc.RootElement.EnumerateObject())
                if (p.Value.ValueKind == JsonValueKind.String) values[p.Name] = p.Value.GetString()!;
            return ReadOutcome.Read;
        }
        catch (FileNotFoundException)
        {
            return ReadOutcome.Missing;
        }
        catch (JsonException e)
        {
            error = e.Message;
            return ReadOutcome.Damaged;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            error = e.Message;
            return ReadOutcome.Unreadable;
        }
    }

    /// <summary><see cref="TryRead"/>, waiting out a file that's briefly held.</summary>
    private ReadOutcome ReadWithRetries(string path, out Dictionary<string, string> values, out string? error)
    {
        for (var attempt = 1; ; attempt++)
        {
            var outcome = TryRead(path, out values, out error);
            if (outcome != ReadOutcome.Unreadable || attempt >= _attempts) return outcome;
            Thread.Sleep(_retryDelay);
        }
    }

    private void Load()
    {
        switch (ReadWithRetries(_path, out var values, out var error))
        {
            case ReadOutcome.Read:
                foreach (var (k, v) in values) Values[k] = v;
                return;
            case ReadOutcome.Missing:
                // First launch, or the file was deleted: the last good copy, if any.
                LoadBackup();
                return;
            case ReadOutcome.Damaged:
                Problem = SettingsFileProblem.Damaged;
                ProblemDetail = error;
                LoadBackup();
                if (_readOnly) return;
                if (!MoveAside())
                {
                    // Couldn't move the damaged file aside: never write over it.
                    _changedWhileUnreadable = [];
                    return;
                }
                // Put the last good copy (or an empty object) back in its place.
                _dirty = true;
                _flushTimer.Change(0, Timeout.Infinite);
                return;
            case ReadOutcome.Unreadable:
                Problem = SettingsFileProblem.Unreadable;
                ProblemDetail = error;
                LoadBackup();
                _changedWhileUnreadable = [];
                return;
        }
    }

    private void LoadBackup()
    {
        switch (ReadWithRetries(BackupPath, out var values, out _))
        {
            case ReadOutcome.Read:
                foreach (var (k, v) in values) Values[k] = v;
                LoadedFromBackup = true;
                break;
            case ReadOutcome.Unreadable:
                _keepBackup = true;
                break;
        }
    }

    private bool MoveAside()
    {
        var aside = $"{_path}.damaged-{DateTime.Now:yyyyMMddHHmmss}";
        try
        {
            File.Move(_path, aside);
            DamagedCopyPath = aside;
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    protected override void OnMutated(string key)
    {
        _changedWhileUnreadable?.Add(key);
        _dirty = true;
        if (!_readOnly && _retryDelayMs == 0) Schedule(300); // else a retry is already waiting
    }

    /// <summary>Called under the lock.</summary>
    private void Schedule(int delayMs)
    {
        if (_disposed) return;
        try { _flushTimer.Change(delayMs, Timeout.Infinite); }
        catch (ObjectDisposedException) { }
    }

    /// <summary>Raised (on the writing thread) after pending changes reach the file.</summary>
    public event Action? Written;

    /// <summary>Writes pending changes now (also called on app suspend/exit).
    /// False when changes are still pending, because the write failed or the
    /// file still can't be read; a retry is then scheduled. While the file
    /// couldn't be read, first tries to read it again: this run's changes go on
    /// top of what it holds, and nothing is written until it reads. Waits for a
    /// write already under way on another thread.</summary>
    public bool Flush()
    {
        if (_readOnly) return true;
        lock (_writeGate)
        {
            lock (Gate) if (!_dirty) return true;

            if (Volatile.Read(ref _changedWhileUnreadable) is not null)
            {
                if (!TryRecoverFile())
                {
                    ScheduleRetry();
                    return false;
                }
                // Waiting for the file wasn't a write failure: report the first real one.
                lock (Gate) _retryDelayMs = 0;
            }

            Dictionary<string, string> snapshot;
            lock (Gate)
            {
                if (!_dirty) return true;
                _dirty = false;
                snapshot = new Dictionary<string, string>(Values);
            }
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
                var tmp = _path + ".tmp";
                using (var stream = File.Create(tmp))
                using (var w = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
                {
                    w.WriteStartObject();
                    foreach (var (k, v) in snapshot.OrderBy(kv => kv.Key, StringComparer.Ordinal)) w.WriteString(k, v);
                    w.WriteEndObject();
                }
                File.Move(tmp, _path, overwrite: true);
                lock (Gate)
                {
                    _retryDelayMs = 0;
                    // Changed while this retry was writing: OnMutated left it to us.
                    if (_dirty) Schedule(300);
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Replacing a file another process has open can be refused with an
                // access error. This runs on a timer thread, where an exception would
                // end the app, so keep the change pending and try again later.
                lock (Gate) _dirty = true;
                if (ScheduleRetry()) WriteFailed?.Invoke($"Couldn't write {Path.GetFileName(_path)}: {e.Message}");
                return false;
            }
            if (!_keepBackup)
            {
                try
                {
                    var tmp = BackupPath + ".tmp";
                    File.Copy(_path, tmp, overwrite: true);
                    File.Move(tmp, BackupPath, overwrite: true);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    // The settings themselves were saved; the next flush refreshes the copy.
                }
            }
        }
        Written?.Invoke();
        return true;
    }

    /// <summary>Schedules the next try with backoff; true for the first of a run of failures.</summary>
    private bool ScheduleRetry()
    {
        lock (Gate)
        {
            var first = _retryDelayMs == 0;
            _retryDelayMs = first ? RetryDelayMs : Math.Min(_retryDelayMs * 2, MaxRetryDelayMs);
            Schedule(_retryDelayMs);
            return first;
        }
    }

    /// <summary>Reads the file this store couldn't read at launch and puts this
    /// run's changes on top of it. False (nothing to write yet) while it still
    /// can't be read.</summary>
    private bool TryRecoverFile()
    {
        var outcome = TryRead(_path, out var onDisk, out _);
        if (outcome == ReadOutcome.Unreadable) return false;
        if (outcome == ReadOutcome.Damaged && !MoveAside()) return false;
        if (outcome != ReadOutcome.Read)
        {
            // Damaged (now moved aside) or gone: nothing to start from, so keep
            // the fallback this run used plus its changes.
            lock (Gate) _changedWhileUnreadable = null;
            return true;
        }
        var changed = new List<string>();
        lock (Gate)
        {
            // What the file holds wins, except the keys changed this run. A
            // change built on fallback values (a whole list read, edited and
            // written back) still replaces the file's value for that key.
            foreach (var key in _changedWhileUnreadable!)
                if (Values.TryGetValue(key, out var v)) onDisk[key] = v;
                else onDisk.Remove(key);
            foreach (var key in Values.Keys.Union(onDisk.Keys))
                if (Values.GetValueOrDefault(key) != onDisk.GetValueOrDefault(key)) changed.Add(key);
            Values.Clear();
            foreach (var (k, v) in onDisk) Values[k] = v;
            _changedWhileUnreadable = null;
        }
        foreach (var key in changed) RaiseChanged(key);
        return true;
    }

    public void Dispose()
    {
        // The process is usually about to exit, so a scheduled retry would never
        // run: try a few more times now.
        for (var attempt = 0; !Flush() && attempt < 3; attempt++) Thread.Sleep(100);
        lock (Gate) _disposed = true;
        _flushTimer.Dispose();
    }
}
