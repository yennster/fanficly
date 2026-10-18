using System.Text;
using System.Text.Json;
using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>The backup file is shared with the Swift app through a synced
/// folder, so it must read what Swift's JSONEncoder writes and write what
/// Swift's JSONDecoder reads: property names as keys, `.iso8601` dates (UTC,
/// whole seconds), nil optionals omitted, escaped slashes tolerated.</summary>
public sealed class LibraryBackupJsonTests
{
    /// <summary>Shaped exactly like the Swift app's output for a small library
    /// (JSONEncoder escapes "/" as "\/" and writes 600.0 as 600).</summary>
    private const string SwiftFixture = """
        {"works":[{"ao3Id":12345,"title":"The Long Way Home","authorName":"wanderlight","authorUsername":"wanderlight","summary":"<p>Two travellers \/ one road.<\/p>","rating":"General Audiences","warnings":["No Archive Warnings Apply"],"categories":["Gen"],"fandoms":["Original Work"],"characters":["Mira"],"relationships":[],"freeforms":["Slow Burn","Found Family"],"language":"English","wordCount":48213,"chapterCount":12,"totalChapters":20,"kudos":1200,"hits":34000,"bookmarksCount":0,"commentsCount":0,"isComplete":false,"updatedAt":"2026-06-01T12:00:00Z","savedAt":"2026-05-30T08:15:30Z","lastReadAt":"2026-06-02T21:04:05Z","lastReadChapter":8,"lastReadProgress":0.66,"isFollowed":true,"followedAt":"2026-05-30T08:15:30Z","lastSeenChapterCount":12,"isStarred":true,"isPinned":false,"chapters":[{"index":1,"title":"Chapter 1","bodyHTML":"<p>It began with a map.<\/p>","aoId":900},{"index":2,"title":"Chapter 2","bodyHTML":"<p>“Quotes” & ünïcödé<\/p>"}],"folderName":"Faves","folderNames":["Faves","To Reread"]}],"bookmarks":[{"ao3Id":77,"workAo3Id":12345,"notes":"","tags":["cosy"],"savedAt":"2026-05-01T00:00:00Z"}],"subscriptions":[{"key":"work:1","kind":"work","displayName":"Fic One","authorName":"alice","lastSeenChapterCount":5,"lastCheckedAt":"2026-06-01T03:00:00Z"},{"key":"user:carol","kind":"user","displayName":"carol","authorName":""}],"searches":[{"name":"Slow burn, complete","prompt":"tag:\"Slow Burn\" complete:yes","sortColumn":"_score","sortDirection":"desc","savedAt":"2026-04-01T10:00:00Z"}],"progress":[{"ao3Id":12345,"chapterIndex":8,"paragraphIndex":42,"title":"The Long Way Home","author":"wanderlight","updatedAt":"2026-06-02T21:04:05Z"}],"filters":[{"name":"Fluff · General","filtersJSON":"{\"freeformNames\":[\"Fluff\"],\"ratings\":[\"10\"]}","savedAt":"2026-04-02T10:00:00Z"}],"hidden":[{"ao3Id":666,"title":"Nope","hiddenAt":"2026-03-03T03:03:03Z"}],"settings":{"theme":"sepia","fontSizePt":22,"lineSpacingPt":4.5,"filterMatureExplicit":true,"profiles":"[{\"name\":\"Default\"}]","themePad":"dracula","fontSizePtMac":18},"folders":[{"name":"Faves","createdAt":"2026-01-01T00:00:00Z"},{"name":"To Reread","createdAt":"2026-01-02T00:00:00Z"}],"stats":[{"ao3Id":12345,"title":"The Long Way Home","author":"wanderlight","fandoms":["Original Work"],"categories":["Gen"],"relationships":[],"rating":"General Audiences","wordCount":48213,"firstReadAt":"2026-05-30T08:20:00Z","lastReadAt":"2026-06-02T21:04:05Z","totalSeconds":3600,"daySeconds":{"2026-05-30":1200,"2026-06-02":2400.5},"maxProgress":0.66,"workIsComplete":false}],"timestamp":"2026-06-02T21:04:06Z"}
        """;

    /// <summary>A backup from before stats, folders, settings, star/pin, chapter
    /// ids, folder lists and stat progress existed.</summary>
    private const string OlderSwiftFixture = """
        {"works":[{"ao3Id":1,"title":"T","authorName":"A","authorUsername":"","summary":"","rating":"Not Rated","warnings":[],"categories":[],"fandoms":[],"characters":[],"relationships":[],"freeforms":[],"language":"en","wordCount":0,"chapterCount":1,"kudos":0,"hits":0,"bookmarksCount":0,"commentsCount":0,"isComplete":false,"savedAt":"2025-01-01T00:00:00Z","isFollowed":false,"chapters":[{"index":1,"title":"Ch","bodyHTML":"<p>x<\/p>"}],"folderName":"Old"}],"bookmarks":[],"subscriptions":[],"searches":[],"progress":[],"filters":[],"hidden":[],"timestamp":"2025-01-01T00:00:00Z"}
        """;

    private static DateTimeOffset Utc(int y, int mo, int d, int h = 0, int mi = 0, int s = 0) => new(y, mo, d, h, mi, s, TimeSpan.Zero);

    [Fact]
    public void DecodesSwiftOutput()
    {
        var b = LibraryBackupJson.Decode(SwiftFixture);

        var w = Assert.Single(b.Works);
        Assert.Equal(12345, w.Ao3Id);
        Assert.Equal("<p>Two travellers / one road.</p>", w.Summary);
        Assert.Equal(["Slow Burn", "Found Family"], w.Freeforms);
        Assert.Equal(20, w.TotalChapters);
        Assert.Null(w.PublishedAt);
        Assert.Equal(Utc(2026, 6, 1, 12), w.UpdatedAt);
        Assert.Equal(Utc(2026, 5, 30, 8, 15, 30), w.SavedAt);
        Assert.Equal(0.66, w.LastReadProgress);
        Assert.True(w.IsFollowed);
        Assert.True(w.IsStarred);
        Assert.False(w.IsPinned);
        Assert.Equal([900, null], w.Chapters.Select(c => c.AoId));
        Assert.Equal("<p>“Quotes” & ünïcödé</p>", w.Chapters[1].BodyHtml);
        Assert.Equal("Faves", w.FolderName);
        Assert.Equal(["Faves", "To Reread"], w.FolderNames!);

        Assert.Equal(["cosy"], Assert.Single(b.Bookmarks).Tags);
        Assert.Equal(5, b.Subscriptions[0].LastSeenChapterCount);
        Assert.Null(b.Subscriptions[1].LastSeenChapterCount);
        Assert.Null(b.Subscriptions[1].LastCheckedAt);
        Assert.Equal("tag:\"Slow Burn\" complete:yes", Assert.Single(b.Searches).Prompt);
        Assert.Equal(42, Assert.Single(b.Progress).ParagraphIndex);
        Assert.Equal("{\"freeformNames\":[\"Fluff\"],\"ratings\":[\"10\"]}", Assert.Single(b.Filters).FiltersJson);
        Assert.Equal(Utc(2026, 3, 3, 3, 3, 3), Assert.Single(b.Hidden).HiddenAt);

        var s = b.Settings!;
        Assert.Equal("sepia", s.GetString("theme"));
        Assert.Equal(22, s.GetDouble("fontSizePt"));
        Assert.Equal(4.5, s.GetDouble("lineSpacingPt"));
        Assert.True(s.GetBool("filterMatureExplicit"));
        Assert.Equal("dracula", s.GetString("themePad"));
        Assert.Equal(18, s.GetDouble("fontSizePtMac"));
        Assert.Null(s.GetString("mode"));

        Assert.Equal(["Faves", "To Reread"], b.Folders!.Select(f => f.Name));
        var stat = Assert.Single(b.Stats!);
        Assert.Equal(2400.5, stat.DaySeconds["2026-06-02"]);
        Assert.Equal(0.66, stat.MaxProgress);
        Assert.False(stat.WorkIsComplete);
        Assert.Equal(Utc(2026, 6, 2, 21, 4, 6), b.Timestamp);
    }

    [Fact]
    public void DecodesOlderBackupsWithoutTheOptionalFields()
    {
        var b = LibraryBackupJson.Decode(OlderSwiftFixture);
        var w = Assert.Single(b.Works);
        Assert.Null(w.IsStarred);
        Assert.Null(w.IsPinned);
        Assert.Null(w.FolderNames);
        Assert.Equal("Old", w.FolderName);
        Assert.Null(Assert.Single(w.Chapters).AoId);
        Assert.Null(b.Settings);
        Assert.Null(b.Folders);
        Assert.Null(b.Stats);
        Assert.Null(w.Note);
        Assert.Null(w.PersonalTags);
    }

    [Fact]
    public void NoteAndPersonalTagsRoundTripInSwiftsKeys()
    {
        // The Swift app writes them as "note" and "personalTags" on a work.
        var json = SwiftFixture.Replace("\"folderNames\":[\"Faves\",\"To Reread\"]",
            "\"folderNames\":[\"Faves\",\"To Reread\"],\"note\":\"Comfort read\",\"personalTags\":[\"for a bad day\"],\"notesUpdatedAt\":\"2026-05-04T03:02:01Z\"");
        Assert.NotEqual(SwiftFixture, json);
        var w = Assert.Single(LibraryBackupJson.Decode(json).Works);
        Assert.Equal("Comfort read", w.Note);
        Assert.Equal(["for a bad day"], w.PersonalTags!);
        Assert.Equal(Utc(2026, 5, 4, 3, 2, 1), w.NotesUpdatedAt);

        var again = Assert.Single(LibraryBackupJson.Decode(LibraryBackupJson.Encode(LibraryBackupJson.Decode(json))).Works);
        Assert.Equal("Comfort read", again.Note);
        Assert.Equal(["for a bad day"], again.PersonalTags!);
        Assert.Equal(Utc(2026, 5, 4, 3, 2, 1), again.NotesUpdatedAt);
    }

    [Fact]
    public void CarriesWindowsReaderSettings()
    {
        // Windows' own per-device reader settings (reader.<name>.windows) ride
        // along like the phone, pad and Mac ones; Swift ignores the extra keys.
        var store = new InMemoryKeyValueStore();
        store.SetString("reader.fontSizePt.windows", "19");
        store.SetString("reader.mode.windows", "pageByPage");
        store.SetString("reader.activeProfile.windows", "Night");
        var captured = SettingsBackup.Capture(store);
        Assert.Equal(19, captured.GetDouble("fontSizePtWindows"));
        Assert.Equal("pageByPage", captured.GetString("modeWindows"));
        Assert.Equal("Night", captured.GetString("activeProfileWindows"));

        var json = SwiftFixture.Replace("\"fontSizePtMac\":18", "\"fontSizePtMac\":18,\"fontSizePtWindows\":19,\"activeProfileWindows\":\"Night\"");
        var decoded = LibraryBackupJson.Decode(json).Settings!;
        Assert.Equal(19, decoded.GetDouble("fontSizePtWindows"));
        Assert.Equal("Night", decoded.GetString("activeProfileWindows"));
    }

    [Fact]
    public void ReencodingSwiftOutputGivesTheSameJson()
    {
        // Our encoding of a decoded Swift backup is the same JSON document
        // (key order and string escaping aside), so the Swift app reads it back.
        var ours = LibraryBackupJson.Encode(LibraryBackupJson.Decode(SwiftFixture));
        using var expected = JsonDocument.Parse(SwiftFixture);
        using var actual = JsonDocument.Parse(ours);
        AssertJsonEqual(expected.RootElement, actual.RootElement, "$");

        using var older = JsonDocument.Parse(OlderSwiftFixture);
        using var olderOurs = JsonDocument.Parse(LibraryBackupJson.Encode(LibraryBackupJson.Decode(OlderSwiftFixture)));
        AssertJsonEqual(older.RootElement, olderOurs.RootElement, "$");
    }

    [Fact]
    public void EncodesDatesAsSwiftIso8601AndOmitsNils()
    {
        var backup = new LibraryBackup(
            Works:
            [
                new WorkBackup(
                    1, "T", "A", "", "", "Not Rated", [], [], [], [], [], [], "en", 0, 1, null, 0, 0, 0, 0, false,
                    null, null, new DateTimeOffset(2026, 6, 1, 14, 30, 15, 789, TimeSpan.FromHours(2)),
                    null, null, null, false, null, null, null, null, [new ChapterBackup(1, "Ch", "<p>a/b</p>", null)], null, null),
            ],
            Bookmarks: [], Subscriptions: [], Searches: [], Progress: [], Filters: [], Hidden: [],
            Settings: null, Folders: null, Stats: null,
            Timestamp: new DateTimeOffset(2026, 6, 1, 12, 0, 0, TimeSpan.Zero));
        var json = Encoding.UTF8.GetString(LibraryBackupJson.Encode(backup));

        // Local time converted to UTC, fractional seconds dropped (Swift's
        // .iso8601 decoder rejects fractions).
        Assert.Contains("\"savedAt\":\"2026-06-01T12:30:15Z\"", json);
        Assert.Contains("\"timestamp\":\"2026-06-01T12:00:00Z\"", json);
        // nil optionals are omitted, never written as null.
        Assert.DoesNotContain("null", json);
        Assert.DoesNotContain("totalChapters", json);
        Assert.DoesNotContain("aoId", json);
        Assert.DoesNotContain("isStarred", json);
        Assert.DoesNotContain("settings", json);
        Assert.DoesNotContain("stats", json);
        // Bodies survive intact.
        Assert.Equal("<p>a/b</p>", LibraryBackupJson.Decode(json).Works[0].Chapters[0].BodyHtml);
    }

    [Fact]
    public void WholeNumberDoublesHaveNoFraction()
    {
        var stat = new StatBackup(1, "", "", [], [], [], "", 0, Utc(2026, 1, 1), Utc(2026, 1, 1), 600,
                                  new Dictionary<string, double> { ["2026-01-01"] = 600 }, 1.0, true);
        var backup = new LibraryBackup([], [], [], [], [], [], [], null, null, [stat], Utc(2026, 1, 1));
        var json = Encoding.UTF8.GetString(LibraryBackupJson.Encode(backup));
        Assert.Contains("\"totalSeconds\":600,", json);
        Assert.Contains("{\"2026-01-01\":600}", json);
        Assert.Contains("\"maxProgress\":1,", json);
    }

    [Fact]
    public void MissingRequiredFieldFailsLikeSwift()
    {
        // Swift's decoder rejects the whole backup when a required key is
        // missing; restore then reports failure rather than half-applying it.
        Assert.ThrowsAny<JsonException>(() => LibraryBackupJson.Decode(OlderSwiftFixture.Replace(",\"timestamp\":\"2025-01-01T00:00:00Z\"", "")));
        Assert.ThrowsAny<JsonException>(() => LibraryBackupJson.Decode(OlderSwiftFixture.Replace("\"isFollowed\":false,", "")));
        Assert.ThrowsAny<JsonException>(() => LibraryBackupJson.Decode(OlderSwiftFixture.Replace("2025-01-01T00:00:00Z\"}", "yesterday\"}")));
    }

    [Fact]
    public void ParsesOtherIso8601Offsets()
    {
        Assert.Equal(Utc(2026, 6, 1, 10), LibraryBackupJson.ParseDate("2026-06-01T12:00:00+02:00"));
        Assert.Equal(Utc(2026, 6, 1, 10), LibraryBackupJson.ParseDate("2026-06-01T12:00:00+0200"));
        Assert.Equal(Utc(2026, 6, 1, 12), LibraryBackupJson.ParseDate("2026-06-01T12:00:00.250Z").AddMilliseconds(-250));
    }

    /// <summary>A whole library through backup and restore into an empty store
    /// comes back record for record.</summary>
    [Fact]
    public async Task FullLibraryRoundTripsThroughTheBackupFile()
    {
        var path = Path.Combine(Path.GetTempPath(), $"roundtrip_{Guid.NewGuid()}.json");
        try
        {
            File.WriteAllText(path, SwiftFixture);
            using var store = LibraryStore.OpenInMemory();
            var settings = new InMemoryKeyValueStore();
            var sync = new LibrarySyncManager(settings) { BackupPathOverride = path };
            Assert.True(await sync.RestoreAsync(store));

            var work = Assert.Single(store.All<Work>());
            Assert.Equal(["Faves", "To Reread"], work.Folders.Select(f => f.Name).Order());
            Assert.Equal(2, work.Chapters.Count);
            Assert.True(work.IsStarred);
            Assert.Equal(0.66, work.LastReadProgress);
            Assert.Equal(42, store.GetReadingProgress(12345)?.ParagraphIndex);
            Assert.Equal(5, store.GetSubscription("work:1")?.LastSeenChapterCount);
            Assert.NotNull(store.GetHiddenWork(666));
            Assert.Equal("sepia", settings.GetString("reader.theme"));
            Assert.Equal(22, settings.GetDouble("reader.fontSizePt"));
            Assert.Equal("dracula", settings.GetString("reader.theme.pad"));
            Assert.Equal(18, settings.GetDouble("reader.fontSizePt.mac"));
            // No profile merger installed and nothing local: the incoming profiles are kept.
            Assert.Equal("[{\"name\":\"Default\"}]", settings.GetString("reader.profiles"));
            Assert.False(sync.CloudBackupHasUnappliedChanges);

            // Backing up merges onto the same file and keeps every record.
            sync.Backup(store);
            var again = LibraryBackupJson.Decode(File.ReadAllBytes(path));
            Assert.Equal([12345], again.Works.Select(w => w.Ao3Id));
            Assert.Equal(["Faves", "To Reread"], again.Works[0].FolderNames!.Order());
            Assert.Equal([900, null], again.Works[0].Chapters.Select(c => c.AoId));
            Assert.Equal(2, again.Folders!.Count);
            // The merge lifts the total to Σ DaySeconds (1200 + 2400.5).
            Assert.Equal(3600.5, again.Stats![0].TotalSeconds);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void BackupSkipsWhenOnlyAPlaceholderExists()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"placeholder_{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            File.WriteAllText(Path.Combine(dir, ".library_backup.json.icloud"), "");
            using var store = LibraryStore.OpenInMemory();
            store.Insert(new Work(1, "T", "A"));
            store.Save();
            var sync = new LibrarySyncManager(new InMemoryKeyValueStore()) { SyncFolder = dir };
            Assert.True(sync.IsBackupAvailable);
            sync.Backup(store);
            // Not overwritten into existence: the other device's backup is still downloading.
            Assert.False(File.Exists(Path.Combine(dir, LibrarySyncManager.BackupFileName)));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void UnappliedChangesTracksTheFileDate()
    {
        var path = Path.Combine(Path.GetTempPath(), $"stamp_{Guid.NewGuid()}.json");
        try
        {
            var settings = new InMemoryKeyValueStore();
            var sync = new LibrarySyncManager(settings) { BackupPathOverride = path };
            Assert.True(sync.CloudBackupHasUnappliedChanges); // can't tell → restore

            using var store = LibraryStore.OpenInMemory();
            sync.Backup(store);
            Assert.False(sync.CloudBackupHasUnappliedChanges); // our own write is applied

            File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(5)); // another device wrote it
            Assert.True(sync.CloudBackupHasUnappliedChanges);
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static void AssertJsonEqual(JsonElement expected, JsonElement actual, string path)
    {
        Assert.True(expected.ValueKind == actual.ValueKind, $"{path}: {expected.ValueKind} vs {actual.ValueKind}");
        switch (expected.ValueKind)
        {
            case JsonValueKind.Object:
                var e = expected.EnumerateObject().ToDictionary(p => p.Name, p => p.Value);
                var a = actual.EnumerateObject().ToDictionary(p => p.Name, p => p.Value);
                Assert.True(e.Keys.ToHashSet().SetEquals(a.Keys),
                    $"{path}: keys differ — expected [{string.Join(",", e.Keys.Order())}], got [{string.Join(",", a.Keys.Order())}]");
                foreach (var (k, v) in e) AssertJsonEqual(v, a[k], $"{path}.{k}");
                break;
            case JsonValueKind.Array:
                Assert.Equal(expected.GetArrayLength(), actual.GetArrayLength());
                var i = 0;
                foreach (var (x, y) in expected.EnumerateArray().Zip(actual.EnumerateArray())) AssertJsonEqual(x, y, $"{path}[{i++}]");
                break;
            case JsonValueKind.String:
                Assert.Equal(expected.GetString(), actual.GetString());
                break;
            case JsonValueKind.Number:
                Assert.Equal(expected.GetDouble(), actual.GetDouble());
                Assert.Equal(expected.GetRawText(), actual.GetRawText()); // 600 stays 600, 0.66 stays 0.66
                break;
        }
    }
}
