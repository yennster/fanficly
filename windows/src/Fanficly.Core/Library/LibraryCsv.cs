using System.Globalization;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;

namespace Fanficly.Core;

/// <summary>Settings → Export Spreadsheet (#417): the library as a CSV file,
/// one row per saved work with its AO3 link, AO3's details and what the reader
/// added (progress, stars, folders, note, tags). Swift: <c>LibraryCSV</c>.
///
/// UTF-8 with a byte order mark (so Excel reads non-English titles), a header
/// row, CRLF line ends and RFC 4180 quoting. Several values in one cell are
/// joined with "; ", dates are ISO 8601 in UTC, and yes/no columns say
/// <c>yes</c> or <c>no</c>. The columns, their order and every cell's format
/// match the Apple app's, so a file from either app looks the same.
///
/// It isn't the library file (Export Library File…): that JSON is for
/// importing back. This one is for reading, sorting and other apps.</summary>
public static partial class LibraryCsv
{
    /// <summary>The columns, in order. The Apple app's <c>LibraryCSV.columns</c>
    /// must match (both apps' tests pin this list).</summary>
    public static readonly IReadOnlyList<string> Columns =
    [
        "ao3_url", "work_id", "title", "author", "author_url", "fandoms", "relationships",
        "characters", "additional_tags", "rating", "warnings", "categories", "language",
        "words", "chapters", "complete", "published", "updated", "kudos", "hits",
        "bookmarks", "comments", "summary", "saved_at", "last_read_at", "last_read_chapter",
        "progress_percent", "starred", "pinned", "following", "folders", "personal_tags",
        "note", "downloaded",
    ];

    /// <summary>Columns that hold text from AO3 or the reader. A cell in one of
    /// these that starts like a formula gets a leading apostrophe (<see cref="Guarded"/>).</summary>
    public static readonly IReadOnlySet<string> TextColumns = new HashSet<string>
    {
        "title", "author", "fandoms", "relationships", "characters", "additional_tags",
        "rating", "warnings", "categories", "language", "summary", "folders",
        "personal_tags", "note",
    };

    /// <summary>One work's cells, in <see cref="Columns"/> order. Read the
    /// work on the UI thread, like every record.</summary>
    public static IReadOnlyList<string> Row(Work work)
    {
        var id = work.Ao3Id;
        // Imported books (negative ids) aren't on AO3, so they have no link.
        var onAO3 = !EpubImport.IsLocalWork(id);
        var username = work.AuthorUsername.Trim();
        var folders = work.Folders.Select(f => f.Name)
            .Concat(work.Folder is { } legacy ? [legacy.Name] : [])
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.Ordinal);
        var values = new Dictionary<string, string>
        {
            ["ao3_url"] = onAO3 ? $"https://archiveofourown.org/works/{id}" : "",
            ["work_id"] = onAO3 ? id.ToString(CultureInfo.InvariantCulture) : "",
            ["title"] = work.Title,
            ["author"] = work.AuthorName,
            ["author_url"] = onAO3 && username.Length > 0 ? $"https://archiveofourown.org/users/{Uri.EscapeDataString(username)}" : "",
            ["fandoms"] = List(work.Fandoms),
            ["relationships"] = List(work.Relationships),
            ["characters"] = List(work.Characters),
            ["additional_tags"] = List(work.Freeforms),
            ["rating"] = work.Rating,
            ["warnings"] = List(work.Warnings),
            ["categories"] = List(work.Categories),
            ["language"] = work.Language,
            ["words"] = Number(work.WordCount),
            ["chapters"] = $"{Number(work.ChapterCount)}/{(work.TotalChapters is { } total ? Number(total) : "?")}",
            ["complete"] = YesNo(work.IsComplete),
            ["published"] = Date(work.PublishedAt),
            ["updated"] = Date(work.UpdatedAt),
            ["kudos"] = Number(work.Kudos),
            ["hits"] = Number(work.Hits),
            ["bookmarks"] = Number(work.BookmarksCount),
            ["comments"] = Number(work.CommentsCount),
            ["summary"] = PlainText(work.Summary),
            ["saved_at"] = Date(work.SavedAt),
            ["last_read_at"] = Date(work.LastReadAt),
            ["last_read_chapter"] = work.LastReadChapter is { } chapter ? Number(chapter) : "",
            ["progress_percent"] = Percent(work.LastReadProgress),
            ["starred"] = YesNo(work.IsStarred),
            ["pinned"] = YesNo(work.IsPinned),
            ["following"] = YesNo(work.IsFollowed),
            ["folders"] = List(folders),
            ["personal_tags"] = List(work.PersonalTags),
            ["note"] = work.Note ?? "",
            ["downloaded"] = YesNo(WorkPersistence.IsDownloaded(work)),
        };
        return Columns.Select(c => values.GetValueOrDefault(c, "")).ToList();
    }

    /// <summary>Every saved work, oldest saved first, leaving out works that
    /// <paramref name="isPending"/> says wait behind the Undo bar.</summary>
    public static List<IReadOnlyList<string>> Rows(LibraryStore store, Func<int, bool>? isPending = null) =>
        store.Works
            .Where(w => isPending?.Invoke(w.Ao3Id) != true)
            .OrderBy(w => w.SavedAt)
            .Select(Row)
            .ToList();

    /// <summary>The whole file's text, header first, without the byte order mark.</summary>
    public static string Text(IEnumerable<IReadOnlyList<string>> rows)
    {
        var text = new StringBuilder();
        text.Append(string.Join(",", Columns.Select(Escape))).Append("\r\n");
        foreach (var row in rows)
        {
            text.Append(string.Join(",", Columns.Zip(row, (column, value) =>
                Escape(TextColumns.Contains(column) ? Guarded(value) : value)))).Append("\r\n");
        }
        return text.ToString();
    }

    /// <summary>The file's bytes: a UTF-8 byte order mark, then <see cref="Text"/>.</summary>
    public static byte[] Data(IEnumerable<IReadOnlyList<string>> rows) =>
        [0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes(Text(rows))];

    /// <summary>"Fanficly Library 2026-11-23.csv", on the PC's own date.</summary>
    public static string FileName(DateTimeOffset date) =>
        $"Fanficly Library {date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)}.csv";

    // Cells

    /// <summary>RFC 4180: a field holding a comma, a quote or a line break is
    /// quoted, with its quotes doubled.</summary>
    public static string Escape(string field) =>
        field.IndexOfAny([',', '"', '\n', '\r']) < 0 ? field : $"\"{field.Replace("\"", "\"\"")}\"";

    /// <summary>A text cell that starts with <c>=</c>, <c>+</c>, <c>-</c>,
    /// <c>@</c>, a tab or a carriage return gets a leading apostrophe, so a
    /// spreadsheet app shows it as text instead of running it as a formula
    /// (OWASP's CSV injection advice). Titles, tags and summaries come from
    /// AO3, where anyone can write them.</summary>
    public static string Guarded(string value) =>
        value.Length > 0 && "=+-@\t\r".Contains(value[0]) ? "'" + value : value;

    public static string List(IEnumerable<string> values) => string.Join("; ", values);

    public static string YesNo(bool value) => value ? "yes" : "no";

    private static string Number(int value) => value.ToString(CultureInfo.InvariantCulture);

    /// <summary>ISO 8601 in UTC, to the second ("2026-11-23T18:39:09Z"); "" for none.</summary>
    public static string Date(DateTimeOffset? date) =>
        date is { } d ? d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture) : "";

    /// <summary>0…1 progress as a whole percentage, 0–100; "" when never opened.</summary>
    public static string Percent(double? progress)
    {
        if (progress is not { } p || !double.IsFinite(p)) return "";
        return ((int)Math.Round(Math.Clamp(p, 0, 1) * 100, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>AO3's summary HTML as plain text, by the Apple app's steps: a
    /// line break or the end of a paragraph starts a new line, tags go,
    /// entities are decoded, spaces in a line are collapsed and blank lines
    /// dropped.</summary>
    public static string PlainText(string html)
    {
        var text = BreakTag().Replace(html, "\n");
        text = BlockEnd().Replace(text, "\n");
        text = AnyTag().Replace(text, "");
        text = WebUtility.HtmlDecode(text);
        var lines = NewLine().Split(text)
            .Select(line => string.Join(" ", line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)))
            .Where(line => line.Length > 0);
        return string.Join("\n", lines);
    }

    [GeneratedRegex(@"<br\s*/?>", RegexOptions.IgnoreCase)]
    private static partial Regex BreakTag();

    [GeneratedRegex(@"</(p|div|li|blockquote|h[1-6])\s*>", RegexOptions.IgnoreCase)]
    private static partial Regex BlockEnd();

    [GeneratedRegex(@"<[^>]*>")]
    private static partial Regex AnyTag();

    /// <summary>Swift's <c>CharacterSet.newlines</c>.</summary>
    [GeneratedRegex(@"[\n\v\f\r\u0085\u2028\u2029]")]
    private static partial Regex NewLine();
}
