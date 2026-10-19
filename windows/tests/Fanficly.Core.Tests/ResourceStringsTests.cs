using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace Fanficly.Core.Tests;

/// <summary>Every <c>Strings.Get("key")</c> in the app has an entry in
/// <c>Strings/en-US/Resources.resw</c>, and every entry is used. (The lookup
/// itself needs MakePri, so the UI tests check it on Windows.)</summary>
public sealed partial class ResourceStringsTests
{
    private static string AppFolder([CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "..", "src", "Fanficly.App"));

    [GeneratedRegex("""Strings\.Get\("([^"]+)"\)""")]
    private static partial Regex GetCall();

    private static HashSet<string> UsedKeys() =>
        Directory.EnumerateFiles(AppFolder(), "*.cs", SearchOption.AllDirectories)
            .SelectMany(file => GetCall().Matches(File.ReadAllText(file)).Select(m => m.Groups[1].Value))
            .ToHashSet();

    private static Dictionary<string, string> TableEntries() =>
        XDocument.Load(Path.Combine(AppFolder(), "Strings", "en-US", "Resources.resw"))
            .Root!.Elements("data")
            .ToDictionary(d => (string)d.Attribute("name")!, d => (string?)d.Element("value") ?? "");

    [Fact]
    public void EveryKeyInTheCodeIsInTheTable()
    {
        var table = TableEntries();
        var used = UsedKeys();
        Assert.NotEmpty(used);
        Assert.Empty(used.Where(key => !table.ContainsKey(key)));
    }

    [Fact]
    public void EveryTableEntryIsUsedAndHasText()
    {
        var used = UsedKeys();
        foreach (var (key, value) in TableEntries())
        {
            Assert.Contains(key, used);
            Assert.False(string.IsNullOrWhiteSpace(value), $"{key} has no text.");
            Assert.DoesNotContain('.', key);
        }
    }
}
