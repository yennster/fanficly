using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace Fanficly.Core;

// The backup file shared with the Swift app through a synced folder. Its JSON
// is exactly what Swift's JSONEncoder writes for these Codable structs (with
// `dateEncodingStrategy = .iso8601`): property names as keys, dates as
// ISO 8601 strings in UTC with whole seconds ("2026-10-16T09:41:00Z"), and
// nil optionals omitted. Optional fields stay optional so older backups decode.

public sealed record LibraryBackup(
    IReadOnlyList<WorkBackup> Works,
    IReadOnlyList<BookmarkBackup> Bookmarks,
    IReadOnlyList<SubscriptionBackup> Subscriptions,
    IReadOnlyList<SearchBackup> Searches,
    IReadOnlyList<ProgressBackup> Progress,
    IReadOnlyList<FilterBackup> Filters,
    IReadOnlyList<HiddenBackup> Hidden,
    SettingsBackup? Settings,
    IReadOnlyList<FolderBackup>? Folders,
    /// <summary>Optional so older backups (before the Stats feature) still decode.</summary>
    IReadOnlyList<StatBackup>? Stats,
    DateTimeOffset Timestamp,
    /// <summary>Windows-only for now (the Swift decoder ignores the key); optional
    /// so older backups still decode.</summary>
    IReadOnlyList<AuthorBackup>? FollowedAuthors = null,
    /// <summary>Blocked tags and authors (RM-006); optional so older backups
    /// still decode.</summary>
    IReadOnlyList<BlockedBackup>? Blocked = null);

/// <summary>A blocked tag or author, matched across devices by
/// <see cref="Key"/> (kind plus the value ignoring case).</summary>
public sealed record BlockedBackup(string Kind, string Value, DateTimeOffset CreatedAt)
{
    public string Key => BlockedTerm.KeyFor(Kind, Value);
}

/// <summary>A locally followed author, matched across devices by username
/// ignoring case.</summary>
public sealed record AuthorBackup(string Username, string DisplayName, DateTimeOffset FollowedAt,
                                  IReadOnlyList<int> KnownWorkIds, DateTimeOffset? LastCheckedAt);

public sealed record FolderBackup(string Name, DateTimeOffset CreatedAt);

public sealed record StatBackup(
    int Ao3Id,
    string Title,
    string Author,
    IReadOnlyList<string> Fandoms,
    IReadOnlyList<string> Categories,
    IReadOnlyList<string> Relationships,
    string Rating,
    int WordCount,
    DateTimeOffset FirstReadAt,
    DateTimeOffset LastReadAt,
    double TotalSeconds,
    IReadOnlyDictionary<string, double> DaySeconds,
    // Optional so backups written before these fields still decode.
    double? MaxProgress,
    bool? WorkIsComplete);

public sealed record WorkBackup(
    int Ao3Id,
    string Title,
    string AuthorName,
    string AuthorUsername,
    string Summary,
    string Rating,
    IReadOnlyList<string> Warnings,
    IReadOnlyList<string> Categories,
    IReadOnlyList<string> Fandoms,
    IReadOnlyList<string> Characters,
    IReadOnlyList<string> Relationships,
    IReadOnlyList<string> Freeforms,
    string Language,
    int WordCount,
    int ChapterCount,
    int? TotalChapters,
    int Kudos,
    int Hits,
    int BookmarksCount,
    int CommentsCount,
    bool IsComplete,
    DateTimeOffset? PublishedAt,
    DateTimeOffset? UpdatedAt,
    DateTimeOffset SavedAt,
    DateTimeOffset? LastReadAt,
    int? LastReadChapter,
    double? LastReadProgress,
    bool IsFollowed,
    DateTimeOffset? FollowedAt,
    int? LastSeenChapterCount,
    bool? IsStarred,
    bool? IsPinned,
    IReadOnlyList<ChapterBackup> Chapters,
    string? FolderName,
    IReadOnlyList<string>? FolderNames);

/// <param name="AoId">AO3 chapter id (drives per-chapter comments). Optional so
/// backups written before this field still decode.</param>
public sealed record ChapterBackup(int Index, string Title, string BodyHtml, int? AoId);

public sealed record BookmarkBackup(int Ao3Id, int WorkAo3Id, string Notes, IReadOnlyList<string> Tags, DateTimeOffset SavedAt);

public sealed record SubscriptionBackup(
    string Key, string Kind, string DisplayName, string AuthorName, int? LastSeenChapterCount, DateTimeOffset? LastCheckedAt);

public sealed record SearchBackup(string Name, string Prompt, string SortColumn, string SortDirection, DateTimeOffset SavedAt);

public sealed record ProgressBackup(int Ao3Id, int ChapterIndex, int ParagraphIndex, string Title, string Author, DateTimeOffset UpdatedAt);

public sealed record FilterBackup(string Name, string FiltersJson, DateTimeOffset SavedAt);

public sealed record HiddenBackup(int Ao3Id, string Title, DateTimeOffset HiddenAt);

public enum SettingKind { String, Double, Bool }

/// <summary>One backed-up setting: its JSON key in the backup, the settings
/// key it's read from and restored to, and its type.</summary>
public sealed record SettingField(string JsonKey, string DefaultsKey, SettingKind Kind);

/// <summary>The reader and content settings carried in a backup. Every field is
/// optional; only the ones set on the backing-up device are present.</summary>
public sealed class SettingsBackup
{
    /// <summary>Every field, in the Swift struct's declaration order.</summary>
    public static IReadOnlyList<SettingField> Fields { get; } = BuildFields();

    private static List<SettingField> BuildFields()
    {
        var f = new List<SettingField>
        {
            new("theme", "reader.theme", SettingKind.String),
            new("fontFamily", "reader.fontFamily", SettingKind.String),
            new("width", "reader.width", SettingKind.String),
            new("widthPercent", "reader.widthPercent", SettingKind.Double),
            new("mode", "reader.mode", SettingKind.String),
            new("fontSizePt", "reader.fontSizePt", SettingKind.Double),
            new("lineSpacingPt", "reader.lineSpacingPt", SettingKind.Double),
            new("paragraphSpacingPt", "reader.paragraphSpacingPt", SettingKind.Double),
            new("pageTurnHaptics", "reader.pageTurnHaptics", SettingKind.Bool),
            new("pageTurnAnimations", "reader.pageTurnAnimations", SettingKind.Bool),
            new("kerningPt", "reader.kerningPt", SettingKind.Double),
            new("boldText", "reader.boldText", SettingKind.Bool),
            new("ttsRate", "reader.ttsRate", SettingKind.Double),
            new("ttsVoiceId", "reader.ttsVoiceId", SettingKind.String),
            new("filterMatureExplicit", "content.filterMatureExplicit", SettingKind.Bool),
            new("ageConfirmed", "content.ageConfirmed", SettingKind.Bool),
            new("activeProfile", "reader.activeProfile", SettingKind.String),
            new("activeProfilePhone", "reader.activeProfile.phone", SettingKind.String),
            new("activeProfileMac", "reader.activeProfile.mac", SettingKind.String),
            new("activeProfilePad", "reader.activeProfile.pad", SettingKind.String),
            // Windows-only keys; Swift's decoder ignores keys it doesn't know.
            new("activeProfileWindows", "reader.activeProfile.windows", SettingKind.String),
            new(ProfilesJsonKey, ProfilesDefaultsKey, SettingKind.String),
        };
        // Device-specific settings: <name><Device> ↔ reader.<name>.<device>.
        (string Name, SettingKind Kind)[] perDevice =
        [
            ("theme", SettingKind.String), ("fontFamily", SettingKind.String), ("widthPercent", SettingKind.Double),
            ("mode", SettingKind.String), ("fontSizePt", SettingKind.Double), ("lineSpacingPt", SettingKind.Double),
            ("paragraphSpacingPt", SettingKind.Double), ("pageTurnHaptics", SettingKind.Bool),
            ("pageTurnAnimations", SettingKind.Bool), ("kerningPt", SettingKind.Double), ("boldText", SettingKind.Bool),
        ];
        foreach (var (name, kind) in perDevice)
            foreach (var device in (string[])["Phone", "Mac", "Pad", "Windows"])
                f.Add(new SettingField(name + device, $"reader.{name}.{device.ToLowerInvariant()}", kind));
        return f;
    }

    /// <summary>The profiles field, restored through a merge rather than a plain set.</summary>
    public const string ProfilesJsonKey = "profiles";
    public const string ProfilesDefaultsKey = "reader.profiles";

    /// <summary>Present values by JSON key: a <see cref="string"/>, <see cref="double"/> or <see cref="bool"/>.</summary>
    public Dictionary<string, object> Values { get; } = new();

    public string? GetString(string jsonKey) => Values.TryGetValue(jsonKey, out var v) ? v as string : null;
    public double? GetDouble(string jsonKey) => Values.TryGetValue(jsonKey, out var v) && v is double d ? d : null;
    public bool? GetBool(string jsonKey) => Values.TryGetValue(jsonKey, out var v) && v is bool b ? b : null;

    /// <summary>The device a per-device JSON key belongs to (<c>fontSizePtPad</c> →
    /// <see cref="ReaderDevice.Pad"/>), or null for a shared key.</summary>
    public static ReaderDevice? DeviceOf(string jsonKey)
    {
        foreach (var device in Enum.GetValues<ReaderDevice>())
        {
            var suffix = device.ToString();
            if (jsonKey.Length > suffix.Length && jsonKey.EndsWith(suffix, StringComparison.Ordinal)) return device;
        }
        return null;
    }

    /// <summary>Settings merge key by key (the Swift <c>mergedSettings</c>). This
    /// device's own keys and the shared ones take its value; another device's
    /// per-device keys keep the file's, because this device's copies of them are
    /// only what an earlier restore brought in, and writing those back would
    /// revert that device's newer choices (#133). A key only one side has is kept.</summary>
    public static SettingsBackup? Merged(SettingsBackup? local, SettingsBackup? cloud, ReaderDevice device)
    {
        if (local is null) return cloud;
        if (cloud is null) return local;
        var merged = new SettingsBackup();
        foreach (var (key, value) in cloud.Values) merged.Values[key] = value;
        foreach (var (key, value) in local.Values)
        {
            if (DeviceOf(key) is { } owner && owner != device && merged.Values.ContainsKey(key)) continue;
            merged.Values[key] = value;
        }
        return merged;
    }

    /// <summary>Whether a restore writes this field on <paramref name="device"/>:
    /// shared fields and the device's own, never another device's.</summary>
    public static bool AppliesTo(SettingField field, ReaderDevice device) =>
        DeviceOf(field.JsonKey) is not { } owner || owner == device;

    /// <summary>Reads every field that's set from a settings store (unparseable values count as unset).</summary>
    public static SettingsBackup Capture(IKeyValueStore settings)
    {
        var backup = new SettingsBackup();
        foreach (var field in Fields)
        {
            if (settings.GetString(field.DefaultsKey) is not { } raw) continue;
            switch (field.Kind)
            {
                case SettingKind.String:
                    backup.Values[field.JsonKey] = raw;
                    break;
                case SettingKind.Double:
                    if (double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) && double.IsFinite(d))
                        backup.Values[field.JsonKey] = d;
                    break;
                case SettingKind.Bool:
                    if (raw == "1" || raw.Equals("true", StringComparison.OrdinalIgnoreCase)) backup.Values[field.JsonKey] = true;
                    else if (raw == "0" || raw.Equals("false", StringComparison.OrdinalIgnoreCase)) backup.Values[field.JsonKey] = false;
                    break;
            }
        }
        return backup;
    }
}

/// <summary>Encodes and decodes <see cref="LibraryBackup"/> in the Swift app's
/// JSON shape. Hand-written (Native-AOT safe).</summary>
public static class LibraryBackupJson
{
    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>Swift's <c>.iso8601</c> strategy: UTC, whole seconds, "Z".</summary>
    public static string FormatDate(DateTimeOffset date) =>
        date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    private static readonly string[] DateFormats =
    [
        "yyyy-MM-dd'T'HH:mm:ssK",
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK",
        "yyyy-MM-dd'T'HH:mm:sszzz",
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFzzz",
    ];

    public static DateTimeOffset ParseDate(string text)
    {
        if (DateTimeOffset.TryParseExact(text, DateFormats, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d))
            return d;
        // "+0000"-style offsets (no colon).
        if (text.Length > 5 && (text[^5] == '+' || text[^5] == '-') &&
            DateTimeOffset.TryParseExact(text.Insert(text.Length - 2, ":"), DateFormats, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out d))
            return d;
        throw new JsonException($"Expected an ISO 8601 date, got \"{text}\".");
    }

    // MARK: - Encode

    public static byte[] Encode(LibraryBackup b)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream, WriterOptions))
        {
            w.WriteStartObject();
            WriteArray(w, "works", b.Works, WriteWork);
            WriteArray(w, "bookmarks", b.Bookmarks, (w, x) =>
            {
                w.WriteNumber("ao3Id", x.Ao3Id);
                w.WriteNumber("workAo3Id", x.WorkAo3Id);
                w.WriteString("notes", x.Notes);
                WriteStrings(w, "tags", x.Tags);
                WriteDate(w, "savedAt", x.SavedAt);
            });
            WriteArray(w, "subscriptions", b.Subscriptions, (w, x) =>
            {
                w.WriteString("key", x.Key);
                w.WriteString("kind", x.Kind);
                w.WriteString("displayName", x.DisplayName);
                w.WriteString("authorName", x.AuthorName);
                WriteInt(w, "lastSeenChapterCount", x.LastSeenChapterCount);
                WriteDate(w, "lastCheckedAt", x.LastCheckedAt);
            });
            WriteArray(w, "searches", b.Searches, (w, x) =>
            {
                w.WriteString("name", x.Name);
                w.WriteString("prompt", x.Prompt);
                w.WriteString("sortColumn", x.SortColumn);
                w.WriteString("sortDirection", x.SortDirection);
                WriteDate(w, "savedAt", x.SavedAt);
            });
            WriteArray(w, "progress", b.Progress, (w, x) =>
            {
                w.WriteNumber("ao3Id", x.Ao3Id);
                w.WriteNumber("chapterIndex", x.ChapterIndex);
                w.WriteNumber("paragraphIndex", x.ParagraphIndex);
                w.WriteString("title", x.Title);
                w.WriteString("author", x.Author);
                WriteDate(w, "updatedAt", x.UpdatedAt);
            });
            WriteArray(w, "filters", b.Filters, (w, x) =>
            {
                w.WriteString("name", x.Name);
                w.WriteString("filtersJSON", x.FiltersJson);
                WriteDate(w, "savedAt", x.SavedAt);
            });
            WriteArray(w, "hidden", b.Hidden, (w, x) =>
            {
                w.WriteNumber("ao3Id", x.Ao3Id);
                w.WriteString("title", x.Title);
                WriteDate(w, "hiddenAt", x.HiddenAt);
            });
            if (b.Settings is { } s)
            {
                w.WriteStartObject("settings");
                foreach (var field in SettingsBackup.Fields)
                {
                    if (!s.Values.TryGetValue(field.JsonKey, out var v)) continue;
                    switch (v)
                    {
                        case string str: w.WriteString(field.JsonKey, str); break;
                        case double d: WriteDouble(w, field.JsonKey, d); break;
                        case bool flag: w.WriteBoolean(field.JsonKey, flag); break;
                    }
                }
                w.WriteEndObject();
            }
            if (b.Folders is { } folders)
                WriteArray(w, "folders", folders, (w, x) =>
                {
                    w.WriteString("name", x.Name);
                    WriteDate(w, "createdAt", x.CreatedAt);
                });
            if (b.Stats is { } stats) WriteArray(w, "stats", stats, WriteStat);
            if (b.Blocked is { } blocked)
                WriteArray(w, "blocked", blocked, (w, x) =>
                {
                    w.WriteString("kind", x.Kind);
                    w.WriteString("value", x.Value);
                    WriteDate(w, "createdAt", x.CreatedAt);
                });
            if (b.FollowedAuthors is { } authors)
                WriteArray(w, "followedAuthors", authors, (w, x) =>
                {
                    w.WriteString("username", x.Username);
                    w.WriteString("displayName", x.DisplayName);
                    WriteDate(w, "followedAt", x.FollowedAt);
                    w.WriteStartArray("knownWorkIds");
                    foreach (var id in x.KnownWorkIds) w.WriteNumberValue(id);
                    w.WriteEndArray();
                    WriteDate(w, "lastCheckedAt", x.LastCheckedAt);
                });
            WriteDate(w, "timestamp", b.Timestamp);
            w.WriteEndObject();
        }
        return stream.ToArray();
    }

    private static void WriteWork(Utf8JsonWriter w, WorkBackup x)
    {
        w.WriteNumber("ao3Id", x.Ao3Id);
        w.WriteString("title", x.Title);
        w.WriteString("authorName", x.AuthorName);
        w.WriteString("authorUsername", x.AuthorUsername);
        w.WriteString("summary", x.Summary);
        w.WriteString("rating", x.Rating);
        WriteStrings(w, "warnings", x.Warnings);
        WriteStrings(w, "categories", x.Categories);
        WriteStrings(w, "fandoms", x.Fandoms);
        WriteStrings(w, "characters", x.Characters);
        WriteStrings(w, "relationships", x.Relationships);
        WriteStrings(w, "freeforms", x.Freeforms);
        w.WriteString("language", x.Language);
        w.WriteNumber("wordCount", x.WordCount);
        w.WriteNumber("chapterCount", x.ChapterCount);
        WriteInt(w, "totalChapters", x.TotalChapters);
        w.WriteNumber("kudos", x.Kudos);
        w.WriteNumber("hits", x.Hits);
        w.WriteNumber("bookmarksCount", x.BookmarksCount);
        w.WriteNumber("commentsCount", x.CommentsCount);
        w.WriteBoolean("isComplete", x.IsComplete);
        WriteDate(w, "publishedAt", x.PublishedAt);
        WriteDate(w, "updatedAt", x.UpdatedAt);
        WriteDate(w, "savedAt", x.SavedAt);
        WriteDate(w, "lastReadAt", x.LastReadAt);
        WriteInt(w, "lastReadChapter", x.LastReadChapter);
        if (x.LastReadProgress is { } p) WriteDouble(w, "lastReadProgress", p);
        w.WriteBoolean("isFollowed", x.IsFollowed);
        WriteDate(w, "followedAt", x.FollowedAt);
        WriteInt(w, "lastSeenChapterCount", x.LastSeenChapterCount);
        if (x.IsStarred is { } starred) w.WriteBoolean("isStarred", starred);
        if (x.IsPinned is { } pinned) w.WriteBoolean("isPinned", pinned);
        WriteArray(w, "chapters", x.Chapters, (w, c) =>
        {
            w.WriteNumber("index", c.Index);
            w.WriteString("title", c.Title);
            w.WriteString("bodyHTML", c.BodyHtml);
            WriteInt(w, "aoId", c.AoId);
        });
        if (x.FolderName is { } folderName) w.WriteString("folderName", folderName);
        if (x.FolderNames is { } folderNames) WriteStrings(w, "folderNames", folderNames);
    }

    private static void WriteStat(Utf8JsonWriter w, StatBackup x)
    {
        w.WriteNumber("ao3Id", x.Ao3Id);
        w.WriteString("title", x.Title);
        w.WriteString("author", x.Author);
        WriteStrings(w, "fandoms", x.Fandoms);
        WriteStrings(w, "categories", x.Categories);
        WriteStrings(w, "relationships", x.Relationships);
        w.WriteString("rating", x.Rating);
        w.WriteNumber("wordCount", x.WordCount);
        WriteDate(w, "firstReadAt", x.FirstReadAt);
        WriteDate(w, "lastReadAt", x.LastReadAt);
        WriteDouble(w, "totalSeconds", x.TotalSeconds);
        w.WriteStartObject("daySeconds");
        foreach (var (day, secs) in x.DaySeconds.OrderBy(kv => kv.Key, StringComparer.Ordinal)) WriteDouble(w, day, secs);
        w.WriteEndObject();
        if (x.MaxProgress is { } mp) WriteDouble(w, "maxProgress", mp);
        if (x.WorkIsComplete is { } complete) w.WriteBoolean("workIsComplete", complete);
    }

    private static void WriteArray<T>(Utf8JsonWriter w, string name, IEnumerable<T> items, Action<Utf8JsonWriter, T> body)
    {
        w.WriteStartArray(name);
        foreach (var item in items)
        {
            w.WriteStartObject();
            body(w, item);
            w.WriteEndObject();
        }
        w.WriteEndArray();
    }

    private static void WriteStrings(Utf8JsonWriter w, string name, IEnumerable<string> values)
    {
        w.WriteStartArray(name);
        foreach (var v in values) w.WriteStringValue(v);
        w.WriteEndArray();
    }

    private static void WriteInt(Utf8JsonWriter w, string name, int? value)
    {
        if (value is { } v) w.WriteNumber(name, v);
    }

    /// <summary>Whole numbers without a fraction, as Swift writes them ("600", not "600.0").</summary>
    private static void WriteDouble(Utf8JsonWriter w, string name, double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentException($"\"{name}\" isn't a finite number.");
        if (value == Math.Floor(value) && Math.Abs(value) < 1e15) w.WriteNumber(name, (long)value);
        else w.WriteNumber(name, value);
    }

    private static void WriteDate(Utf8JsonWriter w, string name, DateTimeOffset? value)
    {
        if (value is { } d) w.WriteString(name, FormatDate(d));
    }

    // MARK: - Decode

    /// <summary>Decodes a backup; throws <see cref="JsonException"/> when a
    /// required field is missing or mistyped (Swift's decoder fails the same way).</summary>
    public static LibraryBackup Decode(ReadOnlySpan<byte> utf8)
    {
        var reader = new Utf8JsonReader(utf8, new JsonReaderOptions { AllowTrailingCommas = false });
        using var doc = JsonDocument.ParseValue(ref reader);
        return Decode(doc.RootElement);
    }

    public static LibraryBackup Decode(string json) => Decode(System.Text.Encoding.UTF8.GetBytes(json));

    private static LibraryBackup Decode(JsonElement o)
    {
        RequireObject(o);
        return new LibraryBackup(
            Works: Array(o, "works", ReadWork),
            Bookmarks: Array(o, "bookmarks", x => new BookmarkBackup(
                Int(x, "ao3Id"), Int(x, "workAo3Id"), Str(x, "notes"), Strings(x, "tags"), Date(x, "savedAt"))),
            Subscriptions: Array(o, "subscriptions", x => new SubscriptionBackup(
                Str(x, "key"), Str(x, "kind"), Str(x, "displayName"), Str(x, "authorName"),
                IntN(x, "lastSeenChapterCount"), DateN(x, "lastCheckedAt"))),
            Searches: Array(o, "searches", x => new SearchBackup(
                Str(x, "name"), Str(x, "prompt"), Str(x, "sortColumn"), Str(x, "sortDirection"), Date(x, "savedAt"))),
            Progress: Array(o, "progress", x => new ProgressBackup(
                Int(x, "ao3Id"), Int(x, "chapterIndex"), Int(x, "paragraphIndex"), Str(x, "title"), Str(x, "author"),
                Date(x, "updatedAt"))),
            Filters: Array(o, "filters", x => new FilterBackup(Str(x, "name"), Str(x, "filtersJSON"), Date(x, "savedAt"))),
            Hidden: Array(o, "hidden", x => new HiddenBackup(Int(x, "ao3Id"), Str(x, "title"), Date(x, "hiddenAt"))),
            Settings: Present(o, "settings", out var s) ? ReadSettings(s) : null,
            Folders: Present(o, "folders", out _) ? Array(o, "folders", x => new FolderBackup(Str(x, "name"), Date(x, "createdAt"))) : null,
            Stats: Present(o, "stats", out _) ? Array(o, "stats", ReadStat) : null,
            Timestamp: Date(o, "timestamp"),
            FollowedAuthors: Present(o, "followedAuthors", out _) ? Array(o, "followedAuthors", x => new AuthorBackup(
                Str(x, "username"), Str(x, "displayName"), Date(x, "followedAt"),
                Present(x, "knownWorkIds", out var ids) && ids.ValueKind == JsonValueKind.Array
                    ? ids.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.Number).Select(e => e.GetInt32()).ToList()
                    : [],
                DateN(x, "lastCheckedAt"))) : null,
            Blocked: Present(o, "blocked", out _)
                ? Array(o, "blocked", x => new BlockedBackup(Str(x, "kind"), Str(x, "value"), Date(x, "createdAt")))
                : null);
    }

    private static WorkBackup ReadWork(JsonElement x) => new(
        Ao3Id: Int(x, "ao3Id"),
        Title: Str(x, "title"),
        AuthorName: Str(x, "authorName"),
        AuthorUsername: Str(x, "authorUsername"),
        Summary: Str(x, "summary"),
        Rating: Str(x, "rating"),
        Warnings: Strings(x, "warnings"),
        Categories: Strings(x, "categories"),
        Fandoms: Strings(x, "fandoms"),
        Characters: Strings(x, "characters"),
        Relationships: Strings(x, "relationships"),
        Freeforms: Strings(x, "freeforms"),
        Language: Str(x, "language"),
        WordCount: Int(x, "wordCount"),
        ChapterCount: Int(x, "chapterCount"),
        TotalChapters: IntN(x, "totalChapters"),
        Kudos: Int(x, "kudos"),
        Hits: Int(x, "hits"),
        BookmarksCount: Int(x, "bookmarksCount"),
        CommentsCount: Int(x, "commentsCount"),
        IsComplete: Bool(x, "isComplete"),
        PublishedAt: DateN(x, "publishedAt"),
        UpdatedAt: DateN(x, "updatedAt"),
        SavedAt: Date(x, "savedAt"),
        LastReadAt: DateN(x, "lastReadAt"),
        LastReadChapter: IntN(x, "lastReadChapter"),
        LastReadProgress: DoubleN(x, "lastReadProgress"),
        IsFollowed: Bool(x, "isFollowed"),
        FollowedAt: DateN(x, "followedAt"),
        LastSeenChapterCount: IntN(x, "lastSeenChapterCount"),
        IsStarred: BoolN(x, "isStarred"),
        IsPinned: BoolN(x, "isPinned"),
        Chapters: Array(x, "chapters", c => new ChapterBackup(Int(c, "index"), Str(c, "title"), Str(c, "bodyHTML"), IntN(c, "aoId"))),
        FolderName: StrN(x, "folderName"),
        FolderNames: Present(x, "folderNames", out _) ? Strings(x, "folderNames") : null);

    private static StatBackup ReadStat(JsonElement x)
    {
        var days = new Dictionary<string, double>();
        var map = Required(x, "daySeconds");
        RequireObject(map);
        foreach (var p in map.EnumerateObject()) days[p.Name] = Number(p.Value, p.Name);
        return new StatBackup(
            Int(x, "ao3Id"), Str(x, "title"), Str(x, "author"),
            Strings(x, "fandoms"), Strings(x, "categories"), Strings(x, "relationships"),
            Str(x, "rating"), Int(x, "wordCount"), Date(x, "firstReadAt"), Date(x, "lastReadAt"),
            Double(x, "totalSeconds"), days, DoubleN(x, "maxProgress"), BoolN(x, "workIsComplete"));
    }

    private static SettingsBackup ReadSettings(JsonElement s)
    {
        RequireObject(s);
        var backup = new SettingsBackup();
        foreach (var field in SettingsBackup.Fields)
        {
            if (!Present(s, field.JsonKey, out var v)) continue;
            switch (field.Kind)
            {
                case SettingKind.String when v.ValueKind == JsonValueKind.String:
                    backup.Values[field.JsonKey] = v.GetString()!;
                    break;
                case SettingKind.Double when v.ValueKind == JsonValueKind.Number:
                    backup.Values[field.JsonKey] = v.GetDouble();
                    break;
                case SettingKind.Bool when v.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    backup.Values[field.JsonKey] = v.GetBoolean();
                    break;
                default:
                    throw new JsonException($"Setting \"{field.JsonKey}\" has the wrong type.");
            }
        }
        return backup;
    }

    private static void RequireObject(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.Object) throw new JsonException("Expected an object.");
    }

    /// <summary>Whether a key is present and not null (Swift's <c>decodeIfPresent</c>).</summary>
    private static bool Present(JsonElement o, string key, out JsonElement value) =>
        o.TryGetProperty(key, out value) && value.ValueKind != JsonValueKind.Null;

    private static JsonElement Required(JsonElement o, string key) =>
        Present(o, key, out var v) ? v : throw new JsonException($"Missing \"{key}\".");

    private static List<T> Array<T>(JsonElement o, string key, Func<JsonElement, T> read)
    {
        var a = Required(o, key);
        if (a.ValueKind != JsonValueKind.Array) throw new JsonException($"\"{key}\" isn't an array.");
        var list = new List<T>(a.GetArrayLength());
        foreach (var item in a.EnumerateArray())
        {
            RequireObject(item);
            list.Add(read(item));
        }
        return list;
    }

    private static string Str(JsonElement o, string key) =>
        Required(o, key) is { ValueKind: JsonValueKind.String } v ? v.GetString()! : throw new JsonException($"\"{key}\" isn't a string.");

    private static string? StrN(JsonElement o, string key) =>
        Present(o, key, out var v) ? v.ValueKind == JsonValueKind.String ? v.GetString() : throw new JsonException($"\"{key}\" isn't a string.") : null;

    private static List<string> Strings(JsonElement o, string key)
    {
        var a = Required(o, key);
        if (a.ValueKind != JsonValueKind.Array) throw new JsonException($"\"{key}\" isn't an array.");
        return a.EnumerateArray()
            .Select(e => e.ValueKind == JsonValueKind.String ? e.GetString()! : throw new JsonException($"\"{key}\" holds a non-string."))
            .ToList();
    }

    private static double Number(JsonElement v, string key) =>
        v.ValueKind == JsonValueKind.Number ? v.GetDouble() : throw new JsonException($"\"{key}\" isn't a number.");

    private static int ToInt(JsonElement v, string key)
    {
        if (v.ValueKind != JsonValueKind.Number) throw new JsonException($"\"{key}\" isn't a number.");
        if (v.TryGetInt32(out var i)) return i;
        var d = v.GetDouble();
        if (d == Math.Floor(d) && d >= int.MinValue && d <= int.MaxValue) return (int)d;
        throw new JsonException($"\"{key}\" isn't an integer.");
    }

    private static int Int(JsonElement o, string key) => ToInt(Required(o, key), key);
    private static int? IntN(JsonElement o, string key) => Present(o, key, out var v) ? ToInt(v, key) : null;
    private static double Double(JsonElement o, string key) => Number(Required(o, key), key);
    private static double? DoubleN(JsonElement o, string key) => Present(o, key, out var v) ? Number(v, key) : null;

    private static bool ToBool(JsonElement v, string key) => v.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => throw new JsonException($"\"{key}\" isn't a bool."),
    };

    private static bool Bool(JsonElement o, string key) => ToBool(Required(o, key), key);
    private static bool? BoolN(JsonElement o, string key) => Present(o, key, out var v) ? ToBool(v, key) : null;

    private static DateTimeOffset ToDate(JsonElement v, string key) =>
        v.ValueKind == JsonValueKind.String ? ParseDate(v.GetString()!) : throw new JsonException($"\"{key}\" isn't a date string.");

    private static DateTimeOffset Date(JsonElement o, string key) => ToDate(Required(o, key), key);
    private static DateTimeOffset? DateN(JsonElement o, string key) => Present(o, key, out var v) ? ToDate(v, key) : null;
}
