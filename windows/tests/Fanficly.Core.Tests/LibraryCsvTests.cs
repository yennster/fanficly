using System.Text;
using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>#417 (Swift: <c>LibraryExportTests</c>): Export All My Data. The
/// library as a CSV spreadsheet with the Apple app's columns, and every
/// downloaded story as its own EPUB, made offline.</summary>
public sealed class LibraryCsvTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"fanficly_export_{Guid.NewGuid()}");

    public LibraryCsvTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    // CSV

    /// <summary>The Apple app's <c>LibraryExportTests.testColumnsAreTheSharedList</c>
    /// pins the same list: change both together.</summary>
    [Fact]
    public void ColumnsMatchTheAppleApp()
    {
        Assert.Equal(
        [
            "ao3_url", "work_id", "title", "author", "author_url", "fandoms", "relationships",
            "characters", "additional_tags", "rating", "warnings", "categories", "language",
            "words", "chapters", "complete", "published", "updated", "kudos", "hits",
            "bookmarks", "comments", "summary", "saved_at", "last_read_at", "last_read_chapter",
            "progress_percent", "starred", "pinned", "following", "folders", "personal_tags",
            "note", "downloaded",
        ], LibraryCsv.Columns);
        Assert.Subset(LibraryCsv.Columns.ToHashSet(), LibraryCsv.TextColumns.ToHashSet());
    }

    [Fact]
    public void EscapingFollowsRfc4180()
    {
        Assert.Equal("plain", LibraryCsv.Escape("plain"));
        Assert.Equal("\"a, b\"", LibraryCsv.Escape("a, b"));
        Assert.Equal("\"say \"\"hi\"\"\"", LibraryCsv.Escape("say \"hi\""));
        Assert.Equal("\"one\ntwo\"", LibraryCsv.Escape("one\ntwo"));
        Assert.Equal("\"one\r\ntwo\"", LibraryCsv.Escape("one\r\ntwo"));
        Assert.Equal("🦊 狐狸の嫁入り", LibraryCsv.Escape("🦊 狐狸の嫁入り"));
        Assert.Equal("", LibraryCsv.Escape(""));
    }

    [Fact]
    public void FileHasABomHeaderAndCrlfLines()
    {
        var data = LibraryCsv.Data([Enumerable.Repeat("x", LibraryCsv.Columns.Count).ToList()]);
        Assert.Equal(new byte[] { 0xEF, 0xBB, 0xBF }, data[..3]);
        var text = Encoding.UTF8.GetString(data[3..]);
        Assert.StartsWith("ao3_url,work_id,title,", text);
        Assert.EndsWith(",x\r\n", text);
        Assert.Equal(3, text.Split("\r\n").Length);  // header, row, ""
    }

    [Fact]
    public void RoundTripThroughACsvParserGivesBackTheSameValues()
    {
        string[] tricky =
        [
            "Commas, everywhere, really",
            "\"Quoted\" and \"\"doubled\"\"",
            "Line one\nLine two\r\nLine three",
            "Emoji 🦊🏳️‍🌈 and Ελληνικά, Русский, 日本語, العربية",
            "",
            "trailing space ",
        ];
        var rows = new List<IReadOnlyList<string>>();
        for (var i = 0; i < tricky.Length; i++)
        {
            var row = Enumerable.Repeat("", LibraryCsv.Columns.Count).ToArray();
            row[0] = $"https://archiveofourown.org/works/{i}";
            row[2] = tricky[i];   // title
            row[22] = tricky[i];  // summary
            row[32] = tricky[i];  // note
            rows.Add(row);
        }
        var parsed = ParseCsv(Encoding.UTF8.GetString(LibraryCsv.Data(rows)[3..]));
        Assert.Equal(LibraryCsv.Columns, parsed[0]);
        Assert.Equal(rows.Count, parsed.Count - 1);
        for (var i = 0; i < rows.Count; i++) Assert.Equal(rows[i], parsed[i + 1]);
    }

    [Fact]
    public void FormulaLikeTextIsKeptAsText()
    {
        Assert.Equal("'=HYPERLINK(\"http://x\")", LibraryCsv.Guarded("=HYPERLINK(\"http://x\")"));
        Assert.Equal("'+1", LibraryCsv.Guarded("+1"));
        Assert.Equal("'-dash", LibraryCsv.Guarded("-dash"));
        Assert.Equal("'@me", LibraryCsv.Guarded("@me"));
        Assert.Equal("Normal", LibraryCsv.Guarded("Normal"));
        var row = Enumerable.Repeat("", LibraryCsv.Columns.Count).ToArray();
        row[2] = "=1+1";  // title: guarded
        row[13] = "-5";   // words: a number column, left alone
        var parsed = ParseCsv(LibraryCsv.Text([row]));
        Assert.Equal("'=1+1", parsed[1][2]);
        Assert.Equal("-5", parsed[1][13]);
    }

    [Fact]
    public void RowForAWork()
    {
        using var store = LibraryStore.Open(Path.Combine(_dir, "library.sqlite"));
        var work = new Work(4242, "The Long Way, Home", "Quill (quill_writer)",
            summary: "<p>Two friends &amp; a car.<br/>Road trip!</p><p>  Second   para. </p>",
            rating: "Teen And Up Audiences", warnings: ["No Archive Warnings Apply"],
            categories: ["F/M", "Gen"], fandoms: ["Teen Wolf", "Supernatural"],
            characters: ["Stiles"], relationships: ["Derek/Stiles"],
            freeforms: ["Fluff", "Road Trip"], language: "English", wordCount: 12345,
            chapterCount: 12, totalChapters: null, kudos: 10, hits: 200,
            bookmarksCount: 3, commentsCount: 4, isComplete: false,
            publishedAt: DateTimeOffset.FromUnixTimeSeconds(1_700_000_000),
            updatedAt: null, savedAt: DateTimeOffset.FromUnixTimeSeconds(1_750_000_000))
        {
            AuthorUsername = "quill_writer",
            LastReadAt = DateTimeOffset.FromUnixTimeSeconds(1_760_000_000),
            LastReadChapter = 3,
            LastReadProgress = 0.256,
            IsStarred = true,
            IsFollowed = true,
            Note = "for a bad day",
            PersonalTags = ["comfort", "reread"],
        };
        store.Insert(work);
        var zed = new CustomFolder("Zed");
        var alpha = new CustomFolder("Alpha");
        store.Insert(zed);
        store.Insert(alpha);
        work.Folders.Add(zed);
        work.Folders.Add(alpha);
        store.Insert(new Chapter(work, 1, "One", "<p>Hi</p>"));
        store.Save();

        var row = LibraryCsv.Row(work);
        string Cell(string name) => row[LibraryCsv.Columns.ToList().IndexOf(name)];
        Assert.Equal(LibraryCsv.Columns.Count, row.Count);
        Assert.Equal("https://archiveofourown.org/works/4242", Cell("ao3_url"));
        Assert.Equal("4242", Cell("work_id"));
        Assert.Equal("The Long Way, Home", Cell("title"));
        Assert.Equal("https://archiveofourown.org/users/quill_writer", Cell("author_url"));
        Assert.Equal("Teen Wolf; Supernatural", Cell("fandoms"));
        Assert.Equal("Fluff; Road Trip", Cell("additional_tags"));
        Assert.Equal("F/M; Gen", Cell("categories"));
        Assert.Equal("12345", Cell("words"));
        Assert.Equal("12/?", Cell("chapters"));
        Assert.Equal("no", Cell("complete"));
        Assert.Equal("2023-11-14T22:13:20Z", Cell("published"));
        Assert.Equal("", Cell("updated"));
        Assert.Equal("2025-06-15T15:06:40Z", Cell("saved_at"));
        Assert.Equal("Two friends & a car.\nRoad trip!\nSecond para.", Cell("summary"));
        Assert.Equal("3", Cell("last_read_chapter"));
        Assert.Equal("26", Cell("progress_percent"));
        Assert.Equal("yes", Cell("starred"));
        Assert.Equal("no", Cell("pinned"));
        Assert.Equal("yes", Cell("following"));
        Assert.Equal("Alpha; Zed", Cell("folders"));
        Assert.Equal("comfort; reread", Cell("personal_tags"));
        Assert.Equal("for a bad day", Cell("note"));
        Assert.Equal("yes", Cell("downloaded"));

        work.TotalChapters = 20;
        work.IsComplete = true;
        work.LastReadProgress = null;
        Assert.Equal("12/20", LibraryCsv.Row(work)[14]);
        Assert.Equal("yes", LibraryCsv.Row(work)[15]);
        Assert.Equal("", LibraryCsv.Row(work)[26]);
    }

    [Fact]
    public void ImportedBooksHaveNoAo3Link()
    {
        var work = new Work(-77, "My Own Book", "Me") { AuthorUsername = "me" };
        var row = LibraryCsv.Row(work);
        Assert.Equal("", row[0]);
        Assert.Equal("", row[1]);
        Assert.Equal("", row[4]);
        Assert.Equal("My Own Book", row[2]);
        Assert.Equal("no", row[33]);
    }

    [Fact]
    public void RowsListEveryWorkOldestSavedFirstAndSkipPendingDeletes()
    {
        using var store = LibraryStore.Open(Path.Combine(_dir, "library.sqlite"));
        store.Insert(new Work(2, "Second", "B", savedAt: DateTimeOffset.FromUnixTimeSeconds(2)));
        store.Insert(new Work(1, "First", "A", savedAt: DateTimeOffset.FromUnixTimeSeconds(1)));
        store.Insert(new Work(3, "Deleting", "C", savedAt: DateTimeOffset.FromUnixTimeSeconds(3)));
        store.Save();
        var rows = LibraryCsv.Rows(store, id => id == 3);
        Assert.Equal(["First", "Second"], rows.Select(r => r[2]));
        Assert.Equal("Fanficly Library 2026-11-18.csv",
            LibraryCsv.FileName(new DateTimeOffset(2026, 11, 18, 23, 30, 0, TimeSpan.FromHours(-5))));
    }

    // Every downloaded EPUB

    [Fact]
    public void FileNamesAddTheWorkIdOnlyWhenNamesCollide()
    {
        var names = BulkEpubExport.FileNames([(1, "Stay"), (2, "stay"), (3, "Gone: Again?"), (4, ""), (5, "Unique")]);
        Assert.Equal("Stay (1)", names[1]);
        Assert.Equal("stay (2)", names[2]);
        Assert.Equal("Gone- Again-", names[3]);
        Assert.Equal("work-4", names[4]);
        Assert.Equal("Unique", names[5]);
    }

    [Fact]
    public async Task ExportsOneValidEpubPerDownloadedWorkWithoutAo3()
    {
        using var store = LibraryStore.Open(Path.Combine(_dir, "library.sqlite"));
        var epubs = Path.Combine(_dir, "epubs");
        var output = Path.Combine(_dir, "out");
        Directory.CreateDirectory(epubs);

        // Text only: built from the text.
        var textOnly = new Work(917_001, "Same Name", "A");
        store.Insert(textOnly);
        store.Insert(new Chapter(textOnly, 1, "One", "<p>Text-only words.</p>"));
        // A saved AO3 EPUB as well as text: the saved file is used.
        var saved = new Work(917_002, "Same Name", "B");
        store.Insert(saved);
        store.Insert(new Chapter(saved, 1, "One", "<p>Old text.</p>"));
        File.WriteAllBytes(Path.Combine(epubs, "917002.epub"), EpubBuilder.Build(new EpubBuilder.Book(
            917_002, "Same Name", "B", "", "en", [new("One", "<p>From the saved file.</p>")])));
        // Not downloaded: left out.
        store.Insert(new Work(917_003, "Bookmark Only", "C"));
        store.Save();

        var plan = BulkEpubExport.MakePlan(store, epubFolder: epubs);
        Assert.Equal(new HashSet<int> { 917_001, 917_002 }, plan.WorkIds.ToHashSet());
        Assert.True(plan.EstimatedBytes > 0);

        // No client is involved at all: the export never reaches AO3.
        var reported = new List<int>();
        var paths = await BulkEpubExport.ExportAsync(plan, store, output, new SyncProgress(reported), epubFolder: epubs);
        Assert.Equal(new HashSet<string> { "Same Name (917001).epub", "Same Name (917002).epub" },
            paths.Select(p => Path.GetFileName(p)).ToHashSet());
        Assert.Equal([1, 2], reported);
        foreach (var path in paths)
        {
            var payload = EpubImport.Parse(File.ReadAllBytes(path));
            if (path.Contains("917001"))
            {
                Assert.Equal(917_001, payload.Summary.Id);
                Assert.Contains("Text-only words.", payload.Chapters[0].BodyHtml);
            }
            else
            {
                Assert.Equal(917_002, payload.Summary.Id);
                Assert.Contains("From the saved file.", payload.Chapters[0].BodyHtml);
            }
        }
    }

    [Fact]
    public async Task CancellingStopsBetweenFiles()
    {
        using var store = LibraryStore.Open(Path.Combine(_dir, "library.sqlite"));
        var work = new Work(917_020, "Cancelled", "A");
        store.Insert(work);
        store.Insert(new Chapter(work, 1, "One", "<p>Words.</p>"));
        store.Save();
        var plan = BulkEpubExport.MakePlan(store, epubFolder: Path.Combine(_dir, "none"));
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            BulkEpubExport.ExportAsync(plan, store, Path.Combine(_dir, "out"), ct: cts.Token, epubFolder: Path.Combine(_dir, "none")));
        Assert.Empty(Directory.GetFiles(Path.Combine(_dir, "out")));
    }

    /// <summary>Reports straight away, unlike <see cref="Progress{T}"/>, which posts.</summary>
    private sealed class SyncProgress(List<int> values) : IProgress<int>
    {
        public void Report(int value) => values.Add(value);
    }

    // A small RFC 4180 reader, for the round trips

    internal static List<List<string>> ParseCsv(string text)
    {
        var rows = new List<List<string>>();
        var row = new List<string>();
        var field = new StringBuilder();
        var inQuotes = false;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (inQuotes)
            {
                if (c == '"')
                {
                    if (i + 1 < text.Length && text[i + 1] == '"') { field.Append('"'); i++; }
                    else inQuotes = false;
                }
                else field.Append(c);
            }
            else if (c == '"') inQuotes = true;
            else if (c == ',') { row.Add(field.ToString()); field.Clear(); }
            else if (c == '\r' || c == '\n')
            {
                if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                row.Add(field.ToString()); field.Clear();
                rows.Add(row); row = [];
            }
            else field.Append(c);
        }
        if (field.Length > 0 || row.Count > 0) { row.Add(field.ToString()); rows.Add(row); }
        return rows;
    }
}
