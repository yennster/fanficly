using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;

namespace Fanficly.Core.Tests;

/// <summary>What's New (#422; the Swift WhatsNewTests): the shared changelog's
/// releases for this app, and when the dialog shows after an update.</summary>
public sealed partial class WhatsNewTests
{
    private const string Sample = """
        {
          "about": "ignored",
          "releases": [
            { "version": "2.1.0", "themes": [
                { "icon": "sparkles", "title": "Both", "detail": "Everywhere." },
                { "icon": "bell", "title": "Mac", "detail": "Apple only.", "platforms": ["apple"] },
                { "icon": "book", "title": "PC", "detail": "Windows only.", "platforms": ["windows"] }
            ] },
            { "version": "2.0.1", "date": "2026-11-02", "themes": [
                { "icon": "book", "title": "PC", "detail": "Windows only.", "platforms": ["windows"] }
            ] },
            { "version": "2.0.0", "date": "2026-10-19", "platforms": ["apple"], "themes": [
                { "icon": "book", "title": "Old", "detail": "From the release's platforms." }
            ] }
          ]
        }
        """;

    [Fact]
    public void KeepsOnlyThisAppsThemes_AndDropsEmptyReleases()
    {
        var windows = WhatsNew.Parse(Sample);
        Assert.Equal(["2.1.0", "2.0.1"], windows.Select(r => r.Version));
        Assert.Equal(["Both", "PC"], windows[0].Themes.Select(t => t.Title));
        Assert.Equal(new DateOnly(2026, 11, 2), windows[1].Date);
        Assert.Null(windows[0].Date);

        var apple = WhatsNew.Parse(Sample, "apple");
        Assert.Equal(["2.1.0", "2.0.0"], apple.Select(r => r.Version));
        Assert.Equal(["Both", "Mac"], apple[0].Themes.Select(t => t.Title));
        Assert.Equal(["Old"], apple[1].Themes.Select(t => t.Title));
    }

    [Fact]
    public void ShowsOnlyShippedReleases() =>
        Assert.Equal(["2.0.1"], WhatsNew.Released(WhatsNew.Parse(Sample)).Select(r => r.Version));

    [Fact]
    public void DisplayVersion_DropsATrailingZero()
    {
        Assert.Equal("1.14", new WhatsNewRelease("1.14.0", null, []).DisplayVersion);
        Assert.Equal("1.11.1", new WhatsNewRelease("1.11.1", null, []).DisplayVersion);
    }

    private static readonly WhatsNewRelease Newest = new("2.1.0", null, [new("sparkles", "T", "D")]);

    [Fact]
    public void AnUpdateShowsTheNewestRelease_OnlyOnce()
    {
        Assert.Equal(WhatsNew.Action.Show, WhatsNew.LaunchDecision(Newest, "2.0.0", isExistingUser: true, openedIntoContent: false));
        // Updating from a version from before What's New shows it too.
        Assert.Equal(WhatsNew.Action.Show, WhatsNew.LaunchDecision(Newest, null, isExistingUser: true, openedIntoContent: false));
        Assert.Equal(WhatsNew.Action.Nothing, WhatsNew.LaunchDecision(Newest, "2.1.0", isExistingUser: true, openedIntoContent: false));
    }

    [Fact]
    public void AFreshInstallRecordsWithoutShowing()
    {
        Assert.Equal(WhatsNew.Action.Record, WhatsNew.LaunchDecision(Newest, null, isExistingUser: false, openedIntoContent: false));
        Assert.Equal(WhatsNew.Action.Record, WhatsNew.LaunchDecision(Newest, null, isExistingUser: false, openedIntoContent: true));
    }

    [Fact]
    public void ALaunchIntoAStoryWaitsForTheNextLaunch() =>
        Assert.Equal(WhatsNew.Action.Nothing, WhatsNew.LaunchDecision(Newest, "2.0.0", isExistingUser: true, openedIntoContent: true));

    [Fact]
    public void NoChangelogDoesNothing() =>
        Assert.Equal(WhatsNew.Action.Nothing, WhatsNew.LaunchDecision(null, null, isExistingUser: true, openedIntoContent: false));

    private static string AppFolder([CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "..", "src", "Fanficly.App"));

    [GeneratedRegex(@"\[""([a-z0-9.]+)""\]\s*=|Symbols\.Add\(""([a-z0-9.]+)""")]
    private static partial Regex SymbolName();

    [Fact]
    public void TheEmbeddedChangelogIsValid_AndEveryIconHasAGlyph()
    {
        var all = WhatsNew.Parse(WhatsNew.EmbeddedJson(), "apple").Concat(WhatsNew.Parse(WhatsNew.EmbeddedJson()));
        var mine = WhatsNew.AllReleases;
        Assert.NotEmpty(mine);
        Assert.Equal(mine.Count, mine.Select(r => r.Version).Distinct().Count());

        // The icons are SF Symbol names; the app's Symbols map draws each one.
        var mapped = Directory.EnumerateFiles(Path.Combine(AppFolder(), "UI"), "*.cs")
            .SelectMany(file => SymbolName().Matches(File.ReadAllText(file))
                .Select(m => m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value))
            .ToHashSet();
        foreach (var release in all)
            foreach (var theme in release.Themes)
            {
                Assert.False(string.IsNullOrWhiteSpace(theme.Title), release.Version);
                Assert.False(string.IsNullOrWhiteSpace(theme.Detail), release.Version);
                Assert.True(mapped.Contains(theme.Icon), $"{release.Version}: no Windows glyph for {theme.Icon} (UI/Symbols.cs)");
            }
    }
}
