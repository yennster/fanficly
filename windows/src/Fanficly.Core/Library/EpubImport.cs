using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using AngleSharp.Dom;

namespace Fanficly.Core;

/// <summary>Why an EPUB couldn't be imported; the message is shown as is.</summary>
public sealed class EpubImportException(string message) : Exception(message);

/// <summary>Turns an EPUB file (an AO3 download, or any other e-book) into a
/// work the Library can hold and the reader can open offline (Swift:
/// <c>EPUBImport</c>). <see cref="Parse"/> is pure; <see cref="Save"/> stores
/// the result.
///
/// An AO3 EPUB keeps its AO3 work id (from the "archiveofourown.org/works/&lt;id&gt;"
/// link AO3 puts in the book), so importing one fills in the same Library entry
/// a download would, and AO3 actions keep working once AO3 is reachable. Any
/// other book gets a negative id from the book's identifier
/// (<see cref="LocalWorkId"/>), which can never clash with an AO3 work and stays
/// the same when the same book is imported again.</summary>
public static partial class EpubImport
{
    /// <summary>True for the ids <see cref="LocalWorkId"/> hands out: a book that isn't on AO3.</summary>
    public static bool IsLocalWork(int id) => id < 0;

    /// <summary>Parses an EPUB's bytes into a work and its chapters.</summary>
    public static AO3WorkPayload Parse(byte[] data)
    {
        ZipArchive zip;
        try { zip = new ZipArchive(new MemoryStream(data), ZipArchiveMode.Read); }
        catch (InvalidDataException) { throw new EpubImportException("This file isn't an EPUB e-book."); }
        using (zip) return Parse(zip);
    }

    private static AO3WorkPayload Parse(ZipArchive zip)
    {
        var containerXml = ReadText(zip, "META-INF/container.xml")
            ?? throw new EpubImportException("This file isn't an EPUB e-book.");
        var container = ParseXml(containerXml);
        var opfPath = Elements(container, "rootfile").Select(e => (string?)e.Attribute("full-path")).FirstOrDefault(p => !string.IsNullOrEmpty(p));
        var opfXml = opfPath is null ? null : ReadText(zip, opfPath);
        if (opfPath is null || opfXml is null) throw Damaged("no package file");
        var opf = ParseXml(opfXml);
        var opfDir = DirectoryOf(opfPath);

        // Manifest: id → (path, media type, properties).
        var manifest = new Dictionary<string, (string Path, string Type, string Properties)>();
        foreach (var item in Elements(opf, "item"))
        {
            var id = (string?)item.Attribute("id");
            var href = (string?)item.Attribute("href");
            if (string.IsNullOrEmpty(id) || string.IsNullOrEmpty(href)) continue;
            manifest.TryAdd(id, (Resolve(href, opfDir), ((string?)item.Attribute("media-type") ?? "").ToLowerInvariant(),
                (string?)item.Attribute("properties") ?? ""));
        }
        var spinePaths = new List<string>();
        foreach (var itemref in Elements(opf, "itemref"))
        {
            if ((string?)itemref.Attribute("idref") is not { } idref || !manifest.TryGetValue(idref, out var item)) continue;
            if (item.Type.Contains("html") || item.Path.EndsWith("html", StringComparison.OrdinalIgnoreCase)) spinePaths.Add(item.Path);
        }
        if (spinePaths.Count == 0) throw Damaged("no reading order");

        var docs = new List<IDocument>();
        var rawFirstDocs = new StringBuilder();
        for (var i = 0; i < spinePaths.Count; i++)
        {
            var html = ReadText(zip, spinePaths[i]) ?? "";
            if (i < 3) rawFirstDocs.Append(html);
            docs.Add(HtmlDom.Parse(ExpandSelfClosingTags(html)));
        }

        List<string> Dc(string name) => Elements(opf, name).Select(e => e.Value.Trim()).Where(v => v.Length > 0).ToList();
        var ao3Id = Ao3WorkId(opfXml) ?? Ao3WorkId(rawFirstDocs.ToString());
        var preface = docs.Take(3).Select(d => new Ao3Preface(d)).FirstOrDefault(p => !p.IsEmpty) ?? new Ao3Preface();

        // Table of contents: the NCX (EPUB 2) or the nav document (EPUB 3).
        var spineIndex = new Dictionary<string, int>();
        for (var i = 0; i < spinePaths.Count; i++) spineIndex.TryAdd(spinePaths[i], i);
        var toc = new List<TocEntry>();
        var tocId = Elements(opf, "spine").Select(e => (string?)e.Attribute("toc")).FirstOrDefault() ?? "";
        var ncxPath = manifest.TryGetValue(tocId, out var ncxItem) ? ncxItem.Path
            : manifest.Values.Where(v => v.Type == "application/x-dtbncx+xml").Select(v => v.Path).FirstOrDefault();
        if (ncxPath is not null && ReadText(zip, ncxPath) is { } ncxXml)
        {
            var dir = DirectoryOf(ncxPath);
            foreach (var point in Elements(ParseXml(ncxXml), "navPoint"))
            {
                var label = point.Elements().FirstOrDefault(e => e.Name.LocalName == "navLabel")?.Value ?? "";
                if (point.Elements().FirstOrDefault(e => e.Name.LocalName == "content")?.Attribute("src")?.Value is not { } src) continue;
                toc.Add(new TocEntry(label, src, dir));
            }
        }
        if (toc.Count == 0 && manifest.Values.Where(v => v.Properties.Contains("nav")).Select(v => v.Path).FirstOrDefault() is { } navPath
            && ReadText(zip, navPath) is { } navHtml)
        {
            var nav = HtmlDom.Parse(ExpandSelfClosingTags(navHtml));
            var dir = DirectoryOf(navPath);
            var navs = nav.QuerySelectorAll("nav").ToList();
            var tocNav = navs.FirstOrDefault(n => n.Attr("epub:type").Contains("toc")) ?? navs.FirstOrDefault();
            foreach (var link in tocNav?.QuerySelectorAll("a[href]") ?? Enumerable.Empty<IElement>())
                toc.Add(new TocEntry(link.TextContent, link.Attr("href"), dir));
        }

        var sections = Split(docs, toc, spineIndex);
        var fromAo3 = ao3Id is not null || !preface.IsEmpty;
        if (fromAo3) sections = FoldAo3FrontAndBackMatter(sections);
        sections = sections.Where(s => !string.IsNullOrWhiteSpace(s.Text)).ToList();
        if (sections.Count == 0) throw new EpubImportException("The EPUB has no chapter text to read.");

        var chapters = sections.Select((s, i) => new AO3ChapterPayload(
            i + 1,
            s.Title.Length == 0 ? $"Chapter {i + 1}" : s.Title,
            s.Html,
            ao3Id is null ? null : ChapterId(s.HeadingHtml))).ToList();
        var title = Dc("title").FirstOrDefault() ?? preface.Title ?? "Untitled";
        var creators = Dc("creator");
        var author = creators.Count == 0 ? preface.Author ?? "Unknown author" : string.Join(", ", creators);
        var identifier = Dc("identifier").FirstOrDefault() ?? "";
        var words = preface.Words ?? sections.Sum(s => WordCount(s.Text));
        var description = Dc("description").FirstOrDefault();

        var summary = new AO3WorkSummary
        {
            Id = ao3Id ?? LocalWorkId(identifier, title, author),
            Title = title,
            Author = author,
            AuthorUsername = preface.AuthorUsername,
            Summary = preface.SummaryHtml ?? (description is null ? "" : SummaryHtml(description)),
            Rating = preface.Rating ?? "Not Rated",
            Warnings = preface.Warnings,
            Categories = preface.Categories,
            Fandoms = preface.Fandoms,
            Characters = preface.Characters,
            Relationships = preface.Relationships,
            Freeforms = preface.Freeforms.Count == 0 && !fromAo3 ? Dc("subject") : preface.Freeforms,
            WordCount = words,
            ChapterCount = chapters.Count,
            TotalChapters = preface.TotalChapters ?? (fromAo3 ? null : chapters.Count),
            Language = preface.Language ?? Dc("language").FirstOrDefault() ?? "en",
            IsComplete = preface.IsComplete ?? !fromAo3,
            UpdatedAt = preface.UpdatedAt ?? preface.PublishedAt,
        };
        return new AO3WorkPayload(summary, chapters);
    }

    /// <summary>Saves an imported book to the Library, with the file kept as the
    /// work's EPUB so it shows as Downloaded. A work already in the Library (an
    /// AO3 book) keeps its AO3 details and reading position and takes the
    /// book's chapters; a new one gets the book's details too. Saves and queues
    /// a backup like every <see cref="WorkPersistence"/> change.</summary>
    public static Work Save(AO3WorkPayload payload, byte[] epub, LibraryStore store)
    {
        Work work;
        if (store.GetWork(payload.Summary.Id) is { } existing)
        {
            work = existing;
            foreach (var ch in work.Chapters.ToList()) store.Delete(ch);
            foreach (var ch in payload.Chapters) store.Insert(new Chapter(work, ch.Index, ch.Title, ch.BodyHtml, ch.AoId));
            if (work.WordCount == 0) work.WordCount = payload.Summary.WordCount;
            work.ChapterCount = Math.Max(work.ChapterCount, payload.Chapters.Count);
            SyncDeletions.SetDownloadRemoved(LibrarySyncManager.SharedSettings, work.Ao3Id, removed: false);
            store.TrySave();
        }
        else
        {
            work = WorkPersistence.Upsert(payload, store);
        }
        Directory.CreateDirectory(WorkPersistence.LibraryFolder);
        var target = WorkPersistence.EpubTargetPath(work.Ao3Id);
        var temp = target + ".tmp";
        File.WriteAllBytes(temp, epub);
        File.Move(temp, target, overwrite: true);
        LibrarySyncManager.QueueBackupShared(store);
        return work;
    }

    // MARK: - Ids

    /// <summary>The AO3 work id in the first "archiveofourown.org/works/&lt;id&gt;" link.</summary>
    public static int? Ao3WorkId(string text)
    {
        var m = WorkLinkRegex().Match(text);
        return m.Success && int.TryParse(m.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var id) && id > 0 ? id : null;
    }

    /// <summary>A negative, stable id for a book that isn't from AO3: FNV-1a of
    /// its identifier (or title and author when it has none), so importing the
    /// same book again replaces it instead of adding a copy.</summary>
    public static int LocalWorkId(string identifier, string title, string author)
    {
        var key = identifier.Length == 0 ? $"{title}\u001F{author}" : identifier;
        var hash = 0xcbf29ce484222325UL;
        foreach (var b in Encoding.UTF8.GetBytes(key))
        {
            hash ^= b;
            hash = unchecked(hash * 0x100000001b3UL);
        }
        return -(int)(hash % 2_000_000_000UL) - 1;
    }

    private static int? ChapterId(string html)
    {
        var m = ChapterLinkRegex().Match(html);
        return m.Success && int.TryParse(m.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var id) ? id : null;
    }

    // MARK: - Splitting into chapters

    private sealed class TocEntry
    {
        public string Label { get; }
        public string Path { get; }
        public string? Fragment { get; }

        public TocEntry(string label, string href, string baseDir)
        {
            Label = label.Trim();
            var hash = href.IndexOf('#');
            Path = Resolve(hash < 0 ? href : href[..hash], baseDir);
            Fragment = hash < 0 || hash == href.Length - 1 ? null : Uri.UnescapeDataString(href[(hash + 1)..]);
        }
    }

    public sealed class Section
    {
        public string Title { get; set; } = "";
        public string Html { get; set; } = "";
        public string Text { get; set; } = "";
        /// <summary>The markup of the heading the section starts at, where AO3
        /// links the chapter (for its chapter id).</summary>
        public string HeadingHtml { get; set; } = "";
    }

    /// <summary>Splits the spine into sections at the table of contents' entries.
    /// Text before the first entry (a cover or title page) is left out. Without
    /// a usable table of contents every spine document is a section.</summary>
    private static List<Section> Split(List<IDocument> docs, List<TocEntry> toc, Dictionary<string, int> spineIndex)
    {
        foreach (var doc in docs) Clean(doc);

        var starts = new List<(int Spine, IElement? Element, string Label)>();
        var last = (-1, -1);
        foreach (var entry in toc)
        {
            if (!spineIndex.TryGetValue(entry.Path, out var spine)) continue;
            IElement? element = null;
            var position = -1;
            if (entry.Fragment is { } fragment && docs[spine].Body is { } body)
            {
                var all = body.QuerySelectorAll("*").ToList();
                var i = all.FindIndex(e => e.Id == fragment || e.GetAttribute("name") == fragment);
                if (i >= 0) { element = all[i]; position = i; }
            }
            // Out of document order, or the same place again: not a new section.
            if ((spine, position).CompareTo(last) <= 0) continue;
            last = (spine, position);
            starts.Add((spine, element, entry.Label));
        }

        if (starts.Count == 0)
        {
            var whole = new List<Section>();
            foreach (var doc in docs)
            {
                if (doc.Body is not { } body) continue;
                var section = new Section { Title = HeadingText(body) ?? "" };
                foreach (var node in body.ChildNodes) Append(node, section);
                whole.Add(section);
            }
            return whole;
        }

        var sections = new List<Section>();
        Section? current = null;
        for (var spine = 0; spine < docs.Count; spine++)
        {
            if (docs[spine].Body is not { } body) continue;
            var here = starts.Where(s => s.Spine == spine).ToList();
            if (here.Any(s => s.Element is null))
            {
                if (current is not null) sections.Add(current);
                current = new Section
                {
                    Title = here.First(s => s.Element is null).Label,
                    HeadingHtml = body.QuerySelector("h1, h2, h3")?.OuterHtml ?? "",
                };
            }
            var labels = new Dictionary<IElement, string>(ReferenceEqualityComparer.Instance);
            var containsStart = new HashSet<IElement>(ReferenceEqualityComparer.Instance);
            foreach (var start in here)
            {
                if (start.Element is not { } element) continue;
                labels[element] = start.Label;
                for (var p = element.ParentElement; p is not null; p = p.ParentElement) containsStart.Add(p);
            }

            void Walk(INode node)
            {
                if (node is IElement element)
                {
                    if (labels.TryGetValue(element, out var label))
                    {
                        if (current is not null) sections.Add(current);
                        current = new Section { Title = label, HeadingHtml = element.OuterHtml };
                        // A heading that just repeats the entry's title is the
                        // reader's chapter title already.
                        if (!containsStart.Contains(element))
                        {
                            if (!IsHeading(element, label)) Append(element, current);
                            return;
                        }
                    }
                    if (containsStart.Contains(element))
                    {
                        foreach (var child in element.ChildNodes.ToList()) Walk(child);
                        return;
                    }
                }
                if (current is not null) Append(node, current);
            }
            foreach (var node in body.ChildNodes.ToList()) Walk(node);
        }
        if (current is not null) sections.Add(current);
        return sections;
    }

    /// <summary>AO3 books open with a "Preface" (the work's tags and summary,
    /// read into the Library entry instead) and end with an "Afterword" (the end
    /// notes, which belong to the last chapter).</summary>
    public static List<Section> FoldAo3FrontAndBackMatter(List<Section> sections)
    {
        var result = new List<Section>();
        foreach (var section in sections)
        {
            var title = section.Title.ToLowerInvariant();
            if (title == "preface") continue;
            if (title == "afterword" && result.Count > 0)
            {
                result[^1].Html += section.Html;
                result[^1].Text += " " + section.Text;
                continue;
            }
            result.Add(section);
        }
        return result;
    }

    private static void Append(INode node, Section section)
    {
        switch (node)
        {
            case IText text:
                section.Text += text.Data;
                section.Html += System.Net.WebUtility.HtmlEncode(text.Data);
                break;
            case IElement element:
                section.Text += " " + element.Text();
                section.Html += element.OuterHtml;
                break;
        }
    }

    /// <summary>Takes out what the reader can't use from a book's markup:
    /// scripts, styles, and pictures stored inside the book (the reader only
    /// shows pictures from the web).</summary>
    private static void Clean(IDocument doc)
    {
        foreach (var e in doc.QuerySelectorAll("script, style, link, meta, svg, object, iframe").ToList()) e.Remove();
        foreach (var img in doc.QuerySelectorAll("img").ToList())
        {
            var src = img.Attr("src").ToLowerInvariant();
            if (!(src.StartsWith("https://", StringComparison.Ordinal) || src.StartsWith("http://", StringComparison.Ordinal))) img.Remove();
        }
    }

    private static bool IsHeading(IElement element, string label) =>
        element.LocalName is "h1" or "h2" or "h3" or "h4" or "h5" or "h6"
        && string.Equals(element.TextContent.Trim(), label, StringComparison.OrdinalIgnoreCase);

    private static string? HeadingText(IElement body)
    {
        var text = body.QuerySelector("h1, h2, h3")?.TextContent.Trim();
        return string.IsNullOrEmpty(text) ? null : text;
    }

    // MARK: - AO3's preface

    /// <summary>The tags and stats AO3 prints at the top of every download as a
    /// <c>&lt;dl&gt;</c> of "Rating:", "Fandom:", "Stats:" … pairs, read by their
    /// labels rather than class names, which e-book converters rename.</summary>
    private sealed class Ao3Preface
    {
        public string? Title, Author, SummaryHtml, Rating, Language;
        public string AuthorUsername = "";
        public IReadOnlyList<string> Warnings = [], Categories = [], Fandoms = [], Relationships = [], Characters = [], Freeforms = [];
        public int? Words, TotalChapters;
        public bool? IsComplete;
        public DateTimeOffset? PublishedAt, UpdatedAt;
        public bool IsEmpty { get; private set; } = true;

        public Ao3Preface() { }

        public Ao3Preface(IDocument document)
        {
            foreach (var dt in document.QuerySelectorAll("dt"))
            {
                if (dt.NextElementSibling is not { LocalName: "dd" } dd) continue;
                var label = dt.TextContent.Trim().TrimEnd(':').Trim().ToLowerInvariant();
                var links = dd.QuerySelectorAll("a").Select(a => a.TextContent.Trim()).Where(t => t.Length > 0).ToList();
                var text = dd.TextContent.Trim();
                IReadOnlyList<string> values = links.Count > 0 ? links : text.Split(", ", StringSplitOptions.RemoveEmptyEntries).ToList();
                switch (label)
                {
                    case "rating" or "ratings": Rating = values.FirstOrDefault(); break;
                    case "archive warning" or "archive warnings" or "warning" or "warnings": Warnings = values; break;
                    case "category" or "categories": Categories = values; break;
                    case "fandom" or "fandoms": Fandoms = values; break;
                    case "relationship" or "relationships": Relationships = values; break;
                    case "character" or "characters": Characters = values; break;
                    case "additional tags" or "additional tag" or "freeforms": Freeforms = values; break;
                    case "language": Language = text.Length == 0 ? null : text; break;
                    case "stats": ReadStats(text); break;
                    default: continue;
                }
                IsEmpty = false;
            }
            if (IsEmpty) return;
            var byline = document.QuerySelectorAll("a[rel='author']").ToList();
            if (byline.Count > 0)
            {
                Author = string.Join(", ", byline.Select(a => a.TextContent.Trim()));
                AuthorUsername = SearchResultsParser.AuthorLogin(byline[0].Attr("href"));
            }
            Title = document.QuerySelector("h1")?.TextContent.Trim();
            // "Summary" is a paragraph of its own, followed by the summary's blockquote.
            foreach (var label in document.QuerySelectorAll("p, b, strong, h2, h3"))
            {
                if (label.TextContent.Trim() != "Summary") continue;
                var next = label.NextElementSibling ?? label.ParentElement?.NextElementSibling;
                if (next is { LocalName: "blockquote" })
                {
                    SummaryHtml = next.InnerHtml;
                    break;
                }
            }
        }

        private void ReadStats(string text)
        {
            static DateTimeOffset? Date(Match m) =>
                m.Success && DateTime.TryParseExact(m.Groups[1].Value, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                    DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var d)
                    ? new DateTimeOffset(d, TimeSpan.Zero) : null;
            PublishedAt = Date(Regex.Match(text, @"Published:\s*(\d{4}-\d{2}-\d{2})"));
            var completed = Date(Regex.Match(text, @"Completed:\s*(\d{4}-\d{2}-\d{2})"));
            UpdatedAt = Date(Regex.Match(text, @"Updated:\s*(\d{4}-\d{2}-\d{2})")) ?? completed;
            var words = Regex.Match(text, @"Words:\s*([\d,]+)");
            if (words.Success && int.TryParse(words.Groups[1].Value.Replace(",", ""), NumberStyles.None, CultureInfo.InvariantCulture, out var w))
                Words = w;
            var chapters = Regex.Match(text, @"Chapters:\s*(\d+)/([\d?]+)");
            if (chapters.Success)
            {
                var posted = int.Parse(chapters.Groups[1].Value, CultureInfo.InvariantCulture);
                TotalChapters = int.TryParse(chapters.Groups[2].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var t) ? t : null;
                IsComplete = completed is not null || (TotalChapters is not null && posted == TotalChapters);
            }
            else if (completed is not null)
            {
                IsComplete = true;
            }
        }
    }

    // MARK: - Helpers

    private static readonly HashSet<string> VoidTags = new(StringComparer.OrdinalIgnoreCase)
    {
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    };

    /// <summary>XHTML lets any element close itself (<c>&lt;a id="x"/&gt;</c>,
    /// <c>&lt;title/&gt;</c>), but an HTML parser reads that as an opening tag and
    /// swallows what follows. Spells those out as an opening and closing tag;
    /// void elements stay.</summary>
    public static string ExpandSelfClosingTags(string html) =>
        SelfClosingRegex().Replace(html, m => VoidTags.Contains(m.Groups[1].Value)
            ? m.Value
            : $"<{m.Groups[1].Value}{m.Groups[2].Value}></{m.Groups[1].Value}>");

    private static string SummaryHtml(string description) =>
        description.Contains('<')
            ? description
            : string.Concat(description.Split('\n').Where(l => l.Trim().Length > 0)
                .Select(l => $"<p>{System.Net.WebUtility.HtmlEncode(l)}</p>"));

    private static int WordCount(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

    private static XDocument ParseXml(string xml)
    {
        try { return XDocument.Parse(xml); }
        catch (System.Xml.XmlException e) { throw Damaged(e.Message); }
    }

    /// <summary>Elements by local name, whatever namespace the file uses.</summary>
    private static IEnumerable<XElement> Elements(XDocument doc, string localName) =>
        doc.Descendants().Where(e => string.Equals(e.Name.LocalName, localName, StringComparison.OrdinalIgnoreCase));

    private static string DirectoryOf(string path)
    {
        var slash = path.LastIndexOf('/');
        return slash < 0 ? "" : path[..(slash + 1)];
    }

    /// <summary>A manifest or link <c>href</c> as a path inside the zip.</summary>
    public static string Resolve(string href, string baseDir)
    {
        string decoded;
        try { decoded = Uri.UnescapeDataString(href); }
        catch (UriFormatException) { decoded = href; }
        var parts = new List<string>();
        foreach (var part in (baseDir + decoded).Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part == ".") continue;
            if (part == "..") { if (parts.Count > 0) parts.RemoveAt(parts.Count - 1); continue; }
            parts.Add(part);
        }
        return string.Join('/', parts);
    }

    /// <summary>An entry's text, or null when the book has no such file. Paths
    /// match exactly, then ignoring case (some tools change the case of hrefs).</summary>
    private static string? ReadText(ZipArchive zip, string path)
    {
        var entry = zip.GetEntry(path)
            ?? zip.Entries.FirstOrDefault(e => string.Equals(e.FullName, path, StringComparison.OrdinalIgnoreCase));
        if (entry is null) return null;
        // A chapter is kilobytes; refuse anything absurd rather than read it.
        if (entry.Length > 256L * 1024 * 1024) throw Damaged("file too large");
        try
        {
            using var reader = new StreamReader(entry.Open(), Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            return reader.ReadToEnd();
        }
        catch (InvalidDataException) { throw Damaged("couldn't decompress"); }
    }

    private static EpubImportException Damaged(string detail) => new($"The EPUB couldn't be read ({detail}).");

    [GeneratedRegex(@"archiveofourown\.org/works/(\d+)")]
    private static partial Regex WorkLinkRegex();

    [GeneratedRegex(@"/works/\d+/chapters/(\d+)")]
    private static partial Regex ChapterLinkRegex();

    [GeneratedRegex(@"<([A-Za-z][\w:.-]*)((?:\s[^<>]*?)?)\s*/>")]
    private static partial Regex SelfClosingRegex();
}
