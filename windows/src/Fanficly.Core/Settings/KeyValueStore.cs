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
            OnMutated();
        }
        Changed?.Invoke(key);
    }

    public void Remove(string key)
    {
        lock (Gate)
        {
            if (!Values.Remove(key)) return;
            OnMutated();
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

    /// <summary>Called under the lock after every change.</summary>
    protected virtual void OnMutated() { }
}

/// <summary>Settings persisted as one JSON object in a file (written atomically,
/// debounced). Used by the app for everything <c>@AppStorage</c> held.</summary>
public sealed class JsonFileKeyValueStore : InMemoryKeyValueStore, IDisposable
{
    private readonly string _path;
    private readonly Timer _flushTimer;
    private bool _dirty;
    private bool _disposed;
    private int _retryDelayMs;
    private readonly Lock _writeGate = new();

    /// <summary>How long the first retry of a failed write waits; each later
    /// one waits twice as long, up to <see cref="MaxRetryDelayMs"/>.</summary>
    internal static int RetryDelayMs { get; set; } = 1000;
    internal const int MaxRetryDelayMs = 60_000;

    /// <summary>Told (on the writing thread) when a write fails, once per run of
    /// failures; the app logs it. Core has no log of its own.</summary>
    public static Action<string>? WriteFailed { get; set; }

    public JsonFileKeyValueStore(string path)
    {
        _path = path;
        _flushTimer = new Timer(_ => Flush(), null, Timeout.Infinite, Timeout.Infinite);
        try
        {
            if (File.Exists(path))
            {
                // Share delete too: the widget server re-reads group.json before
                // every render, and Windows refuses to replace a file someone has
                // open without it, so the app's next write would fail.
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var doc = JsonDocument.Parse(stream);
                foreach (var p in doc.RootElement.EnumerateObject())
                    if (p.Value.ValueKind == JsonValueKind.String) Values[p.Name] = p.Value.GetString()!;
            }
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            // A corrupt settings file must not stop the app launching.
        }
    }

    protected override void OnMutated()
    {
        _dirty = true;
        if (_retryDelayMs == 0) Schedule(300); // else a retry is already waiting
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
    /// False when changes are still pending because the write failed; a retry
    /// is then scheduled. Waits for a write already under way on another thread.</summary>
    public bool Flush()
    {
        lock (_writeGate)
        {
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
                bool first;
                lock (Gate)
                {
                    _dirty = true;
                    first = _retryDelayMs == 0;
                    _retryDelayMs = first ? RetryDelayMs : Math.Min(_retryDelayMs * 2, MaxRetryDelayMs);
                    Schedule(_retryDelayMs);
                }
                if (first) WriteFailed?.Invoke($"Couldn't write {Path.GetFileName(_path)}: {e.Message}");
                return false;
            }
        }
        Written?.Invoke();
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
