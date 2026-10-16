using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace Fanficly.Core;

/// <summary>How the library database stores list and dictionary fields: as
/// small JSON texts (SwiftData stores them as transformable blobs). Written by
/// hand with <see cref="Utf8JsonWriter"/> so it stays Native-AOT safe.</summary>
internal static class LibraryJson
{
    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private static string Write(Action<Utf8JsonWriter> body)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream, WriterOptions)) body(w);
        return Encoding.UTF8.GetString(stream.GetBuffer(), 0, (int)stream.Length);
    }

    public static string Strings(IReadOnlyList<string> values) => Write(w =>
    {
        w.WriteStartArray();
        foreach (var v in values) w.WriteStringValue(v);
        w.WriteEndArray();
    });

    public static string Ints(IReadOnlyList<int> values) => Write(w =>
    {
        w.WriteStartArray();
        foreach (var v in values) w.WriteNumberValue(v);
        w.WriteEndArray();
    });

    /// <summary>Keys sorted so equal dictionaries always serialize identically
    /// (the store's change detection compares these texts).</summary>
    public static string DoubleMap(IReadOnlyDictionary<string, double> values) => Write(w =>
    {
        w.WriteStartObject();
        foreach (var (k, v) in values.OrderBy(kv => kv.Key, StringComparer.Ordinal)) w.WriteNumber(k, v);
        w.WriteEndObject();
    });

    public static List<string> ParseStrings(string? json)
    {
        var result = new List<string>();
        if (string.IsNullOrEmpty(json)) return result;
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return result;
            foreach (var e in doc.RootElement.EnumerateArray())
                if (e.ValueKind == JsonValueKind.String) result.Add(e.GetString()!);
        }
        catch (JsonException) { }
        return result;
    }

    public static List<int> ParseInts(string? json)
    {
        var result = new List<int>();
        if (string.IsNullOrEmpty(json)) return result;
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return result;
            foreach (var e in doc.RootElement.EnumerateArray())
                if (e.ValueKind == JsonValueKind.Number && e.TryGetInt32(out var i)) result.Add(i);
        }
        catch (JsonException) { }
        return result;
    }

    public static Dictionary<string, double> ParseDoubleMap(string? json)
    {
        var result = new Dictionary<string, double>();
        if (string.IsNullOrEmpty(json)) return result;
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return result;
            foreach (var p in doc.RootElement.EnumerateObject())
                if (p.Value.ValueKind == JsonValueKind.Number) result[p.Name] = p.Value.GetDouble();
        }
        catch (JsonException) { }
        return result;
    }
}
