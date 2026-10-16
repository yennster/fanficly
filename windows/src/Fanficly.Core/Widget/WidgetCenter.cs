using System.Text.Json;

namespace Fanficly.Core;

/// <summary>Swift's <c>WidgetCenter</c>: asks the host to refresh its widgets.
/// Core only raises <see cref="ReloadRequested"/>; the Windows app forwards it to
/// its widget provider (Windows widget board).</summary>
public static class WidgetCenter
{
    /// <summary>Raised with the widget kind to refresh, or null for every widget.</summary>
    public static event Action<string?>? ReloadRequested;

    public static void ReloadAllTimelines() => ReloadRequested?.Invoke(null);

    public static void ReloadTimelines(string kind) => ReloadRequested?.Invoke(kind);
}

/// <summary>The store the app and its widget provider both read — the Windows
/// stand-in for <c>UserDefaults(suiteName: "group.io.github.yennster.fanficly")</c>.
/// The app installs one at launch (one the widget provider process can also
/// open); null, like an unavailable app group, means only the app's own
/// <see cref="KeyValueStores.Default"/> is written.</summary>
public static class AppGroupStore
{
    public const string Identifier = "group.io.github.yennster.fanficly";

    public static IKeyValueStore? Shared { get; set; }
}

/// <summary>JSON helpers that match Swift's default <c>JSONEncoder</c>/<c>JSONDecoder</c>,
/// so widget payloads keep the Swift app's exact shape.</summary>
internal static class WidgetJson
{
    /// <summary>Swift's <c>Date</c> reference instant (2001-01-01T00:00:00Z); the
    /// default <c>JSONEncoder</c> writes dates as seconds since it.</summary>
    private static readonly DateTimeOffset ReferenceDate = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public static double ToReferenceSeconds(DateTimeOffset date) => (date - ReferenceDate).TotalSeconds;

    public static DateTimeOffset FromReferenceSeconds(double seconds) => ReferenceDate + TimeSpan.FromSeconds(seconds);

    public static string Write(Action<Utf8JsonWriter> write)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream)) write(writer);
        return System.Text.Encoding.UTF8.GetString(stream.ToArray());
    }

    /// <summary>Swift's <c>try? JSONDecoder().decode</c>: any failure is null.</summary>
    public static T? Read<T>(string? json, Func<JsonElement, T> read) where T : class
    {
        if (json is null) return null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            return read(doc.RootElement);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException or KeyNotFoundException)
        {
            return null;
        }
    }

    public static string String(JsonElement o, string key) =>
        o.GetProperty(key).ValueKind == JsonValueKind.String ? o.GetProperty(key).GetString()! : throw new FormatException(key);

    public static int Int(JsonElement o, string key) => o.GetProperty(key).GetInt32();

    public static double Double(JsonElement o, string key) => o.GetProperty(key).GetDouble();

    public static bool Bool(JsonElement o, string key) => o.GetProperty(key).GetBoolean();

    public static DateTimeOffset Date(JsonElement o, string key) => FromReferenceSeconds(Double(o, key));

    /// <summary>An optional field: absent or null is null, anything else must decode.</summary>
    public static T? Optional<T>(JsonElement o, string key, Func<JsonElement, string, T> read) where T : struct =>
        o.TryGetProperty(key, out var v) && v.ValueKind != JsonValueKind.Null ? read(o, key) : null;

    public static IReadOnlyList<string> Strings(JsonElement o, string key) =>
        o.GetProperty(key).EnumerateArray()
            .Select(e => e.ValueKind == JsonValueKind.String ? e.GetString()! : throw new FormatException(key))
            .ToList();

    public static IReadOnlyList<T> Array<T>(JsonElement root, Func<JsonElement, T> read)
    {
        if (root.ValueKind != JsonValueKind.Array) throw new FormatException("array");
        return root.EnumerateArray().Select(read).ToList();
    }
}

/// <summary>Runs an action after a delay, cancelling any not-yet-run predecessor
/// (Swift's cancel-and-reschedule <c>Task.sleep</c> pattern).</summary>
internal sealed class KeyValueSyncDebouncer
{
    private readonly Lock _gate = new();
    private CancellationTokenSource? _pending;
    private Action? _pendingAction;

    public void Schedule(TimeSpan delay, Action action)
    {
        CancellationTokenSource cts;
        lock (_gate)
        {
            _pending?.Cancel();
            _pending = cts = new CancellationTokenSource();
            _pendingAction = action;
        }
        _ = RunAsync(delay, cts);
    }

    private async Task RunAsync(TimeSpan delay, CancellationTokenSource cts)
    {
        try { await Task.Delay(delay, cts.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) { return; }
        Action? action;
        lock (_gate)
        {
            if (_pending != cts) return;
            _pending = null;
            action = _pendingAction;
            _pendingAction = null;
        }
        action?.Invoke();
    }

    /// <summary>Drops the pending action without running it.</summary>
    public void Cancel()
    {
        lock (_gate)
        {
            _pending?.Cancel();
            _pending = null;
            _pendingAction = null;
        }
    }

    /// <summary>Runs the pending action now, if there is one.</summary>
    public void Flush()
    {
        Action? action;
        lock (_gate)
        {
            _pending?.Cancel();
            _pending = null;
            action = _pendingAction;
            _pendingAction = null;
        }
        action?.Invoke();
    }
}
