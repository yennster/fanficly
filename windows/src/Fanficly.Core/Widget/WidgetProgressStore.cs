namespace Fanficly.Core;

/// <summary>The last-read story the widget shows. Encoded exactly as the Swift
/// app's <c>JSONEncoder</c> does (dates as seconds since 2001-01-01, nil optionals
/// omitted).</summary>
public sealed record WidgetStoryProgress(
    int Id,
    string Title,
    string Author,
    double Progress,
    int? Chapter,
    int? Paragraph,
    DateTimeOffset? UpdatedAt)
{
    public double ClampedProgress => Math.Min(Math.Max(Progress, 0), 1);

    /// <summary>When this progress was saved; undated payloads are the oldest.</summary>
    public DateTimeOffset FreshnessDate => UpdatedAt ?? DateTimeOffset.MinValue;

    public string Encode() => WidgetJson.Write(w =>
    {
        w.WriteStartObject();
        w.WriteNumber("id", Id);
        w.WriteString("title", Title);
        w.WriteString("author", Author);
        w.WriteNumber("progress", Progress);
        if (Chapter is { } chapter) w.WriteNumber("chapter", chapter);
        if (Paragraph is { } paragraph) w.WriteNumber("paragraph", paragraph);
        if (UpdatedAt is { } updatedAt) w.WriteNumber("updatedAt", WidgetJson.ToReferenceSeconds(updatedAt));
        w.WriteEndObject();
    });

    /// <summary>Null for missing or undecodable data.</summary>
    public static WidgetStoryProgress? Decode(string? json) => WidgetJson.Read(json, o => new WidgetStoryProgress(
        WidgetJson.Int(o, "id"),
        WidgetJson.String(o, "title"),
        WidgetJson.String(o, "author"),
        WidgetJson.Double(o, "progress"),
        WidgetJson.Optional(o, "chapter", WidgetJson.Int),
        WidgetJson.Optional(o, "paragraph", WidgetJson.Int),
        WidgetJson.Optional(o, "updatedAt", WidgetJson.Date)));
}

/// <summary>
/// Last-read progress for the widget. Every progress save lands here: written
/// to the app-group store (which the widget reads) and the app's own store, and
/// mirrored to the synced store (debounced ~1.2 s; immediate when the reader
/// closes) so the widget and other devices stay fresh. Reads take whichever
/// copy is freshest.
/// </summary>
public static class WidgetProgressStore
{
    public const string AppGroupIdentifier = AppGroupStore.Identifier;
    public const string LastReadProgressKey = "lastReadProgress";
    public const string WidgetKind = "FanficlyWidget";

    internal static TimeSpan CloudSaveDelay { get; set; } = TimeSpan.FromSeconds(1.2);
    internal static TimeSpan WidgetReloadDelay { get; set; } = TimeSpan.FromSeconds(0.3);

    /// <summary>Test seams; null uses the process-wide stores
    /// (<see cref="KeyValueStores.Default"/>, <see cref="AppGroupStore.Shared"/>,
    /// <see cref="KeyValueStores.Synced"/>).</summary>
    internal static IKeyValueStore? LocalOverride { get; set; }
    internal static IKeyValueStore? SharedOverride { get; set; }
    internal static IKeyValueStore? CloudOverride { get; set; }

    private static IKeyValueStore Local => LocalOverride ?? KeyValueStores.Default;
    private static IKeyValueStore? Shared => SharedOverride ?? AppGroupStore.Shared;
    private static IKeyValueStore Cloud => CloudOverride ?? KeyValueStores.Synced;

    private static readonly KeyValueSyncDebouncer CloudSave = new();
    private static readonly KeyValueSyncDebouncer WidgetReload = new();
    private static readonly Lock ObserverGate = new();
    private static IKeyValueStore? _observedCloud;
    [ThreadStatic] private static bool _writingCloud;

    public static void Save(
        int id, string title, string author, double progress,
        int? chapter = null, int? paragraph = null,
        DateTimeOffset? updatedAt = null, bool syncImmediately = false)
    {
        var payload = new WidgetStoryProgress(id, title, author, progress, chapter, paragraph, updatedAt ?? DateTimeOffset.Now);
        Save(payload, syncImmediately);
    }

    /// <summary>The freshest of the local and synced copies (which then also
    /// becomes the local copy), or null when there is none.</summary>
    public static WidgetStoryProgress? Load()
    {
        var newest = Freshest(ReadLocal(), ReadCloud());
        if (newest is null) return null;
        WriteLocal(newest);
        return newest;
    }

    /// <summary>Call once at launch (not in demo or unit-test runs): pulls in
    /// progress synced from another device now and whenever it changes.</summary>
    public static void InstallCloudSyncObserver()
    {
        var cloud = Cloud;
        lock (ObserverGate)
        {
            if (_observedCloud is not null) return;
            _observedCloud = cloud;
        }
        SyncCloudToLocal();
        ReloadWidgets();
        cloud.Changed += OnCloudChanged;
    }

    /// <summary>Removes the observer (tests, or an app swapping its synced store).</summary>
    internal static void UninstallCloudSyncObserver()
    {
        lock (ObserverGate)
        {
            if (_observedCloud is null) return;
            _observedCloud.Changed -= OnCloudChanged;
            _observedCloud = null;
        }
    }

    private static void OnCloudChanged(string key)
    {
        // Swift observes only external changes; our own writes are skipped.
        if (key == LastReadProgressKey && !_writingCloud) SyncCloudToLocal();
    }

    /// <summary>Adopts the synced copy unless the local one is strictly fresher.</summary>
    public static void SyncCloudToLocal()
    {
        if (ReadCloud() is not { } cloudProgress) return;
        if (ReadLocal() is { } localProgress && localProgress.FreshnessDate > cloudProgress.FreshnessDate) return;
        WriteLocal(cloudProgress);
        ReloadWidgets();
    }

    /// <summary>Writes a pending debounced cloud mirror now — call when the app
    /// suspends or exits, so the last save still reaches other devices.</summary>
    public static void FlushPendingCloudWrite() => CloudSave.Flush();

    private static void Save(WidgetStoryProgress payload, bool syncImmediately)
    {
        WriteLocal(payload);
        ScheduleWidgetReload();
        WriteCloud(payload, syncImmediately);
    }

    private static void WriteCloud(WidgetStoryProgress payload, bool syncImmediately)
    {
        CloudSave.Cancel();
        if (syncImmediately)
        {
            WriteCloudNow(payload);
            ReloadWidgetsNow();
            return;
        }
        CloudSave.Schedule(CloudSaveDelay, () =>
        {
            WriteCloudNow(payload);
            ReloadWidgetsNow();
        });
    }

    private static void ScheduleWidgetReload() => WidgetReload.Schedule(WidgetReloadDelay, ReloadWidgetsNow);

    private static void WriteCloudNow(WidgetStoryProgress payload)
    {
        _writingCloud = true;
        try { Cloud.SetString(LastReadProgressKey, payload.Encode()); }
        finally { _writingCloud = false; }
    }

    private static WidgetStoryProgress? ReadLocal() =>
        Freshest(WidgetStoryProgress.Decode(Shared?.GetString(LastReadProgressKey)),
                 WidgetStoryProgress.Decode(Local.GetString(LastReadProgressKey)));

    private static WidgetStoryProgress? ReadCloud() => WidgetStoryProgress.Decode(Cloud.GetString(LastReadProgressKey));

    private static void WriteLocal(WidgetStoryProgress payload)
    {
        var data = payload.Encode();
        Shared?.SetString(LastReadProgressKey, data);
        Local.SetString(LastReadProgressKey, data);
    }

    /// <summary>The freshest non-null payload; on a tie the earlier argument wins
    /// (Swift's <c>max(by:)</c>).</summary>
    internal static WidgetStoryProgress? Freshest(params WidgetStoryProgress?[] candidates)
    {
        WidgetStoryProgress? best = null;
        foreach (var c in candidates)
            if (c is not null && (best is null || best.FreshnessDate < c.FreshnessDate)) best = c;
        return best;
    }

    private static void ReloadWidgets() => ScheduleWidgetReload();

    private static void ReloadWidgetsNow() => WidgetCenter.ReloadTimelines(WidgetKind);
}
