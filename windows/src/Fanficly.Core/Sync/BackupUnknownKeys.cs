using System.Text.Json;
using System.Text.Json.Nodes;

namespace Fanficly.Core;

/// <summary>Keeps the JSON keys this app doesn't know when it rewrites the
/// shared <c>library_backup.json</c> (the Swift app's
/// <c>iCloudSyncManager.preservingUnknownKeys</c>). The Apple and Windows apps
/// add fields at different times (notes and personal tags on Apple, the
/// <c>*Windows</c> reader settings here), and a backup that dropped every key it
/// couldn't read would erase the other app's data from the file.
///
/// <para>Applied to the encoded merge result against the file it merged with:</para>
/// <list type="bullet">
/// <item>Top-level keys this app doesn't know are copied over whole.</item>
/// <item>Each record (and each work's chapter) that the file also has, matched
/// by its identity key, gets back the keys this app doesn't know. Keys it does
/// know are never copied, because a missing one can mean "cleared".</item>
/// <item><c>settings</c> merge key by key: a key the file has and this device
/// doesn't is kept, known or not. Settings are only ever set, never cleared,
/// so a missing key just means this device never had it.</item>
/// </list>
/// Keep the known-key sets in step with <see cref="LibraryBackupJson"/>'s
/// encoder: a key it writes but these sets leave out would be overwritten with
/// the file's old value whenever this device omits it.</summary>
internal static class BackupUnknownKeys
{
    internal static readonly HashSet<string> TopLevelKeys =
    [
        "works", "bookmarks", "subscriptions", "searches", "progress", "filters", "hidden",
        "settings", "folders", "stats", "followedAuthors", "blocked", "timestamp",
    ];

    internal static readonly HashSet<string> WorkKeys =
    [
        "ao3Id", "title", "authorName", "authorUsername", "summary", "rating", "warnings", "categories",
        "fandoms", "characters", "relationships", "freeforms", "language", "wordCount", "chapterCount",
        "totalChapters", "kudos", "hits", "bookmarksCount", "commentsCount", "isComplete", "publishedAt",
        "updatedAt", "savedAt", "lastReadAt", "lastReadChapter", "lastReadProgress", "isFollowed",
        "followedAt", "lastSeenChapterCount", "isStarred", "isPinned", "chapters", "folderName", "folderNames",
    ];

    internal static readonly HashSet<string> ChapterKeys = ["index", "title", "bodyHTML", "aoId"];

    /// <summary>Each record array: its name, identity key, the keys this app
    /// knows, and whether the identity ignores case.</summary>
    internal static readonly (string Array, string Id, HashSet<string> Known, bool IgnoreCase)[] Records =
    [
        ("works", "ao3Id", WorkKeys, false),
        ("bookmarks", "ao3Id", ["ao3Id", "workAo3Id", "notes", "tags", "savedAt"], false),
        ("subscriptions", "key", ["key", "kind", "displayName", "authorName", "lastSeenChapterCount", "lastCheckedAt"], false),
        ("searches", "name", ["name", "prompt", "sortColumn", "sortDirection", "savedAt"], false),
        ("progress", "ao3Id", ["ao3Id", "chapterIndex", "paragraphIndex", "title", "author", "updatedAt"], false),
        ("filters", "name", ["name", "filtersJSON", "savedAt"], false),
        ("hidden", "ao3Id", ["ao3Id", "title", "hiddenAt"], false),
        ("folders", "name", ["name", "createdAt"], false),
        ("stats", "ao3Id",
        [
            "ao3Id", "title", "author", "fandoms", "categories", "relationships", "rating", "wordCount",
            "firstReadAt", "lastReadAt", "totalSeconds", "daySeconds", "maxProgress", "workIsComplete",
        ], false),
        ("followedAuthors", "username", ["username", "displayName", "followedAt", "knownWorkIds", "lastCheckedAt"], true),
    ];

    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary><paramref name="merged"/> (an encoded backup) with the keys
    /// <paramref name="cloud"/> (the file it merged with) holds that this app
    /// doesn't know. Returns <paramref name="merged"/> unchanged when there's
    /// nothing to add.</summary>
    internal static byte[] Preserve(byte[] merged, byte[] cloud)
    {
        if (JsonNode.Parse(merged) is not JsonObject output || JsonNode.Parse(cloud) is not JsonObject file) return merged;
        var changed = false;

        foreach (var (key, value) in file)
        {
            if (TopLevelKeys.Contains(key) || output.ContainsKey(key)) continue;
            output[key] = value?.DeepClone();
            changed = true;
        }

        if (file["settings"] is JsonObject fileSettings)
        {
            if (output["settings"] is JsonObject settings)
            {
                foreach (var (key, value) in fileSettings)
                {
                    if (settings.ContainsKey(key)) continue;
                    settings[key] = value?.DeepClone();
                    changed = true;
                }
            }
            else
            {
                output["settings"] = fileSettings.DeepClone();
                changed = true;
            }
        }

        foreach (var (array, id, known, ignoreCase) in Records)
        {
            if (output[array] is not JsonArray records || file[array] is not JsonArray fileRecords) continue;
            var byId = new Dictionary<string, JsonObject>(ignoreCase ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
            foreach (var r in fileRecords)
                if (r is JsonObject o && Identity(o, id) is { } rid) byId.TryAdd(rid, o);
            foreach (var r in records)
            {
                if (r is not JsonObject record || Identity(record, id) is not { } rid || !byId.TryGetValue(rid, out var fileRecord)) continue;
                changed |= CopyUnknown(record, fileRecord, known);
                if (array == "works" && record["chapters"] is JsonArray chapters && fileRecord["chapters"] is JsonArray fileChapters)
                {
                    var chaptersByIndex = new Dictionary<string, JsonObject>();
                    foreach (var c in fileChapters)
                        if (c is JsonObject o && Identity(o, "index") is { } index) chaptersByIndex.TryAdd(index, o);
                    foreach (var c in chapters)
                        if (c is JsonObject chapter && Identity(chapter, "index") is { } index
                            && chaptersByIndex.TryGetValue(index, out var fileChapter))
                            changed |= CopyUnknown(chapter, fileChapter, ChapterKeys);
                }
            }
        }

        if (!changed) return merged;
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream, WriterOptions)) output.WriteTo(w);
        return stream.ToArray();
    }

    private static bool CopyUnknown(JsonObject record, JsonObject fileRecord, HashSet<string> known)
    {
        var changed = false;
        foreach (var (key, value) in fileRecord)
        {
            if (known.Contains(key) || record.ContainsKey(key)) continue;
            record[key] = value?.DeepClone();
            changed = true;
        }
        return changed;
    }

    /// <summary>A record's identity as text (numbers by their JSON text).</summary>
    private static string? Identity(JsonObject o, string key) =>
        o[key] is JsonValue v && v.TryGetValue(out JsonElement e)
            ? e.ValueKind switch
            {
                JsonValueKind.String => e.GetString(),
                JsonValueKind.Number => e.GetRawText(),
                _ => null,
            }
            : null;
}
