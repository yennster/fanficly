using System.Globalization;

namespace Fanficly.Core;

/// <summary>What the Library (and its folders) can order saved stories by.</summary>
public enum LibrarySortKey { DateSaved, LastRead, LastUpdated, Title, Author, Length }

public static class LibrarySortKeyExtensions
{
    public static IReadOnlyList<LibrarySortKey> All { get; } =
        [LibrarySortKey.DateSaved, LibrarySortKey.LastRead, LibrarySortKey.LastUpdated,
         LibrarySortKey.Title, LibrarySortKey.Author, LibrarySortKey.Length];

    /// <summary>The persisted raw value ("dateSaved", "lastRead", …).</summary>
    public static string RawValue(this LibrarySortKey key) => key switch
    {
        LibrarySortKey.DateSaved => "dateSaved",
        LibrarySortKey.LastRead => "lastRead",
        LibrarySortKey.LastUpdated => "lastUpdated",
        LibrarySortKey.Title => "title",
        LibrarySortKey.Author => "author",
        _ => "length",
    };

    public static LibrarySortKey? ParseLibrarySortKey(string raw) =>
        All.Cast<LibrarySortKey?>().FirstOrDefault(k => k!.Value.RawValue() == raw);

    public static string Title(this LibrarySortKey key) => key switch
    {
        LibrarySortKey.DateSaved => "Date Saved",
        LibrarySortKey.LastRead => "Last Read",
        LibrarySortKey.LastUpdated => "Last Updated",
        LibrarySortKey.Title => "Title",
        LibrarySortKey.Author => "Author",
        _ => "Length",
    };

    /// <summary>Icon id (SF Symbol name; the app maps it to a Fluent glyph).</summary>
    public static string SystemImage(this LibrarySortKey key) => key switch
    {
        LibrarySortKey.DateSaved => "bookmark",
        LibrarySortKey.LastRead => "book",
        LibrarySortKey.LastUpdated => "clock.arrow.circlepath",
        LibrarySortKey.Title => "textformat",
        LibrarySortKey.Author => "person",
        _ => "text.alignleft",
    };

    /// <summary>The direction a key starts in when picked: newest, A to Z, or
    /// longest first.</summary>
    public static bool DefaultAscending(this LibrarySortKey key) =>
        key is LibrarySortKey.Title or LibrarySortKey.Author;

    public static string DirectionLabel(this LibrarySortKey key, bool ascending) => key switch
    {
        LibrarySortKey.DateSaved or LibrarySortKey.LastRead or LibrarySortKey.LastUpdated =>
            ascending ? "Oldest First" : "Newest First",
        LibrarySortKey.Title or LibrarySortKey.Author => ascending ? "A to Z" : "Z to A",
        _ => ascending ? "Shortest First" : "Longest First",
    };
}

/// <summary>The fields stories sort by. <see cref="Work"/> implements it; tests
/// use plain values.</summary>
public interface ILibrarySortable
{
    string Title { get; }
    string AuthorName { get; }
    DateTimeOffset SavedAt { get; }
    DateTimeOffset? LastReadAt { get; }
    DateTimeOffset? UpdatedAt { get; }
    int WordCount { get; }
    bool IsPinned { get; }
}

/// <summary>A Library sort: a key and a direction. The sort menu (UI) picks a
/// new key in its <see cref="LibrarySortKeyExtensions.DefaultAscending"/>
/// direction, and tints itself while <see cref="IsDefault"/> is false.</summary>
public readonly record struct LibrarySort(LibrarySortKey Key, bool Ascending)
{
    /// <summary>Newest saved first — the Library's order before sorting existed.</summary>
    public static LibrarySort Default { get; } = new(LibrarySortKey.DateSaved, false);

    public bool IsDefault => this == Default;

    public const string KeyStorageKey = "library.sortKey";
    public const string AscendingStorageKey = "library.sortAscending";

    /// <summary>From the persisted settings; an unknown key falls back to the default.</summary>
    public static LibrarySort FromStored(string keyRaw, bool ascending) =>
        LibrarySortKeyExtensions.ParseLibrarySortKey(keyRaw) is { } key ? new LibrarySort(key, ascending) : Default;

    /// <summary>Reads the persisted sort from a settings store.</summary>
    public static LibrarySort Load(IKeyValueStore settings) =>
        FromStored(settings.GetString(KeyStorageKey) ?? Default.Key.RawValue(),
                   settings.GetBool(AscendingStorageKey, Default.Ascending));

    public void Store(IKeyValueStore settings)
    {
        settings.SetString(KeyStorageKey, Key.RawValue());
        settings.SetBool(AscendingStorageKey, Ascending);
    }

    /// <summary>Pinned stories stay on top; the rest follow the key and
    /// direction. Stories missing the key (never read, no AO3 update date) go
    /// last in either direction, and ties fall back to newest saved, then
    /// title, so the order never shuffles between renders.</summary>
    public IReadOnlyList<T> Sorted<T>(IEnumerable<T> items) where T : ILibrarySortable
    {
        var self = this;
        var list = items.ToList();
        list.Sort((a, b) =>
        {
            if (a.IsPinned != b.IsPinned) return a.IsPinned ? -1 : 1;
            var c = self.Compare(a, b);
            if (c != 0) return c;
            if (a.SavedAt != b.SavedAt) return a.SavedAt > b.SavedAt ? -1 : 1;
            return LocalizedStandardCompare(a.Title, b.Title);
        });
        return list;
    }

    private int Compare<T>(T a, T b) where T : ILibrarySortable
    {
        switch (Key)
        {
            case LibrarySortKey.DateSaved:
                return Directed(a.SavedAt.CompareTo(b.SavedAt));
            case LibrarySortKey.LastRead:
                return CompareMissingLast(a.LastReadAt, b.LastReadAt);
            case LibrarySortKey.LastUpdated:
                return CompareMissingLast(a.UpdatedAt, b.UpdatedAt);
            case LibrarySortKey.Title:
                return Directed(LocalizedStandardCompare(a.Title, b.Title));
            case LibrarySortKey.Author:
                var byAuthor = Directed(LocalizedStandardCompare(a.AuthorName, b.AuthorName));
                // One author's stories read A to Z whichever way authors run.
                return byAuthor == 0 ? LocalizedStandardCompare(a.Title, b.Title) : byAuthor;
            default:
                if (a.WordCount == b.WordCount) return 0;
                return Directed(a.WordCount < b.WordCount ? -1 : 1);
        }
    }

    private int Directed(int result) => Ascending ? Math.Sign(result) : -Math.Sign(result);

    private int CompareMissingLast(DateTimeOffset? a, DateTimeOffset? b) => (a, b) switch
    {
        ({ } x, { } y) => Directed(x.CompareTo(y)),
        (null, null) => 0,
        (null, _) => 1,
        _ => -1,
    };

    /// <summary>Finder-style ordering (Foundation's <c>localizedStandardCompare</c>):
    /// case-insensitive, digit runs compared by value ("part 2" before "Part
    /// 10"), culture-aware; case only breaks otherwise-equal strings.</summary>
    public static int LocalizedStandardCompare(string a, string b)
    {
        var compare = CultureInfo.CurrentCulture.CompareInfo;
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsDigit(a[i]) && char.IsDigit(b[j]))
            {
                int si = i, sj = j;
                while (i < a.Length && char.IsDigit(a[i])) i++;
                while (j < b.Length && char.IsDigit(b[j])) j++;
                var na = a[si..i].TrimStart('0');
                var nb = b[sj..j].TrimStart('0');
                if (na.Length != nb.Length) return na.Length < nb.Length ? -1 : 1;
                var byValue = string.CompareOrdinal(na, nb);
                if (byValue != 0) return Math.Sign(byValue);
            }
            else
            {
                int si = i, sj = j;
                while (i < a.Length && !char.IsDigit(a[i])) i++;
                while (j < b.Length && !char.IsDigit(b[j])) j++;
                var byText = compare.Compare(a[si..i], b[sj..j], CompareOptions.IgnoreCase | CompareOptions.IgnoreWidth);
                if (byText != 0) return Math.Sign(byText);
            }
        }
        if (i < a.Length || j < b.Length) return i < a.Length ? 1 : -1;
        var tie = compare.Compare(a, b, CompareOptions.None);
        return tie != 0 ? Math.Sign(tie) : Math.Sign(string.CompareOrdinal(a, b));
    }
}
