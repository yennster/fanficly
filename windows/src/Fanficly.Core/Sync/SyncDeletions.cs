using System.Globalization;
using System.Text.Json;

namespace Fanficly.Core;

/// <summary>What a deletion marker removes. <see cref="SyncDeletions.Raw"/>
/// gives the backup's <c>kind</c> strings, shared with the Swift app's
/// <c>DeletionKind</c>.</summary>
public enum DeletionKind { Work, Hidden, Folder, Search, Filter }

/// <summary>A record some device deleted: a library work, a hidden work, a
/// folder, a saved search or a saved filter, by its identity key (the AO3 id,
/// or the name). The union merge would otherwise bring it back from any other
/// device's copy (#135). A record whose own stamp is newer than the marker
/// (saved, hidden or created again since) wins over it, and markers are
/// dropped after 90 days, like reader profile tombstones.</summary>
public sealed record DeletionBackup(string Kind, string Key, DateTimeOffset DeletedAt);

/// <summary>The newest deletion marker per record, for looking records up
/// against (the Swift app's <c>DeletionIndex</c>).</summary>
public sealed class DeletionIndex
{
    private readonly Dictionary<(string Kind, string Key), DateTimeOffset> _markers = new();

    public DeletionIndex(IEnumerable<DeletionBackup> deletions)
    {
        foreach (var d in deletions)
            if (!_markers.TryGetValue((d.Kind, d.Key), out var existing) || d.DeletedAt > existing)
                _markers[(d.Kind, d.Key)] = d.DeletedAt;
    }

    public DateTimeOffset? DeletedAt(DeletionKind kind, string key) =>
        _markers.TryGetValue((SyncDeletions.Raw(kind), key), out var at) ? at : null;

    /// <summary>Whether a marker removes a record stamped <paramref name="stamp"/>
    /// (saved, hidden or created then). Compared in whole seconds, the backup
    /// file's precision, and a tie goes to the marker: on one device a delete
    /// always comes after the save it removes.</summary>
    public bool Removes(DeletionKind kind, string key, DateTimeOffset stamp) =>
        DeletedAt(kind, key) is { } deletedAt && stamp.ToUnixTimeSeconds() <= deletedAt.ToUnixTimeSeconds();

    public bool Removes(DeletionKind kind, int ao3Id, DateTimeOffset stamp) =>
        Removes(kind, ao3Id.ToString(CultureInfo.InvariantCulture), stamp);
}

/// <summary>This device's own deletion markers and removed downloads, kept in
/// its settings (not synced themselves).</summary>
public static class SyncDeletions
{
    /// <summary>Settings key: this device's deletion markers, kept until they
    /// age out so every backup carries them (the file may be cleared, or
    /// written by an app version that doesn't know them). Same name as the
    /// Swift app's.</summary>
    public const string DeletionsKey = "sync.deletions";

    /// <summary>Settings key: works whose download was removed on this device,
    /// so a restore doesn't put their chapters back from another device's copy
    /// and offer to re-download them. Per device: removing a download here
    /// leaves it on the other devices.</summary>
    public const string RemovedDownloadsKey = "sync.removedDownloads";

    /// <summary>How long a deletion marker is kept: a device offline longer than
    /// this can bring a deleted record back, the same trade-off as profiles.</summary>
    public static readonly TimeSpan Lifetime = TimeSpan.FromDays(90);

    public static string Raw(DeletionKind kind) => kind switch
    {
        DeletionKind.Work => "work",
        DeletionKind.Hidden => "hidden",
        DeletionKind.Folder => "folder",
        DeletionKind.Search => "search",
        _ => "filter",
    };

    /// <summary>Remembers that this device deleted a record, so the next backup
    /// carries the deletion to the file and the other devices. Called by every
    /// delete of a work, hidden work, folder, saved search or filter, whether or
    /// not sync is on.</summary>
    public static void Record(IKeyValueStore settings, DeletionKind kind, string key, DateTimeOffset? at = null)
    {
        var date = at ?? DateTimeOffset.Now;
        var raw = Raw(kind);
        var list = Local(settings).Where(d => !(d.Kind == raw && d.Key == key)).Append(new DeletionBackup(raw, key, date));
        Save(settings, Pruned(list, date));
    }

    public static void Record(IKeyValueStore settings, DeletionKind kind, int ao3Id, DateTimeOffset? at = null) =>
        Record(settings, kind, ao3Id.ToString(CultureInfo.InvariantCulture), at);

    public static IReadOnlyList<DeletionBackup> Local(IKeyValueStore settings)
    {
        if (settings.GetString(DeletionsKey) is not { Length: > 0 } json) return [];
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return [];
            var list = new List<DeletionBackup>();
            foreach (var e in doc.RootElement.EnumerateArray())
            {
                if (e.ValueKind == JsonValueKind.Object
                    && e.TryGetProperty("kind", out var kind) && kind.ValueKind == JsonValueKind.String
                    && e.TryGetProperty("key", out var key) && key.ValueKind == JsonValueKind.String
                    && e.TryGetProperty("deletedAt", out var at) && at.ValueKind == JsonValueKind.String)
                    list.Add(new DeletionBackup(kind.GetString()!, key.GetString()!, LibraryBackupJson.ParseDate(at.GetString()!)));
            }
            return list;
        }
        catch (JsonException)
        {
            return [];
        }
    }

    private static void Save(IKeyValueStore settings, IReadOnlyList<DeletionBackup> deletions)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream))
        {
            w.WriteStartArray();
            foreach (var d in deletions)
            {
                w.WriteStartObject();
                w.WriteString("kind", d.Kind);
                w.WriteString("key", d.Key);
                w.WriteString("deletedAt", LibraryBackupJson.FormatDate(d.DeletedAt));
                w.WriteEndObject();
            }
            w.WriteEndArray();
        }
        settings.SetString(DeletionsKey, System.Text.Encoding.UTF8.GetString(stream.ToArray()));
    }

    /// <summary>The newest marker per record, without the ones older than
    /// <see cref="Lifetime"/>.</summary>
    public static IReadOnlyList<DeletionBackup> Pruned(IEnumerable<DeletionBackup> deletions, DateTimeOffset now)
    {
        var cutoff = now - Lifetime;
        var newest = new Dictionary<(string, string), DeletionBackup>();
        foreach (var d in deletions)
        {
            if (d.DeletedAt < cutoff) continue;
            if (newest.TryGetValue((d.Kind, d.Key), out var existing) && existing.DeletedAt >= d.DeletedAt) continue;
            newest[(d.Kind, d.Key)] = d;
        }
        return newest.Values
            .OrderBy(d => d.Kind, StringComparer.Ordinal)
            .ThenBy(d => d.Key, StringComparer.Ordinal)
            .ToList();
    }

    // MARK: - Removed downloads

    public static IReadOnlySet<int> RemovedDownloads(IKeyValueStore settings)
    {
        var ids = new HashSet<int>();
        foreach (var part in (settings.GetString(RemovedDownloadsKey) ?? "").Split(','))
            if (int.TryParse(part, NumberStyles.Integer, CultureInfo.InvariantCulture, out var id)) ids.Add(id);
        return ids;
    }

    /// <summary>Marks (or, with <paramref name="removed"/> false, unmarks) a
    /// work's download as removed on this device.</summary>
    public static void SetDownloadRemoved(IKeyValueStore settings, int ao3Id, bool removed)
    {
        var ids = new HashSet<int>(RemovedDownloads(settings));
        if (!(removed ? ids.Add(ao3Id) : ids.Remove(ao3Id))) return;
        if (ids.Count == 0) settings.Remove(RemovedDownloadsKey);
        else settings.SetString(RemovedDownloadsKey, string.Join(",", ids.Order().Select(i => i.ToString(CultureInfo.InvariantCulture))));
    }
}
