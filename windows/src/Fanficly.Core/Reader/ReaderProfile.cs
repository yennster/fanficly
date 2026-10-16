using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Fanficly.Core;

/// <summary>Which device's reader settings apply. Typography is per-device: every
/// reader key goes through <see cref="ReaderProfile.DeviceKey(string)"/>.</summary>
public enum ReaderDevice { Phone, Pad, Mac, Windows }

public static class ReaderDeviceExtensions
{
    /// <summary>The settings-key suffix: <c>.phone</c>, <c>.pad</c>, <c>.mac</c>, <c>.windows</c>.</summary>
    public static string KeySuffix(this ReaderDevice device) => device switch
    {
        ReaderDevice.Phone => ".phone",
        ReaderDevice.Pad => ".pad",
        ReaderDevice.Mac => ".mac",
        ReaderDevice.Windows => ".windows",
        _ => throw new ArgumentOutOfRangeException(nameof(device)),
    };
}

/// <summary>A named set of reader typography settings. Stored as a JSON array under
/// <c>reader.profiles</c> in exactly the Swift app's shape (same keys, same order,
/// absent optionals omitted), so profiles round-trip between the Apple apps and
/// Windows.
///
/// <see cref="UpdatedAt"/>/<see cref="DeletedAt"/> are sync bookkeeping (seconds since
/// 1970). Optional (like <see cref="WidthRaw"/>) so pre-existing JSON still decodes
/// and older app versions ignore the unknown keys — the stored top-level shape must
/// stay a plain array. An entry with <see cref="DeletedAt"/> set is a tombstone: it
/// keeps its full payload (older decoders would fail on missing required fields)
/// and stays in the stored array so the deletion propagates through
/// <see cref="MergedProfiles"/>, but <see cref="LoadProfiles"/> hides it.</summary>
public sealed record ReaderProfile
{
    public string Id => Name;
    public required string Name { get; init; }
    public required string ThemeRaw { get; init; }
    public required string FontFamilyRaw { get; init; }
    public string? WidthRaw { get; init; }
    public double? WidthPercent { get; init; }
    public required string ModeRaw { get; init; }
    public required double FontSizePt { get; init; }
    public required double LineSpacingPt { get; init; }
    public required double ParagraphSpacingPt { get; init; }
    public required bool PageTurnHaptics { get; init; }
    public required bool PageTurnAnimations { get; init; }
    public double? KerningPt { get; init; }
    public bool? BoldText { get; init; }
    public double? UpdatedAt { get; init; }
    public double? DeletedAt { get; init; }

    public bool IsDeleted => DeletedAt is not null;

    /// <summary>Tombstones older than this (90 days) are pruned on save/merge. A device
    /// that hasn't synced within the window can resurrect the profile — the trade-off
    /// for not growing the stored JSON forever.</summary>
    public static readonly TimeSpan TombstoneLifetime = TimeSpan.FromDays(90);

    public bool IsExpiredTombstone(DateTimeOffset now) =>
        DeletedAt is { } deletedAt && UnixSeconds(now) - deletedAt > TombstoneLifetime.TotalSeconds;

    /// <summary>Equality ignoring the sync bookkeeping, used to decide whether a save
    /// actually changed a profile and should stamp a fresh <see cref="UpdatedAt"/>.</summary>
    public bool ContentEquals(ReaderProfile other) =>
        this with { UpdatedAt = null, DeletedAt = null } == other with { UpdatedAt = null, DeletedAt = null };

    // MARK: - Per-device keys

    /// <summary>The device this app's settings belong to. The Windows app keeps the
    /// default; tests may switch it.</summary>
    public static ReaderDevice CurrentDevice { get; set; } = ReaderDevice.Windows;

    /// <summary>This device's active-profile key, e.g. <c>reader.activeProfile.windows</c>.</summary>
    public static string DeviceActiveProfileKey => "reader.activeProfile" + CurrentDevice.KeySuffix();

    /// <summary><paramref name="baseKey"/> for this device, e.g. <c>reader.theme.windows</c>.</summary>
    public static string DeviceKey(string baseKey) => DeviceKey(baseKey, CurrentDevice);

    public static string DeviceKey(string baseKey, ReaderDevice device) => baseKey + device.KeySuffix();

    /// <summary>The reader keys that were once stored without a device suffix.</summary>
    public static readonly IReadOnlyList<string> LegacySettingKeys =
    [
        "reader.theme",
        "reader.fontFamily",
        "reader.widthPercent",
        "reader.mode",
        "reader.fontSizePt",
        "reader.lineSpacingPt",
        "reader.paragraphSpacingPt",
        "reader.pageTurnHaptics",
        "reader.pageTurnAnimations",
        "reader.kerningPt",
        "reader.boldText",
    ];

    /// <summary>Copies each legacy un-suffixed reader setting to this device's key,
    /// once: only where the device key isn't set yet. (On Windows the legacy keys
    /// only exist in settings restored from an Apple backup.)</summary>
    public static void MigrateLegacySettingsIfNeeded(IKeyValueStore? store = null)
    {
        var defaults = store ?? KeyValueStores.Default;
        var suffix = CurrentDevice.KeySuffix();
        foreach (var key in LegacySettingKeys)
        {
            var deviceKey = key + suffix;
            if (defaults.Contains(deviceKey)) continue;
            if (defaults.GetString(key) is { } legacyValue) defaults.SetString(deviceKey, legacyValue);
        }
    }

    // MARK: - Defaults

    public static readonly IReadOnlyList<ReaderProfile> DefaultProfiles =
    [
        new ReaderProfile
        {
            Name = "Default",
            ThemeRaw = ReaderTheme.System.RawValue(),
            FontFamilyRaw = ReaderFontFamily.NewYork.RawValue(),
            WidthRaw = ReaderWidth.Medium.RawValue(),
            WidthPercent = 70.0,
            ModeRaw = ReadingMode.Continuous.RawValue(),
            FontSizePt = ReaderMetrics.DefaultFontSize,
            LineSpacingPt = ReaderMetrics.DefaultLineSpacing,
            ParagraphSpacingPt = ReaderMetrics.DefaultParagraphSpacing,
            PageTurnHaptics = false,
            PageTurnAnimations = true,
            KerningPt = ReaderMetrics.DefaultKerning,
            BoldText = false,
        },
    ];

    // MARK: - JSON

    /// <summary>Decodes every stored entry, including deletion tombstones (display paths
    /// use <see cref="LoadProfiles"/>, which filters them out). Null when the JSON
    /// isn't a valid profile array — like Swift's <c>JSONDecoder</c>, one bad entry
    /// fails the whole list. Entries without <see cref="WidthPercent"/> get it from
    /// their legacy <see cref="WidthRaw"/>.</summary>
    public static List<ReaderProfile>? DecodeProfiles(string? jsonString)
    {
        if (string.IsNullOrEmpty(jsonString)) return null;
        List<ReaderProfile> list;
        try
        {
            using var doc = JsonDocument.Parse(jsonString);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return null;
            list = [];
            foreach (var element in doc.RootElement.EnumerateArray())
            {
                if (Decode(element) is not { } profile) return null;
                list.Add(profile);
            }
        }
        catch (JsonException)
        {
            return null;
        }

        for (var i = 0; i < list.Count; i++)
        {
            if (list[i].WidthPercent is not null) continue;
            var percent = list[i].WidthRaw switch
            {
                null => 70.0,
                "narrow" => 50.0,
                "medium" => 70.0,
                "wide" => 85.0,
                "full" => 100.0,
                _ => 70.0,
            };
            list[i] = list[i] with { WidthPercent = percent };
        }
        return list;
    }

    /// <summary>The live profiles (tombstones hidden); <see cref="DefaultProfiles"/>
    /// when the JSON can't be decoded.</summary>
    public static IReadOnlyList<ReaderProfile> LoadProfiles(string? jsonString)
    {
        if (DecodeProfiles(jsonString) is not { } list) return DefaultProfiles;
        return list.Where(p => !p.IsDeleted).ToList();
    }

    /// <summary>Encodes a profile list as is (no bookkeeping).</summary>
    public static string SaveProfiles(IEnumerable<ReaderProfile> list)
    {
        var sb = new StringBuilder("[");
        var first = true;
        foreach (var profile in list)
        {
            if (!first) sb.Append(',');
            first = false;
            Encode(profile, sb);
        }
        return sb.Append(']').ToString();
    }

    /// <summary>Encodes an edited profile list, carrying the sync bookkeeping forward
    /// from the previously stored JSON: entries whose content changed are stamped
    /// <see cref="UpdatedAt"/>, and names that disappeared from
    /// <paramref name="list"/> are kept as tombstones so <see cref="MergedProfiles"/>
    /// can tell a deletion apart from a stale copy that should be resurrected.
    /// Expired tombstones are pruned.</summary>
    public static string SaveProfiles(IEnumerable<ReaderProfile> list, string? previousJSON, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow;
        var previous = DecodeProfiles(previousJSON ?? "") ?? [];
        var timestamp = UnixSeconds(at);
        var edited = list.ToList();

        var result = edited.Select(profile =>
        {
            var entry = profile with { DeletedAt = null };
            var prior = previous.FirstOrDefault(p => SameName(p.Name, profile.Name));
            return prior is not null && !prior.IsDeleted && prior.ContentEquals(entry)
                ? entry with { UpdatedAt = prior.UpdatedAt }
                : entry with { UpdatedAt = timestamp };
        }).ToList();

        foreach (var prior in previous)
        {
            if (edited.Any(p => SameName(p.Name, prior.Name))) continue;
            var tombstone = prior.DeletedAt is null ? prior with { DeletedAt = timestamp } : prior;
            if (!tombstone.IsExpiredTombstone(at)) result.Add(tombstone);
        }

        return SaveProfiles(result);
    }

    /// <summary>Merges two stored-profile JSON strings, resolving per-name conflicts via
    /// <see cref="Resolve"/> so deletions and edits beat stale copies instead of being
    /// unioned back in. Expired tombstones are pruned.</summary>
    public static string MergedProfiles(string? localJSON, string incomingJSON, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow;
        var merged = DecodeProfiles(localJSON ?? "") ?? [];
        foreach (var profile in DecodeProfiles(incomingJSON) ?? [])
        {
            var index = merged.FindIndex(p => SameName(p.Name, profile.Name));
            if (index >= 0) merged[index] = Resolve(merged[index], profile);
            else merged.Add(profile);
        }
        merged.RemoveAll(p => p.IsExpiredTombstone(at));
        return SaveProfiles(merged);
    }

    /// <summary>Conflict resolution for two copies of the same profile: the newest
    /// UpdatedAt/DeletedAt stamp wins, so an edit or deletion beats any stale copy (a
    /// stamp-less pre-tombstone entry counts as oldest). On an exact tie a tombstone
    /// beats a live copy so a same-instant echo can't undo a delete; between
    /// equal-aged live copies the incoming side wins, preserving the original union
    /// behavior for legacy entries.</summary>
    private static ReaderProfile Resolve(ReaderProfile current, ReaderProfile incoming)
    {
        var currentStamp = Math.Max(current.UpdatedAt ?? 0, current.DeletedAt ?? 0);
        var incomingStamp = Math.Max(incoming.UpdatedAt ?? 0, incoming.DeletedAt ?? 0);
        if (incomingStamp != currentStamp) return incomingStamp > currentStamp ? incoming : current;
        if (current.IsDeleted != incoming.IsDeleted) return current.IsDeleted ? current : incoming;
        return incoming;
    }

    /// <summary>Profile names match case-insensitively in the current culture (Swift's
    /// <c>localizedCaseInsensitiveCompare</c>).</summary>
    private static bool SameName(string a, string b) => string.Compare(a, b, CultureInfo.CurrentCulture,
        CompareOptions.IgnoreCase) == 0;

    internal static double UnixSeconds(DateTimeOffset date) => (date - DateTimeOffset.UnixEpoch).TotalSeconds;

    private static ReaderProfile? Decode(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        if (!RequiredString(e, "name", out var name) || !RequiredString(e, "themeRaw", out var theme)
            || !RequiredString(e, "fontFamilyRaw", out var font) || !RequiredString(e, "modeRaw", out var mode)
            || !RequiredDouble(e, "fontSizePt", out var size) || !RequiredDouble(e, "lineSpacingPt", out var line)
            || !RequiredDouble(e, "paragraphSpacingPt", out var paragraph)
            || !RequiredBool(e, "pageTurnHaptics", out var haptics) || !RequiredBool(e, "pageTurnAnimations", out var animations)
            || !OptionalString(e, "widthRaw", out var widthRaw) || !OptionalDouble(e, "widthPercent", out var widthPercent)
            || !OptionalDouble(e, "kerningPt", out var kerning) || !OptionalBool(e, "boldText", out var bold)
            || !OptionalDouble(e, "updatedAt", out var updatedAt) || !OptionalDouble(e, "deletedAt", out var deletedAt))
            return null;
        return new ReaderProfile
        {
            Name = name, ThemeRaw = theme, FontFamilyRaw = font, WidthRaw = widthRaw, WidthPercent = widthPercent,
            ModeRaw = mode, FontSizePt = size, LineSpacingPt = line, ParagraphSpacingPt = paragraph,
            PageTurnHaptics = haptics, PageTurnAnimations = animations, KerningPt = kerning, BoldText = bold,
            UpdatedAt = updatedAt, DeletedAt = deletedAt,
        };
    }

    private static bool RequiredString(JsonElement e, string key, out string value)
    {
        value = "";
        if (!e.TryGetProperty(key, out var p) || p.ValueKind != JsonValueKind.String) return false;
        value = p.GetString()!;
        return true;
    }

    private static bool RequiredDouble(JsonElement e, string key, out double value)
    {
        value = 0;
        return e.TryGetProperty(key, out var p) && p.ValueKind == JsonValueKind.Number && p.TryGetDouble(out value);
    }

    private static bool RequiredBool(JsonElement e, string key, out bool value)
    {
        value = false;
        if (!e.TryGetProperty(key, out var p) || p.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) return false;
        value = p.GetBoolean();
        return true;
    }

    // Optional fields: absent or null → null; any other wrong type fails the decode.
    private static bool OptionalString(JsonElement e, string key, out string? value)
    {
        value = null;
        if (!e.TryGetProperty(key, out var p) || p.ValueKind == JsonValueKind.Null) return true;
        if (p.ValueKind != JsonValueKind.String) return false;
        value = p.GetString();
        return true;
    }

    private static bool OptionalDouble(JsonElement e, string key, out double? value)
    {
        value = null;
        if (!e.TryGetProperty(key, out var p) || p.ValueKind == JsonValueKind.Null) return true;
        if (p.ValueKind != JsonValueKind.Number || !p.TryGetDouble(out var d)) return false;
        value = d;
        return true;
    }

    private static bool OptionalBool(JsonElement e, string key, out bool? value)
    {
        value = null;
        if (!e.TryGetProperty(key, out var p) || p.ValueKind == JsonValueKind.Null) return true;
        if (p.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) return false;
        value = p.GetBoolean();
        return true;
    }

    /// <summary>Writes one profile the way Swift's <c>JSONEncoder</c> does: declared
    /// key order, nil optionals omitted, integral doubles without a fraction, "/"
    /// escaped.</summary>
    private static void Encode(ReaderProfile p, StringBuilder sb)
    {
        sb.Append('{');
        WriteString(sb, "name", p.Name, first: true);
        WriteString(sb, "themeRaw", p.ThemeRaw);
        WriteString(sb, "fontFamilyRaw", p.FontFamilyRaw);
        if (p.WidthRaw is { } widthRaw) WriteString(sb, "widthRaw", widthRaw);
        if (p.WidthPercent is { } widthPercent) WriteNumber(sb, "widthPercent", widthPercent);
        WriteString(sb, "modeRaw", p.ModeRaw);
        WriteNumber(sb, "fontSizePt", p.FontSizePt);
        WriteNumber(sb, "lineSpacingPt", p.LineSpacingPt);
        WriteNumber(sb, "paragraphSpacingPt", p.ParagraphSpacingPt);
        WriteBool(sb, "pageTurnHaptics", p.PageTurnHaptics);
        WriteBool(sb, "pageTurnAnimations", p.PageTurnAnimations);
        if (p.KerningPt is { } kerning) WriteNumber(sb, "kerningPt", kerning);
        if (p.BoldText is { } bold) WriteBool(sb, "boldText", bold);
        if (p.UpdatedAt is { } updatedAt) WriteNumber(sb, "updatedAt", updatedAt);
        if (p.DeletedAt is { } deletedAt) WriteNumber(sb, "deletedAt", deletedAt);
        sb.Append('}');
    }

    private static void WriteKey(StringBuilder sb, string key, bool first)
    {
        if (!first) sb.Append(',');
        AppendJsonString(sb, key);
        sb.Append(':');
    }

    private static void WriteString(StringBuilder sb, string key, string value, bool first = false)
    {
        WriteKey(sb, key, first);
        AppendJsonString(sb, value);
    }

    private static void WriteNumber(StringBuilder sb, string key, double value)
    {
        WriteKey(sb, key, false);
        // JSON has no NaN/Infinity; Swift's encoder would throw, so store 0.
        sb.Append(double.IsFinite(value) ? value.ToString("R", CultureInfo.InvariantCulture) : "0");
    }

    private static void WriteBool(StringBuilder sb, string key, bool value)
    {
        WriteKey(sb, key, false);
        sb.Append(value ? "true" : "false");
    }

    private static void AppendJsonString(StringBuilder sb, string value)
    {
        sb.Append('"');
        foreach (var c in value)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '/': sb.Append("\\/"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }
}
