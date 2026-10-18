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

    public JsonFileKeyValueStore(string path)
    {
        _path = path;
        _flushTimer = new Timer(_ => Flush(), null, Timeout.Infinite, Timeout.Infinite);
        try
        {
            if (File.Exists(path))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(path));
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
        _flushTimer.Change(300, Timeout.Infinite);
    }

    /// <summary>Writes pending changes now (also called on app suspend/exit).</summary>
    public void Flush()
    {
        Dictionary<string, string> snapshot;
        lock (Gate)
        {
            if (!_dirty) return;
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
        }
        catch (IOException)
        {
            lock (Gate) _dirty = true;
        }
    }

    public void Dispose()
    {
        Flush();
        _flushTimer.Dispose();
    }
}
