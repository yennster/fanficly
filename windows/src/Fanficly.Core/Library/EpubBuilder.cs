using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using AngleSharp;
using AngleSharp.Html.Parser;
using AngleSharp.Xhtml;

namespace Fanficly.Core;

/// <summary>Makes an EPUB from a saved work's chapter text, so Export → EPUB
/// works offline for every story saved on this PC, including ones whose AO3
/// EPUB was never fetched (a restore) or was removed in Settings → Storage
/// (#173). When AO3's own file is saved, Export shares that instead
/// (<see cref="OfflineExportAsync"/>). Swift: <c>EPUBBuilder</c>.
///
/// The book is EPUB 3 with an EPUB 2 table of contents (<c>toc.ncx</c>) for
/// older readers: a title page (title, author, AO3 link, summary), then one
/// XHTML file per chapter. The contents list only the chapters, so importing
/// the file back (<see cref="EpubImport"/>, which leaves out what comes before
/// the first entry) gives the same chapters. Images are left out, as the
/// reader leaves them out offline. The zip is written by hand with every entry
/// stored (no compression), which the EPUB spec allows and every reader
/// accepts; the <c>mimetype</c> entry must be first and stored anyway.</summary>
public static partial class EpubBuilder
{
    public sealed record Chapter(string Title, string Html);

    /// <param name="Summary">HTML, as AO3 shows it.</param>
    public sealed record Book(int WorkId, string Title, string Author, string Summary, string Language, IReadOnlyList<Chapter> Chapters);

    /// <summary>The book for a saved work, chapters in reading order.</summary>
    public static Book BookFrom(Work work) =>
        new(work.Ao3Id, work.Title, work.AuthorName, work.Summary, work.Language,
            work.Chapters.OrderBy(c => c.Index).Select(c => new Chapter(c.Title, c.BodyHtml)).ToList());

    /// <summary>An EPUB of a story saved on this PC, without AO3, written into
    /// <paramref name="exportsDirectory"/> under the story's title: a copy of
    /// the saved AO3 file, or one built from the saved text. Null when the
    /// story isn't saved (no text and no file), so Export downloads. The saved
    /// file is never older than the text: saving or restoring new text deletes
    /// it. The book is read on the caller's thread and built on the thread
    /// pool, since a long work takes a moment.</summary>
    public static async Task<string?> OfflineExportAsync(int workId, string title, LibraryStore store, string exportsDirectory)
    {
        var saved = WorkPersistence.EpubPath(workId);
        var work = store.GetWork(workId);
        if (saved is null && (work is null || !WorkPersistence.IsDownloaded(work))) return null;
        Directory.CreateDirectory(exportsDirectory);
        var target = Path.Combine(exportsDirectory, $"{FileName(title, workId)}.epub");
        if (saved is not null)
        {
            try
            {
                File.Copy(saved, target, overwrite: true);
                return target;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // A file that can't be read: build one from the text instead.
                if (work is null || !WorkPersistence.IsDownloaded(work)) return null;
            }
        }
        var book = BookFrom(work!);
        var bytes = await Task.Run(() => Build(book));
        await File.WriteAllBytesAsync(target, bytes);
        return target;
    }

    /// <summary>A file name for the story (Swift: <c>AO3Client.sanitizeFilename</c>).</summary>
    public static string FileName(string title, int workId)
    {
        var invalid = Path.GetInvalidFileNameChars().Concat("/\\?%*|\"<>:").ToHashSet();
        var cleaned = new string(title.Select(c => invalid.Contains(c) ? '-' : c).ToArray());
        cleaned = (cleaned.Length > 80 ? cleaned[..80] : cleaned).Trim();
        return cleaned.Length == 0 ? $"work-{workId}" : cleaned;
    }

    /// <summary>The EPUB file's bytes.</summary>
    public static byte[] Build(Book book)
    {
        var zip = new StoredZip();
        zip.Add("mimetype", "application/epub+zip");
        zip.Add("META-INF/container.xml", ContainerXml);
        zip.Add("OEBPS/content.opf", PackageDocument(book));
        zip.Add("OEBPS/nav.xhtml", NavDocument(book));
        zip.Add("OEBPS/toc.ncx", Ncx(book));
        zip.Add("OEBPS/style.css", Stylesheet);
        zip.Add("OEBPS/title.xhtml", TitlePage(book));
        for (var i = 0; i < book.Chapters.Count; i++)
            zip.Add($"OEBPS/{ChapterFile(i)}", ChapterPage(book.Chapters[i], i + 1, book));
        return zip.Finish();
    }

    // MARK: - Documents

    private const string ContainerXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """;

    private const string Stylesheet = """
        body { font-family: serif; line-height: 1.5; margin: 0 5%; }
        h1, h2 { text-align: center; }
        p.byline { text-align: center; font-style: italic; }
        p.source { text-align: center; font-size: 0.9em; }
        blockquote { margin: 1em 1.5em; }
        """;

    public static string ChapterFile(int index) => $"chapter-{index + 1}.xhtml";

    public static string ChapterTitle(Chapter chapter, int number)
    {
        var title = chapter.Title.Trim();
        return title.Length == 0 ? $"Chapter {number}" : title;
    }

    /// <summary>The book's identifier: the AO3 work URL, or a stable URN for an
    /// imported book that isn't on AO3.</summary>
    public static string Identifier(Book book) =>
        EpubImport.IsLocalWork(book.WorkId)
            ? $"urn:fanficly:{book.WorkId}"
            : $"https://archiveofourown.org/works/{book.WorkId}";

    /// <summary>A BCP 47 tag for <c>dc:language</c>. AO3 gives a language name
    /// ("English"), which isn't one, so anything that doesn't look like a tag is "en".</summary>
    public static string LanguageTag(string language)
    {
        var trimmed = language.Trim();
        return LanguageTagPattern().IsMatch(trimmed) ? trimmed : "en";
    }

    [GeneratedRegex("^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$")]
    private static partial Regex LanguageTagPattern();

    [GeneratedRegex("[\u0000-\u0008\u000B\u000C\u000E-\u001F]")]
    private static partial Regex ControlCharacters();

    [GeneratedRegex("^[A-Za-z_][A-Za-z0-9_.-]*$")]
    private static partial Regex XmlNamePattern();

    private static string PackageDocument(Book book)
    {
        var manifest = string.Join("\n", book.Chapters.Select((_, i) =>
            $"""    <item id="c{i + 1}" href="{ChapterFile(i)}" media-type="application/xhtml+xml"/>"""));
        var spine = string.Join("\n", book.Chapters.Select((_, i) => $"""    <itemref idref="c{i + 1}"/>"""));
        var lang = LanguageTag(book.Language);
        var modified = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        return $"""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="{lang}">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">{Escape(Identifier(book))}</dc:identifier>
                <dc:title>{Escape(book.Title)}</dc:title>
                <dc:creator>{Escape(book.Author)}</dc:creator>
                <dc:language>{lang}</dc:language>
                <meta property="dcterms:modified">{modified}</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="css" href="style.css" media-type="text/css"/>
                <item id="title" href="title.xhtml" media-type="application/xhtml+xml"/>
            {manifest}
              </manifest>
              <spine toc="ncx">
                <itemref idref="title"/>
            {spine}
              </spine>
            </package>
            """;
    }

    private static string NavDocument(Book book)
    {
        var items = string.Join("\n", book.Chapters.Select((c, i) =>
            $"""      <li><a href="{ChapterFile(i)}">{Escape(ChapterTitle(c, i + 1))}</a></li>"""));
        return Xhtml("Contents", LanguageTag(book.Language), $"""
            <nav epub:type="toc" id="toc">
              <h1>Contents</h1>
              <ol>
            {items}
              </ol>
            </nav>
            """);
    }

    private static string Ncx(Book book)
    {
        var points = string.Join("\n", book.Chapters.Select((c, i) =>
            $"""    <navPoint id="np{i + 1}" playOrder="{i + 1}"><navLabel><text>{Escape(ChapterTitle(c, i + 1))}</text></navLabel><content src="{ChapterFile(i)}"/></navPoint>"""));
        return $"""
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <head>
                <meta name="dtb:uid" content="{Escape(Identifier(book))}"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="0"/>
                <meta name="dtb:maxPageNumber" content="0"/>
              </head>
              <docTitle><text>{Escape(book.Title)}</text></docTitle>
              <navMap>
            {points}
              </navMap>
            </ncx>
            """;
    }

    private static string TitlePage(Book book)
    {
        var body = new StringBuilder($"<h1>{Escape(book.Title)}</h1>\n");
        if (book.Author.Length > 0) body.Append($"<p class=\"byline\">by {Escape(book.Author)}</p>\n");
        if (!EpubImport.IsLocalWork(book.WorkId))
        {
            var link = Escape(Identifier(book));
            body.Append($"<p class=\"source\"><a href=\"{link}\">{link}</a></p>\n");
        }
        var summary = XhtmlBody(book.Summary);
        if (summary.Length > 0) body.Append($"<h2>Summary</h2>\n<blockquote>{summary}</blockquote>\n");
        return Xhtml(book.Title, LanguageTag(book.Language), body.ToString());
    }

    private static string ChapterPage(Chapter chapter, int number, Book book)
    {
        var title = ChapterTitle(chapter, number);
        return Xhtml(title, LanguageTag(book.Language), $"<h2>{Escape(title)}</h2>\n{XhtmlBody(chapter.Html)}");
    }

    private static string Xhtml(string title, string lang, string body) => $"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="{lang}" lang="{lang}">
        <head>
          <meta charset="UTF-8"/>
          <title>{Escape(title)}</title>
          <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        {body}
        </body>
        </html>
        """;

    private const string DroppedElements =
        "script, style, link, meta, iframe, object, embed, form, input, button, img, svg, video, audio, source";

    /// <summary>Saved chapter HTML as well-formed XHTML: AngleSharp re-serializes
    /// it as XHTML (closed void tags, escaped text). Scripts, styles, embeds and
    /// forms are dropped, and so are images, which would be remote resources.
    /// Attributes whose names aren't valid XML are dropped, prefixed elements give
    /// way to their contents and control characters go, so the file still parses.</summary>
    public static string XhtmlBody(string html)
    {
        if (string.IsNullOrWhiteSpace(html)) return "";
        var document = new HtmlParser().ParseDocument($"<!DOCTYPE html><html><body>{html}</body></html>");
        var body = document.Body;
        if (body is null) return $"<p>{Escape(Regex.Replace(html, "<[^>]+>", ""))}</p>";
        foreach (var element in body.QuerySelectorAll(DroppedElements).ToList()) element.Remove();
        // Word's <o:p> and the like: a prefix with no namespace isn't XML.
        foreach (var element in body.QuerySelectorAll("*").Where(e => e.LocalName.Contains(':') || e.Prefix is not null).ToList())
            element.Replace([.. element.ChildNodes]);
        foreach (var element in body.QuerySelectorAll("*"))
            foreach (var attribute in element.Attributes.ToList())
                if (!XmlNamePattern().IsMatch(attribute.Name)) element.RemoveAttribute(attribute.Name);
        // Control characters other than tab and newlines aren't allowed in XML 1.0 at all.
        return ControlCharacters().Replace(string.Concat(body.ChildNodes.Select(n => n.ToHtml(XhtmlMarkupFormatter.Instance))), "");
    }

    public static string Escape(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (var c in text)
        {
            switch (c)
            {
                case '&': sb.Append("&amp;"); break;
                case '<': sb.Append("&lt;"); break;
                case '>': sb.Append("&gt;"); break;
                case '"': sb.Append("&quot;"); break;
                case '\'': sb.Append("&#39;"); break;
                // Control characters other than tab and newlines aren't allowed in XML 1.0.
                case < ' ' when c is not ('\t' or '\n' or '\r'): break;
                default: sb.Append(c); break;
            }
        }
        return sb.ToString();
    }
}

/// <summary>A zip archive with every entry stored (method 0): what an EPUB
/// needs, written the same way as the Swift app's <c>StoredZip</c>.</summary>
public sealed class StoredZip
{
    private readonly MemoryStream _data = new();
    private readonly MemoryStream _central = new();
    private ushort _count;

    // 1980-01-01 00:00, the earliest DOS date: the files have no meaningful
    // time, and a fixed one keeps the output reproducible.
    private const ushort DosTime = 0;
    private const ushort DosDate = (0 << 9) | (1 << 5) | 1;

    public void Add(string path, string text) => Add(path, Encoding.UTF8.GetBytes(text));

    public void Add(string path, byte[] contents)
    {
        var name = Encoding.UTF8.GetBytes(path);
        var crc = Crc32.Checksum(contents);
        var offset = (uint)_data.Length;

        using (var w = new BinaryWriter(_data, Encoding.UTF8, leaveOpen: true))
        {
            w.Write(0x04034b50u);
            w.Write((ushort)20);       // version needed
            w.Write((ushort)0x0800);   // flags: UTF-8 names
            w.Write((ushort)0);        // stored
            w.Write(DosTime);
            w.Write(DosDate);
            w.Write(crc);
            w.Write((uint)contents.Length);
            w.Write((uint)contents.Length);
            w.Write((ushort)name.Length);
            w.Write((ushort)0);        // extra length
            w.Write(name);
            w.Write(contents);
        }
        using (var w = new BinaryWriter(_central, Encoding.UTF8, leaveOpen: true))
        {
            w.Write(0x02014b50u);
            w.Write((ushort)20);       // version made by
            w.Write((ushort)20);       // version needed
            w.Write((ushort)0x0800);
            w.Write((ushort)0);
            w.Write(DosTime);
            w.Write(DosDate);
            w.Write(crc);
            w.Write((uint)contents.Length);
            w.Write((uint)contents.Length);
            w.Write((ushort)name.Length);
            w.Write((ushort)0);        // extra length
            w.Write((ushort)0);        // comment length
            w.Write((ushort)0);        // disk number
            w.Write((ushort)0);        // internal attributes
            w.Write(0u);               // external attributes
            w.Write(offset);
            w.Write(name);
        }
        _count++;
    }

    public byte[] Finish()
    {
        var centralOffset = (uint)_data.Length;
        using var output = new MemoryStream();
        _data.WriteTo(output);
        _central.WriteTo(output);
        using (var w = new BinaryWriter(output, Encoding.UTF8, leaveOpen: true))
        {
            w.Write(0x06054b50u);
            w.Write((ushort)0);        // this disk
            w.Write((ushort)0);        // disk with the directory
            w.Write(_count);
            w.Write(_count);
            w.Write((uint)_central.Length);
            w.Write(centralOffset);
            w.Write((ushort)0);        // comment length
        }
        return output.ToArray();
    }
}

public static class Crc32
{
    private static readonly uint[] Table = Enumerable.Range(0, 256).Select(n =>
    {
        var c = (uint)n;
        for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        return c;
    }).ToArray();

    public static uint Checksum(byte[] data)
    {
        var crc = 0xFFFFFFFFu;
        foreach (var b in data) crc = Table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFFu;
    }
}
