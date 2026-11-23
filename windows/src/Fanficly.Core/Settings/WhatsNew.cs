using System.Globalization;
using System.Reflection;
using System.Text.Json;

namespace Fanficly.Core;

/// <summary>One theme of a release: an icon (an SF Symbol name, mapped by the
/// app's Symbols), a short title and one line.</summary>
public sealed record WhatsNewTheme(string Icon, string Title, string Detail);

/// <summary>One release in the shared changelog, with only this app's themes.</summary>
public sealed record WhatsNewRelease(string Version, DateOnly? Date, IReadOnlyList<WhatsNewTheme> Themes)
{
    /// <summary>"1.14" for "1.14.0"; "1.11.1" as it is.</summary>
    public string DisplayVersion
    {
        get
        {
            var parts = Version.Split('.');
            return parts.Length == 3 && parts[2] == "0" ? $"{parts[0]}.{parts[1]}" : Version;
        }
    }
}

/// <summary>
/// What's New (#422; the Swift <c>WhatsNew</c>): a dialog the first time the
/// app opens after an update, and Settings → About → What's New with every
/// release. The text is the repository's changelog/whats-new.json, shared with
/// the Apple app and embedded in this assembly, so nothing is fetched. The
/// release workflow's store notes come from the same entry.
/// </summary>
public static class WhatsNew
{
    /// <summary>This app's name in the changelog's <c>platforms</c> lists.</summary>
    public const string Platform = "windows";

    /// <summary>"whatsNew.lastSeenVersion": the newest release whose What's New
    /// this PC has shown (or skipped on a fresh install). The Apple app's key.</summary>
    public const string LastSeenKey = "whatsNew.lastSeenVersion";

    private const string ResourceName = "Fanficly.Core.whats-new.json";

    /// <summary>The changelog's releases for <paramref name="platform"/>, newest
    /// first: each keeps only the themes for that platform (a theme's own
    /// <c>platforms</c>, else its release's, else every platform), and a release
    /// left with none is dropped.</summary>
    public static IReadOnlyList<WhatsNewRelease> Parse(string json, string platform = Platform)
    {
        using var doc = JsonDocument.Parse(json);
        var releases = new List<WhatsNewRelease>();
        foreach (var release in doc.RootElement.GetProperty("releases").EnumerateArray())
        {
            var releasePlatforms = Platforms(release);
            var themes = new List<WhatsNewTheme>();
            foreach (var theme in release.GetProperty("themes").EnumerateArray())
            {
                var platforms = Platforms(theme) ?? releasePlatforms;
                if (platforms is not null && !platforms.Contains(platform)) continue;
                themes.Add(new WhatsNewTheme(
                    theme.GetProperty("icon").GetString() ?? "",
                    theme.GetProperty("title").GetString() ?? "",
                    theme.GetProperty("detail").GetString() ?? ""));
            }
            if (themes.Count == 0) continue;
            DateOnly? date = release.TryGetProperty("date", out var d) && d.ValueKind == JsonValueKind.String
                && DateOnly.TryParseExact(d.GetString(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day)
                ? day : null;
            releases.Add(new WhatsNewRelease(release.GetProperty("version").GetString() ?? "", date, themes));
        }
        return releases;
    }

    private static List<string>? Platforms(JsonElement element) =>
        element.TryGetProperty("platforms", out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Select(p => p.GetString() ?? "").ToList()
            : null;

    /// <summary>The embedded changelog's releases for this app.</summary>
    public static IReadOnlyList<WhatsNewRelease> Releases => _releases ??= Load();
    private static IReadOnlyList<WhatsNewRelease>? _releases;

    /// <summary>The embedded changelog/whats-new.json as text.</summary>
    internal static string EmbeddedJson()
    {
        using var stream = typeof(WhatsNew).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidOperationException($"{ResourceName} isn't embedded");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    private static IReadOnlyList<WhatsNewRelease> Load()
    {
        try { return Parse(EmbeddedJson()); }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException) { return []; }
    }

    public enum Action { Nothing, Record, Show }

    /// <summary>What a launch does with the newest release. <paramref name="isExistingUser"/>:
    /// the app was set up before this launch (the 17+ confirmation was already
    /// given), so this is an update, not a fresh install, which only records
    /// the newest release as seen. <paramref name="openedIntoContent"/>: the
    /// launch opened a story, a link, a file or a share, which the dialog
    /// mustn't cover; it waits for the next plain launch.</summary>
    public static Action LaunchDecision(WhatsNewRelease? newest, string? lastSeen, bool isExistingUser, bool openedIntoContent)
    {
        if (newest is null || lastSeen == newest.Version) return Action.Nothing;
        if (!isExistingUser) return Action.Record;
        return openedIntoContent ? Action.Nothing : Action.Show;
    }
}
