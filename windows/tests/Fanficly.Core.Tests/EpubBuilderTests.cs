using System.Text;
using System.Xml;
using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>#173 (Swift: <c>EPUBBuilderTests</c>): Export → EPUB works offline
/// for a story saved on this PC, from AO3's saved file or, without one, an
/// EPUB built from the saved text; Downloaded means saved text; Settings →
/// Storage removes the saved EPUBs and keeps everything else.</summary>
public sealed class EpubBuilderTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"fanficly_epubbuild_{Guid.NewGuid()}");

    public EpubBuilderTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    private static readonly EpubBuilder.Book Book = new(
        12345, "The Long Way <Home> & Back", "Quill Writer", "<p>Two friends drive home.</p>", "English",
        [
            new("Chapter 1: Hello", "<p>It was a dark &amp; stormy night.<br>Rain fell.</p><script>alert(1)</script><img src=\"https://example.com/a.png\">"),
            new("", "<p>They reached Ohio.</p>"),
        ]);

    [Fact]
    public void BuiltBookImportsBackWithTheSameStory()
    {
        var payload = EpubImport.Parse(EpubBuilder.Build(Book));

        Assert.Equal(12345, payload.Summary.Id);
        Assert.Equal("The Long Way <Home> & Back", payload.Summary.Title);
        Assert.Equal("Quill Writer", payload.Summary.Author);
        // The title page isn't in the contents, so it isn't a chapter.
        Assert.Equal(["Chapter 1: Hello", "Chapter 2"], payload.Chapters.Select(c => c.Title));
        Assert.Contains("stormy night.", payload.Chapters[0].BodyHtml);
        Assert.Contains("Rain fell.", payload.Chapters[0].BodyHtml);
        Assert.DoesNotContain("alert(1)", payload.Chapters[0].BodyHtml);
        Assert.DoesNotContain("<img", payload.Chapters[0].BodyHtml);
        Assert.Contains("They reached Ohio.", payload.Chapters[1].BodyHtml);
    }

    [Fact]
    public void ZipStartsWithAStoredMimetype()
    {
        var data = EpubBuilder.Build(Book);
        Assert.Equal(new byte[] { 0x50, 0x4b, 0x03, 0x04 }, data[..4]);
        Assert.Equal(0, data[8]);
        Assert.Equal("mimetype", Encoding.UTF8.GetString(data, 30, 8));
        Assert.Equal("application/epub+zip", Encoding.UTF8.GetString(data, 38, 20));
        // .NET's own reader agrees on every entry.
        using var zip = new System.IO.Compression.ZipArchive(new MemoryStream(data));
        Assert.Equal("mimetype", zip.Entries[0].FullName);
        Assert.Contains(zip.Entries, e => e.FullName == "OEBPS/chapter-2.xhtml");
        foreach (var entry in zip.Entries.Where(e => e.FullName.EndsWith(".xhtml") || e.FullName.EndsWith(".opf") || e.FullName.EndsWith(".ncx")))
        {
            using var stream = entry.Open();
            var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore };
            using var reader = XmlReader.Create(stream, settings);
            while (reader.Read()) { }  // throws if the XML isn't well-formed
        }
    }

    [Fact]
    public void ChapterHtmlBecomesWellFormedXhtml()
    {
        var body = EpubBuilder.XhtmlBody("<p bad\"name=1 class=x>One<br>two &amp; <i>three</p><hr>&nbsp;");
        Assert.Contains("<br", body);
        Assert.DoesNotContain("bad", body);
        var doc = new XmlDocument();
        doc.LoadXml($"<body>{body}</body>");
    }

    [Fact]
    public void EscapesAndLanguageTags()
    {
        Assert.Equal("a&lt;b&gt;&amp;&quot;c&#39;", EpubBuilder.Escape("a<b>&\"c'\u0001"));
        Assert.Equal("en", EpubBuilder.LanguageTag("English"));
        Assert.Equal("pt-BR", EpubBuilder.LanguageTag("pt-BR"));
        Assert.Equal("https://archiveofourown.org/works/12345", EpubBuilder.Identifier(Book));
        Assert.Equal("urn:fanficly:-7", EpubBuilder.Identifier(Book with { WorkId = -7 }));
        Assert.Equal("a-b", EpubBuilder.FileName("a/b", 1));
        Assert.Equal("work-5", EpubBuilder.FileName("  ", 5));
    }

    [Fact]
    public void Crc32MatchesTheStandardCheckValue() =>
        Assert.Equal(0xCBF43926u, Crc32.Checksum(Encoding.ASCII.GetBytes("123456789")));

    [Fact]
    public void OfflineExportBuildsFromSavedTextAndSkipsUnsavedWorks()
    {
        using var store = LibraryStore.Open(Path.Combine(_dir, "library.sqlite"));
        const int id = 987_650_173;
        var work = new Work(id, "Offline Fic", "Writer");
        store.Insert(work);
        store.Insert(new Chapter(work, 1, "One", "<p>Saved words.</p>"));
        var bookmarked = new Work(987_650_174, "Bookmarked", "Writer");
        store.Insert(bookmarked);
        store.Save();

        Assert.True(WorkPersistence.IsDownloaded(work));
        Assert.True(WorkPersistence.IsDownloaded(id, store));
        Assert.False(WorkPersistence.IsDownloaded(bookmarked));
        Assert.Equal([987_650_174], RestoreDownloadCenter.FolderDownloadCandidates([work, bookmarked]));

        var exports = Path.Combine(_dir, "exports");
        var path = EpubBuilder.OfflineExport(id, "Offline Fic", store, exports);
        Assert.Equal(Path.Combine(exports, "Offline Fic.epub"), path);
        var payload = EpubImport.Parse(File.ReadAllBytes(path!));
        Assert.Contains("Saved words.", payload.Chapters[0].BodyHtml);

        // Not saved here: Export downloads from AO3 instead.
        Assert.Null(EpubBuilder.OfflineExport(987_650_174, "Bookmarked", store, exports));
        Assert.Null(EpubBuilder.OfflineExport(987_650_175, "Unknown", store, exports));
    }

    [Fact]
    public void RemovingSavedEpubsKeepsOtherFiles()
    {
        var folder = Path.Combine(_dir, "library");
        Directory.CreateDirectory(folder);
        File.WriteAllBytes(Path.Combine(folder, "1.epub"), new byte[100]);
        File.WriteAllBytes(Path.Combine(folder, "2.EPUB"), new byte[50]);
        File.WriteAllBytes(Path.Combine(folder, "notes.txt"), new byte[10]);

        Assert.Equal(new EpubStorage(2, 150), WorkPersistence.SavedEpubStorage(folder));
        Assert.Equal(2, WorkPersistence.RemoveAllSavedEpubs(folder));
        Assert.Equal(0, WorkPersistence.SavedEpubStorage(folder).Count);
        Assert.True(File.Exists(Path.Combine(folder, "notes.txt")));
        Assert.Equal(new EpubStorage(0, 0), WorkPersistence.SavedEpubStorage(Path.Combine(_dir, "missing")));
    }
}
