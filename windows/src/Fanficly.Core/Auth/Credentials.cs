using System.Globalization;
using System.Net;
using System.Text.Json;

namespace Fanficly.Core;

/// <summary>A persisted HTTP cookie — AO3's session cookie is the only secret the
/// app keeps.</summary>
public sealed record SerializableCookie(
    string Name,
    string Value,
    string Domain,
    string Path,
    DateTimeOffset? ExpiresDate,
    bool IsSecure,
    bool IsHttpOnly)
{
    public static SerializableCookie FromCookie(Cookie cookie) => new(
        cookie.Name,
        cookie.Value,
        cookie.Domain,
        cookie.Path,
        // A session cookie has no expiry (Cookie.Expires is MinValue).
        cookie.Expires == DateTime.MinValue ? null : new DateTimeOffset(cookie.Expires.ToUniversalTime(), TimeSpan.Zero),
        cookie.Secure,
        cookie.HttpOnly);

    public Cookie ToCookie()
    {
        var cookie = new Cookie(Name, Value, Path, Domain) { Secure = IsSecure, HttpOnly = IsHttpOnly };
        if (ExpiresDate is { } expires) cookie.Expires = expires.UtcDateTime;
        return cookie;
    }

    /// <summary>The cookies as a JSON array (what a vault stores).</summary>
    public static string ToJson(IEnumerable<SerializableCookie> cookies)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream))
        {
            w.WriteStartArray();
            foreach (var c in cookies)
            {
                w.WriteStartObject();
                w.WriteString("name", c.Name);
                w.WriteString("value", c.Value);
                w.WriteString("domain", c.Domain);
                w.WriteString("path", c.Path);
                if (c.ExpiresDate is { } e) w.WriteString("expiresDate", e.ToString("O", CultureInfo.InvariantCulture));
                w.WriteBoolean("isSecure", c.IsSecure);
                w.WriteBoolean("isHTTPOnly", c.IsHttpOnly);
                w.WriteEndObject();
            }
            w.WriteEndArray();
        }
        return System.Text.Encoding.UTF8.GetString(stream.ToArray());
    }

    /// <summary>Reads <see cref="ToJson"/> output. Anything unreadable yields an empty
    /// list (as the Swift store's failed decode does) — never an exception.</summary>
    public static IReadOnlyList<SerializableCookie> ListFromJson(string? json)
    {
        if (string.IsNullOrEmpty(json)) return [];
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return [];
            var result = new List<SerializableCookie>();
            foreach (var o in doc.RootElement.EnumerateArray())
            {
                if (o.ValueKind != JsonValueKind.Object) return [];
                string? Str(string key) => o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
                bool Bool(string key) => o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;
                if (Str("name") is not { } name || Str("value") is not { } value
                    || Str("domain") is not { } domain || Str("path") is not { } path)
                    return [];
                DateTimeOffset? expires = Str("expiresDate") is { } raw
                    && DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var d) ? d : null;
                result.Add(new SerializableCookie(name, value, domain, path, expires, Bool("isSecure"), Bool("isHTTPOnly")));
            }
            return result;
        }
        catch (JsonException)
        {
            return [];
        }
    }
}

/// <summary>Where the AO3 username and session cookies persist (Swift's
/// <c>CredentialStore</c>, backed by the Keychain). The Windows app implements it
/// with the Windows credential locker / DPAPI.</summary>
public interface ICookieVault
{
    string? StoredUsername();

    /// <summary>Stores the logged-in username; null or "" clears it <em>and</em> the
    /// saved cookies (logout).</summary>
    void SetUsername(string? username);

    void SaveCookies(IReadOnlyList<SerializableCookie> cookies);

    IReadOnlyList<SerializableCookie> LoadCookies();
}

/// <summary>A vault over any string secret store: the username under
/// <c>ao3.username</c> and the cookies as JSON under <c>ao3.cookies</c>, the same keys
/// the Swift app uses in its Keychain. Platform vaults only supply the three
/// primitives.</summary>
public abstract class KeyedCookieVault : ICookieVault
{
    public const string UsernameKey = "ao3.username";
    public const string CookiesKey = "ao3.cookies";

    protected abstract string? Read(string key);
    protected abstract void Write(string key, string value);
    protected abstract void Delete(string key);

    public string? StoredUsername() => Read(UsernameKey);

    public void SetUsername(string? username)
    {
        if (!string.IsNullOrEmpty(username))
        {
            Write(UsernameKey, username);
        }
        else
        {
            Delete(UsernameKey);
            Delete(CookiesKey);
        }
    }

    public void SaveCookies(IReadOnlyList<SerializableCookie> cookies) => Write(CookiesKey, SerializableCookie.ToJson(cookies));

    public IReadOnlyList<SerializableCookie> LoadCookies() => SerializableCookie.ListFromJson(Read(CookiesKey));
}

/// <summary>An in-memory vault, for tests, previews and demo runs.</summary>
public sealed class InMemoryCookieVault : KeyedCookieVault
{
    private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);
    private readonly Lock _gate = new();

    protected override string? Read(string key)
    {
        lock (_gate) return _values.TryGetValue(key, out var v) ? v : null;
    }

    protected override void Write(string key, string value)
    {
        lock (_gate) _values[key] = value;
    }

    protected override void Delete(string key)
    {
        lock (_gate) _values.Remove(key);
    }
}

/// <summary>The process-wide vault (Swift's <c>CredentialStore.shared</c>). The app
/// installs its platform vault at launch, before creating the AO3 client.</summary>
public static class CredentialStore
{
    public static ICookieVault Shared { get; set; } = new InMemoryCookieVault();
}
