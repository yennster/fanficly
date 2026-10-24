using System.Collections;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.Data.Sqlite;

namespace Fanficly.Core;

/// <summary>Which kinds of library record a <see cref="LibraryStore.Save"/>
/// changed — what a screen checks to decide whether to refresh (the
/// <c>@Query</c> stand-in).</summary>
[Flags]
public enum LibraryEntityKinds
{
    None = 0,
    Works = 1 << 0,
    Chapters = 1 << 1,
    Tags = 1 << 2,
    Bookmarks = 1 << 3,
    SavedFilters = 1 << 4,
    ReadingProgress = 1 << 5,
    RecentlyViewed = 1 << 6,
    SavedSearches = 1 << 7,
    HiddenWorks = 1 << 8,
    Subscriptions = 1 << 9,
    FollowedAuthors = 1 << 10,
    ReadingStats = 1 << 11,
    /// <summary>Folders themselves, or which works are in them.</summary>
    Folders = 1 << 12,
    BlockedTerms = 1 << 13,
    All = (1 << 14) - 1,
}

/// <summary>Base of every library record (the SwiftData <c>@Model</c> stand-in).
/// Mutate properties freely, then call <see cref="LibraryStore.Save"/>: the
/// store finds what changed by comparing each record against what it last
/// wrote. Property changes raise <see cref="PropertyChanged"/> for binding.
/// Like a SwiftData model, a record belongs to one store and isn't itself
/// locked: mutate it from one thread at a time.</summary>
public abstract class LibraryEntity : INotifyPropertyChanged
{
    /// <summary>Database row id; 0 until inserted.</summary>
    internal long RowId;
    /// <summary>The owning store while inserted (null when new or deleted).</summary>
    internal LibraryStore? Store;
    /// <summary>The row as last written to (or read from) the database; null
    /// when the record has never been saved.</summary>
    internal object?[]? PersistedRow;

    internal abstract LibraryEntityKinds EntityKind { get; }
    /// <summary>The <c>@Attribute(.unique)</c> value, or null when the type has none.</summary>
    internal virtual object? UniqueKey => null;
    /// <summary>The column values, in the order of the type's <c>Columns</c>.</summary>
    internal abstract object?[] ToRow();

    /// <summary>Whether the record is in a store (inserted and not deleted).</summary>
    public bool IsInserted => Store is not null;

    public event PropertyChangedEventHandler? PropertyChanged;

    protected void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        OnPropertyChanged(name);
    }

    protected void OnPropertyChanged(string? name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>Row encode/decode helpers shared by the entity mappings. Dates are
/// stored as UTC ticks (exact round trip), bools as 0/1, lists as JSON text.</summary>
internal static class Db
{
    public static object D(DateTimeOffset d) => d.UtcTicks;
    public static object? D(DateTimeOffset? d) => d?.UtcTicks;
    public static object B(bool b) => b ? 1L : 0L;
    public static object I(int i) => (long)i;
    public static object? I(int? i) => i is { } v ? (long)v : null;

    public static string Str(SqliteDataReader r, int i) => r.IsDBNull(i) ? "" : r.GetString(i);
    public static string? StrN(SqliteDataReader r, int i) => r.IsDBNull(i) ? null : r.GetString(i);
    public static int Int(SqliteDataReader r, int i) => r.IsDBNull(i) ? 0 : (int)r.GetInt64(i);
    public static int? IntN(SqliteDataReader r, int i) => r.IsDBNull(i) ? null : (int)r.GetInt64(i);
    public static long? LongN(SqliteDataReader r, int i) => r.IsDBNull(i) ? null : r.GetInt64(i);
    public static double Dbl(SqliteDataReader r, int i) => r.IsDBNull(i) ? 0 : r.GetDouble(i);
    public static double? DblN(SqliteDataReader r, int i) => r.IsDBNull(i) ? null : r.GetDouble(i);
    public static bool Bool(SqliteDataReader r, int i) => !r.IsDBNull(i) && r.GetInt64(i) != 0;
    public static DateTimeOffset Date(SqliteDataReader r, int i) =>
        r.IsDBNull(i) ? DateTimeOffset.UnixEpoch : new DateTimeOffset(r.GetInt64(i), TimeSpan.Zero);
    public static DateTimeOffset? DateN(SqliteDataReader r, int i) =>
        r.IsDBNull(i) ? null : new DateTimeOffset(r.GetInt64(i), TimeSpan.Zero);
}

/// <summary>One side of the Work ↔ CustomFolder many-to-many. Adding or
/// removing keeps the other side's list in step, like SwiftData's inverse
/// relationship.</summary>
public sealed class EntityLinks<TOwner, TItem> : IReadOnlyList<TItem>
    where TOwner : LibraryEntity where TItem : LibraryEntity
{
    private readonly List<TItem> _items = [];
    private readonly TOwner _owner;
    private readonly Func<TItem, EntityLinks<TItem, TOwner>> _inverse;

    internal EntityLinks(TOwner owner, Func<TItem, EntityLinks<TItem, TOwner>> inverse)
    {
        _owner = owner;
        _inverse = inverse;
    }

    public int Count => _items.Count;
    public TItem this[int index] => _items[index];
    public bool Contains(TItem item) => _items.Contains(item);
    public IEnumerator<TItem> GetEnumerator() => _items.GetEnumerator();
    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    /// <summary>Adds the item (no-op when already present) and the inverse link.</summary>
    public void Add(TItem item)
    {
        if (_items.Contains(item)) return;
        _items.Add(item);
        _inverse(item).AddRaw(_owner);
    }

    public bool Remove(TItem item)
    {
        if (!_items.Remove(item)) return false;
        _inverse(item).RemoveRaw(_owner);
        return true;
    }

    public int RemoveAll(Func<TItem, bool> match)
    {
        var doomed = _items.Where(match).ToList();
        foreach (var item in doomed) Remove(item);
        return doomed.Count;
    }

    public void Clear()
    {
        foreach (var item in _items.ToList()) Remove(item);
    }

    internal void AddRaw(TItem item)
    {
        if (!_items.Contains(item)) _items.Add(item);
    }

    internal void RemoveRaw(TItem item) => _items.Remove(item);
}

/// <summary>A saved work: metadata, local follow/star/pin state, reading
/// position stamps, and (when downloaded) its chapters.</summary>
public sealed class Work : LibraryEntity, ILibrarySortable
{
    internal static readonly string[] Columns =
    [
        "ao3_id", "title", "author_name", "author_username", "summary", "rating", "warnings", "categories",
        "fandoms", "characters", "relationships", "freeforms", "language", "word_count", "chapter_count",
        "total_chapters", "kudos", "hits", "bookmarks_count", "comments_count", "is_complete", "published_at",
        "updated_at", "saved_at", "last_read_at", "last_read_chapter", "last_read_progress", "epub_local_path",
        "is_followed", "followed_at", "last_seen_chapter_count", "last_checked_at", "is_starred", "is_pinned",
        "folder_id",
    ];

    private string _title, _authorName, _authorUsername = "", _summary, _rating, _language;
    private IReadOnlyList<string> _warnings, _categories, _fandoms, _characters, _relationships, _freeforms;
    private int _wordCount, _chapterCount, _kudos, _hits, _bookmarksCount, _commentsCount;
    private int? _totalChapters, _lastReadChapter, _lastSeenChapterCount;
    private bool _isComplete, _isFollowed, _isStarred, _isPinned;
    private DateTimeOffset? _publishedAt, _updatedAt, _lastReadAt, _followedAt, _lastCheckedAt;
    private DateTimeOffset _savedAt;
    private double? _lastReadProgress;
    private string? _epubLocalPath;
    private CustomFolder? _folder;
    internal readonly List<Chapter> ChapterList = [];

    public Work(
        int ao3Id,
        string title,
        string authorName,
        string summary = "",
        string rating = "Not Rated",
        IReadOnlyList<string>? warnings = null,
        IReadOnlyList<string>? categories = null,
        IReadOnlyList<string>? fandoms = null,
        IReadOnlyList<string>? characters = null,
        IReadOnlyList<string>? relationships = null,
        IReadOnlyList<string>? freeforms = null,
        string language = "en",
        int wordCount = 0,
        int chapterCount = 1,
        int? totalChapters = null,
        int kudos = 0,
        int hits = 0,
        int bookmarksCount = 0,
        int commentsCount = 0,
        bool isComplete = false,
        DateTimeOffset? publishedAt = null,
        DateTimeOffset? updatedAt = null,
        DateTimeOffset? savedAt = null)
    {
        Ao3Id = ao3Id;
        _title = title;
        _authorName = authorName;
        _summary = summary;
        _rating = rating;
        _warnings = warnings ?? [];
        _categories = categories ?? [];
        _fandoms = fandoms ?? [];
        _characters = characters ?? [];
        _relationships = relationships ?? [];
        _freeforms = freeforms ?? [];
        _language = language;
        _wordCount = wordCount;
        _chapterCount = chapterCount;
        _totalChapters = totalChapters;
        _kudos = kudos;
        _hits = hits;
        _bookmarksCount = bookmarksCount;
        _commentsCount = commentsCount;
        _isComplete = isComplete;
        _publishedAt = publishedAt;
        _updatedAt = updatedAt;
        _savedAt = savedAt ?? DateTimeOffset.Now;
        Folders = new EntityLinks<Work, CustomFolder>(this, f => f.Works);
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.Works;
    internal override object? UniqueKey => Ao3Id;

    /// <summary>Unique.</summary>
    public int Ao3Id { get; }
    public string Title { get => _title; set => Set(ref _title, value); }
    public string AuthorName { get => _authorName; set => Set(ref _authorName, value); }
    /// <summary>AO3 login for "more by this author"; "" when unknown.</summary>
    public string AuthorUsername { get => _authorUsername; set => Set(ref _authorUsername, value); }
    public string Summary { get => _summary; set => Set(ref _summary, value); }
    public string Rating { get => _rating; set => Set(ref _rating, value); }
    public IReadOnlyList<string> Warnings { get => _warnings; set => Set(ref _warnings, value); }
    public IReadOnlyList<string> Categories { get => _categories; set => Set(ref _categories, value); }
    public IReadOnlyList<string> Fandoms { get => _fandoms; set => Set(ref _fandoms, value); }
    public IReadOnlyList<string> Characters { get => _characters; set => Set(ref _characters, value); }
    public IReadOnlyList<string> Relationships { get => _relationships; set => Set(ref _relationships, value); }
    public IReadOnlyList<string> Freeforms { get => _freeforms; set => Set(ref _freeforms, value); }
    public string Language { get => _language; set => Set(ref _language, value); }
    public int WordCount { get => _wordCount; set => Set(ref _wordCount, value); }
    public int ChapterCount { get => _chapterCount; set => Set(ref _chapterCount, value); }
    public int? TotalChapters { get => _totalChapters; set => Set(ref _totalChapters, value); }
    public int Kudos { get => _kudos; set => Set(ref _kudos, value); }
    public int Hits { get => _hits; set => Set(ref _hits, value); }
    public int BookmarksCount { get => _bookmarksCount; set => Set(ref _bookmarksCount, value); }
    public int CommentsCount { get => _commentsCount; set => Set(ref _commentsCount, value); }
    public bool IsComplete { get => _isComplete; set => Set(ref _isComplete, value); }
    public DateTimeOffset? PublishedAt { get => _publishedAt; set => Set(ref _publishedAt, value); }
    public DateTimeOffset? UpdatedAt { get => _updatedAt; set => Set(ref _updatedAt, value); }
    public DateTimeOffset SavedAt { get => _savedAt; set => Set(ref _savedAt, value); }
    public DateTimeOffset? LastReadAt { get => _lastReadAt; set => Set(ref _lastReadAt, value); }
    public int? LastReadChapter { get => _lastReadChapter; set => Set(ref _lastReadChapter, value); }
    public double? LastReadProgress { get => _lastReadProgress; set => Set(ref _lastReadProgress, value); }
    public string? EpubLocalPath { get => _epubLocalPath; set => Set(ref _epubLocalPath, value); }

    /// <summary>Local "follow" — saved to the device without needing an AO3
    /// login. Followed works are checked for new chapters by the poller.</summary>
    public bool IsFollowed { get => _isFollowed; set => Set(ref _isFollowed, value); }
    public DateTimeOffset? FollowedAt { get => _followedAt; set => Set(ref _followedAt, value); }
    public int? LastSeenChapterCount { get => _lastSeenChapterCount; set => Set(ref _lastSeenChapterCount, value); }
    /// <summary>When the poller last attempted a new-chapter check for this
    /// followed work — drives the oldest-first rotation in
    /// <see cref="SubscriptionPoller.RunFullPollAsync"/>.</summary>
    public DateTimeOffset? LastCheckedAt { get => _lastCheckedAt; set => Set(ref _lastCheckedAt, value); }

    public bool IsStarred { get => _isStarred; set => Set(ref _isStarred, value); }
    public bool IsPinned { get => _isPinned; set => Set(ref _isPinned, value); }

    /// <summary>The downloaded chapters (cascade-deleted with the work). Add one
    /// by constructing a <see cref="Chapter"/> with this work; remove one with
    /// <see cref="LibraryStore.Delete"/>.</summary>
    public IReadOnlyList<Chapter> Chapters => ChapterList;

    /// <summary>Legacy single-folder reference (pre multi-folder); restore clears it.</summary>
    public CustomFolder? Folder { get => _folder; set => Set(ref _folder, value); }

    /// <summary>The folders this work is in; inverse of <see cref="CustomFolder.Works"/>.</summary>
    public EntityLinks<Work, CustomFolder> Folders { get; }

    /// <summary>The Library's metadata search: case-insensitive substring match
    /// on title, author, fandoms, characters, ships, tags, rating, warnings and
    /// categories. An empty (or blank) query matches everything.</summary>
    public bool Matches(string query)
    {
        var trimmed = query.Trim().ToLowerInvariant();
        if (trimmed.Length == 0) return true;
        bool Has(string s) => s.ToLowerInvariant().Contains(trimmed, StringComparison.Ordinal);
        return Has(Title) ||
            Has(AuthorName) ||
            Fandoms.Any(Has) ||
            Characters.Any(Has) ||
            Relationships.Any(Has) ||
            Freeforms.Any(Has) ||
            Has(Rating) ||
            Warnings.Any(Has) ||
            Categories.Any(Has);
    }

    internal override object?[] ToRow() =>
    [
        Db.I(Ao3Id), Title, AuthorName, AuthorUsername, Summary, Rating, LibraryJson.Strings(Warnings),
        LibraryJson.Strings(Categories), LibraryJson.Strings(Fandoms), LibraryJson.Strings(Characters),
        LibraryJson.Strings(Relationships), LibraryJson.Strings(Freeforms), Language, Db.I(WordCount),
        Db.I(ChapterCount), Db.I(TotalChapters), Db.I(Kudos), Db.I(Hits), Db.I(BookmarksCount),
        Db.I(CommentsCount), Db.B(IsComplete), Db.D(PublishedAt), Db.D(UpdatedAt), Db.D(SavedAt),
        Db.D(LastReadAt), Db.I(LastReadChapter), LastReadProgress, EpubLocalPath, Db.B(IsFollowed),
        Db.D(FollowedAt), Db.I(LastSeenChapterCount), Db.D(LastCheckedAt), Db.B(IsStarred), Db.B(IsPinned),
        Folder is { RowId: > 0 } f && f.Store is not null ? f.RowId : null,
    ];

    /// <summary>Reads a row (column 0 is the row id). Returns the legacy folder id
    /// separately: folders are linked once every table is loaded.</summary>
    internal static Work Read(SqliteDataReader r, out long? legacyFolderId)
    {
        var w = new Work(Db.Int(r, 1), Db.Str(r, 2), Db.Str(r, 3))
        {
            _authorUsername = Db.Str(r, 4),
            _summary = Db.Str(r, 5),
            _rating = Db.Str(r, 6),
            _warnings = LibraryJson.ParseStrings(Db.StrN(r, 7)),
            _categories = LibraryJson.ParseStrings(Db.StrN(r, 8)),
            _fandoms = LibraryJson.ParseStrings(Db.StrN(r, 9)),
            _characters = LibraryJson.ParseStrings(Db.StrN(r, 10)),
            _relationships = LibraryJson.ParseStrings(Db.StrN(r, 11)),
            _freeforms = LibraryJson.ParseStrings(Db.StrN(r, 12)),
            _language = Db.Str(r, 13),
            _wordCount = Db.Int(r, 14),
            _chapterCount = Db.Int(r, 15),
            _totalChapters = Db.IntN(r, 16),
            _kudos = Db.Int(r, 17),
            _hits = Db.Int(r, 18),
            _bookmarksCount = Db.Int(r, 19),
            _commentsCount = Db.Int(r, 20),
            _isComplete = Db.Bool(r, 21),
            _publishedAt = Db.DateN(r, 22),
            _updatedAt = Db.DateN(r, 23),
            _savedAt = Db.Date(r, 24),
            _lastReadAt = Db.DateN(r, 25),
            _lastReadChapter = Db.IntN(r, 26),
            _lastReadProgress = Db.DblN(r, 27),
            _epubLocalPath = Db.StrN(r, 28),
            _isFollowed = Db.Bool(r, 29),
            _followedAt = Db.DateN(r, 30),
            _lastSeenChapterCount = Db.IntN(r, 31),
            _lastCheckedAt = Db.DateN(r, 32),
            _isStarred = Db.Bool(r, 33),
            _isPinned = Db.Bool(r, 34),
        };
        legacyFolderId = Db.LongN(r, 35);
        return w;
    }
}

/// <summary>One downloaded chapter. Its <see cref="BodyHtml"/> can be large, so
/// a stored chapter loads it from the database on first access.</summary>
public sealed class Chapter : LibraryEntity
{
    internal static readonly string[] Columns = ["work_id", "idx", "title", "ao_id"];

    private Work? _work;
    private int _index;
    private string _title;
    private int? _aoId;
    private string? _body;
    internal bool BodyLoaded;
    internal bool BodyDirty;

    public Chapter(Work? work, int index, string title, string bodyHtml, int? aoId = null)
    {
        _index = index;
        _title = title;
        _aoId = aoId;
        _body = bodyHtml;
        BodyLoaded = true;
        BodyDirty = true;
        Work = work;
    }

    private Chapter(int index, string title, int? aoId)
    {
        _index = index;
        _title = title;
        _aoId = aoId;
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.Chapters;

    /// <summary>The owning work; setting it moves the chapter between the works'
    /// <see cref="Work.Chapters"/> lists (the inverse relationship).</summary>
    public Work? Work
    {
        get => _work;
        set
        {
            if (ReferenceEquals(_work, value)) return;
            _work?.ChapterList.Remove(this);
            _work = value;
            if (value is not null && !value.ChapterList.Contains(this)) value.ChapterList.Add(this);
            OnPropertyChanged(nameof(Work));
        }
    }

    internal void DetachFromWork()
    {
        _work?.ChapterList.Remove(this);
        _work = null;
    }

    /// <summary>1-based chapter number.</summary>
    public int Index { get => _index; set => Set(ref _index, value); }
    public string Title { get => _title; set => Set(ref _title, value); }

    /// <summary>AO3 chapter id, so a downloaded work can still load/post that
    /// chapter's comments. Null for older saved chapters → callers fall back
    /// to work-level comments.</summary>
    public int? AoId { get => _aoId; set => Set(ref _aoId, value); }

    public string BodyHtml
    {
        get
        {
            if (!BodyLoaded)
            {
                _body = Store?.LoadChapterBody(RowId) ?? "";
                BodyLoaded = true;
            }
            return _body ?? "";
        }
        set
        {
            _body = value;
            BodyLoaded = true;
            BodyDirty = true;
            OnPropertyChanged(nameof(BodyHtml));
        }
    }

    /// <summary>The body for a backup when it's loaded; null when it's only in
    /// the database, where the backup reads it (off the UI thread) without
    /// keeping it in memory.</summary>
    internal string? LoadedBodyForBackup => BodyLoaded ? _body ?? "" : null;

    /// <summary>Drops a loaded, unchanged body from memory (it reloads on access).</summary>
    public void UnloadBody()
    {
        if (BodyDirty || Store is null || PersistedRow is null) return;
        _body = null;
        BodyLoaded = false;
    }

    internal override object?[] ToRow() =>
        [_work is { } w && w.Store is not null ? w.RowId : null, Db.I(Index), Title, Db.I(AoId)];

    internal static Chapter Read(SqliteDataReader r, out long? workId)
    {
        workId = Db.LongN(r, 1);
        return new Chapter(Db.Int(r, 2), Db.Str(r, 3), Db.IntN(r, 4));
    }
}

public sealed class TagRecord : LibraryEntity
{
    internal static readonly string[] Columns = ["name", "kind"];
    private string _kind;

    public TagRecord(string name, string kind)
    {
        Name = name;
        _kind = kind;
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.Tags;
    internal override object? UniqueKey => Name;

    /// <summary>Unique.</summary>
    public string Name { get; }
    public string Kind { get => _kind; set => Set(ref _kind, value); }

    internal override object?[] ToRow() => [Name, Kind];
    internal static TagRecord Read(SqliteDataReader r) => new(Db.Str(r, 1), Db.Str(r, 2));
}

public sealed class BookmarkRecord : LibraryEntity
{
    internal static readonly string[] Columns = ["ao3_id", "work_ao3_id", "notes", "tags", "saved_at"];
    private int _workAo3Id;
    private string _notes;
    private IReadOnlyList<string> _tags;
    private DateTimeOffset _savedAt;

    public BookmarkRecord(int ao3Id, int workAo3Id, string notes = "", IReadOnlyList<string>? tags = null, DateTimeOffset? savedAt = null)
    {
        Ao3Id = ao3Id;
        _workAo3Id = workAo3Id;
        _notes = notes;
        _tags = tags ?? [];
        _savedAt = savedAt ?? DateTimeOffset.Now;
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.Bookmarks;
    internal override object? UniqueKey => Ao3Id;

    /// <summary>Unique.</summary>
    public int Ao3Id { get; }
    public int WorkAo3Id { get => _workAo3Id; set => Set(ref _workAo3Id, value); }
    public string Notes { get => _notes; set => Set(ref _notes, value); }
    public IReadOnlyList<string> Tags { get => _tags; set => Set(ref _tags, value); }
    public DateTimeOffset SavedAt { get => _savedAt; set => Set(ref _savedAt, value); }

    internal override object?[] ToRow() => [Db.I(Ao3Id), Db.I(WorkAo3Id), Notes, LibraryJson.Strings(Tags), Db.D(SavedAt)];
    internal static BookmarkRecord Read(SqliteDataReader r) =>
        new(Db.Int(r, 1), Db.Int(r, 2), Db.Str(r, 3), LibraryJson.ParseStrings(Db.StrN(r, 4)), Db.Date(r, 5));
}

public sealed class SavedFilter : LibraryEntity
{
    internal static readonly string[] Columns = ["name", "filters_json", "saved_at"];
    private string _filtersJson;
    private DateTimeOffset _savedAt;

    public SavedFilter(string name, string filtersJson, DateTimeOffset? savedAt = null)
    {
        Name = name;
        _filtersJson = filtersJson;
        _savedAt = savedAt ?? DateTimeOffset.Now;
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.SavedFilters;
    internal override object? UniqueKey => Name;

    /// <summary>Unique.</summary>
    public string Name { get; }
    public string FiltersJson { get => _filtersJson; set => Set(ref _filtersJson, value); }
    public DateTimeOffset SavedAt { get => _savedAt; set => Set(ref _savedAt, value); }

    internal override object?[] ToRow() => [Name, FiltersJson, Db.D(SavedAt)];
    internal static SavedFilter Read(SqliteDataReader r) => new(Db.Str(r, 1), Db.Str(r, 2), Db.Date(r, 3));
}

/// <summary>Where the reader was in a work: chapter + paragraph anchor.</summary>
public sealed class ReadingProgress : LibraryEntity
{
    internal static readonly string[] Columns = ["ao3_id", "chapter_index", "paragraph_index", "title", "author", "updated_at"];
    private int _chapterIndex, _paragraphIndex;
    private string _title, _author;
    private DateTimeOffset _updatedAt;

    public ReadingProgress(int ao3Id, int chapterIndex = 1, int paragraphIndex = 0, string title = "", string author = "", DateTimeOffset? updatedAt = null)
    {
        Ao3Id = ao3Id;
        _chapterIndex = chapterIndex;
        _paragraphIndex = paragraphIndex;
        _title = title;
        _author = author;
        _updatedAt = updatedAt ?? DateTimeOffset.Now;
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.ReadingProgress;
    internal override object? UniqueKey => Ao3Id;

    /// <summary>Unique.</summary>
    public int Ao3Id { get; }
    public int ChapterIndex { get => _chapterIndex; set => Set(ref _chapterIndex, value); }
    public int ParagraphIndex { get => _paragraphIndex; set => Set(ref _paragraphIndex, value); }
    public string Title { get => _title; set => Set(ref _title, value); }
    public string Author { get => _author; set => Set(ref _author, value); }
    public DateTimeOffset UpdatedAt { get => _updatedAt; set => Set(ref _updatedAt, value); }

    internal override object?[] ToRow() => [Db.I(Ao3Id), Db.I(ChapterIndex), Db.I(ParagraphIndex), Title, Author, Db.D(UpdatedAt)];
    internal static ReadingProgress Read(SqliteDataReader r) =>
        new(Db.Int(r, 1), Db.Int(r, 2), Db.Int(r, 3), Db.Str(r, 4), Db.Str(r, 5), Db.Date(r, 6));
}

/// <summary>A lightweight history entry for a work the user opened. Kept
/// separate from <see cref="Work"/> so merely viewing a fic doesn't create a
/// saved Work row — mirrors ReadingProgress's per-work-id footprint.</summary>
public sealed class RecentlyViewed : LibraryEntity
{
    internal static readonly string[] Columns = ["ao3_id", "title", "author", "fandom", "viewed_at"];
    private string _title, _author, _fandom;
    private DateTimeOffset _viewedAt;

    public RecentlyViewed(int ao3Id, string title, string author = "", string fandom = "", DateTimeOffset? viewedAt = null)
    {
        Ao3Id = ao3Id;
        _title = title;
        _author = author;
        _fandom = fandom;
        _viewedAt = viewedAt ?? DateTimeOffset.Now;
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.RecentlyViewed;
    internal override object? UniqueKey => Ao3Id;

    /// <summary>Unique.</summary>
    public int Ao3Id { get; }
    public string Title { get => _title; set => Set(ref _title, value); }
    public string Author { get => _author; set => Set(ref _author, value); }
    public string Fandom { get => _fandom; set => Set(ref _fandom, value); }
    public DateTimeOffset ViewedAt { get => _viewedAt; set => Set(ref _viewedAt, value); }

    /// <summary>The fandom without its source suffix ("Harry Potter - J. K.
    /// Rowling" → "Harry Potter"), as the history row shows it; "" when unknown.</summary>
    public string FandomShort
    {
        get
        {
            if (Fandom.Length == 0) return "";
            return Fandom.Split(" - ")[0];
        }
    }

    internal override object?[] ToRow() => [Db.I(Ao3Id), Title, Author, Fandom, Db.D(ViewedAt)];
    internal static RecentlyViewed Read(SqliteDataReader r) =>
        new(Db.Int(r, 1), Db.Str(r, 2), Db.Str(r, 3), Db.Str(r, 4), Db.Date(r, 5));
}

public sealed class SavedSearch : LibraryEntity
{
    internal static readonly string[] Columns = ["name", "prompt", "sort_column", "sort_direction", "saved_at"];
    private string _prompt, _sortColumn, _sortDirection;
    private DateTimeOffset _savedAt;

    public SavedSearch(string name, string prompt, string sortColumn = "_score", string sortDirection = "desc", DateTimeOffset? savedAt = null)
    {
        Name = name;
        _prompt = prompt;
        _sortColumn = sortColumn;
        _sortDirection = sortDirection;
        _savedAt = savedAt ?? DateTimeOffset.Now;
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.SavedSearches;
    internal override object? UniqueKey => Name;

    /// <summary>Unique.</summary>
    public string Name { get; }
    public string Prompt { get => _prompt; set => Set(ref _prompt, value); }
    public string SortColumn { get => _sortColumn; set => Set(ref _sortColumn, value); }
    public string SortDirection { get => _sortDirection; set => Set(ref _sortDirection, value); }
    public DateTimeOffset SavedAt { get => _savedAt; set => Set(ref _savedAt, value); }

    internal override object?[] ToRow() => [Name, Prompt, SortColumn, SortDirection, Db.D(SavedAt)];
    internal static SavedSearch Read(SqliteDataReader r) =>
        new(Db.Str(r, 1), Db.Str(r, 2), Db.Str(r, 3), Db.Str(r, 4), Db.Date(r, 5));
}

/// <summary>A work the user has hidden ("block objectionable content" — App
/// Store guideline 1.2). Hidden ids are filtered out of Search and Browse.</summary>
public sealed class HiddenWork : LibraryEntity
{
    internal static readonly string[] Columns = ["ao3_id", "title", "hidden_at"];
    private string _title;
    private DateTimeOffset _hiddenAt;

    public HiddenWork(int ao3Id, string title = "", DateTimeOffset? hiddenAt = null)
    {
        Ao3Id = ao3Id;
        _title = title;
        _hiddenAt = hiddenAt ?? DateTimeOffset.Now;
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.HiddenWorks;
    internal override object? UniqueKey => Ao3Id;

    /// <summary>Unique.</summary>
    public int Ao3Id { get; }
    public string Title { get => _title; set => Set(ref _title, value); }
    public DateTimeOffset HiddenAt { get => _hiddenAt; set => Set(ref _hiddenAt, value); }

    internal override object?[] ToRow() => [Db.I(Ao3Id), Title, Db.D(HiddenAt)];
    internal static HiddenWork Read(SqliteDataReader r) => new(Db.Int(r, 1), Db.Str(r, 2), Db.Date(r, 3));
}

/// <summary>What a <see cref="BlockedTerm"/> blocks.</summary>
public enum BlockedTermKind { Tag, Author }

/// <summary>A tag or author the user has blocked (BlockedTerm, RM-006). Works
/// carrying a blocked tag, or by a blocked author, are filtered out of search
/// and browse lists by <see cref="ContentFilter.Apply"/>, never out of works
/// the user opened on purpose.</summary>
public sealed class BlockedTerm : LibraryEntity
{
    internal static readonly string[] Columns = ["key", "kind", "value", "created_at"];
    private DateTimeOffset _createdAt;

    public BlockedTerm(BlockedTermKind kind, string value, DateTimeOffset? createdAt = null)
        : this(KindName(kind), value, createdAt) { }

    private BlockedTerm(string kind, string value, DateTimeOffset? createdAt)
    {
        Kind = kind;
        Value = value.Trim();
        Key = KeyFor(kind, Value);
        _createdAt = createdAt ?? DateTimeOffset.Now;
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.BlockedTerms;
    internal override object? UniqueKey => Key;

    /// <summary>Unique: lowercased "kind:value", so a term can't be blocked
    /// twice in different case.</summary>
    public string Key { get; }
    /// <summary>"tag" or "author", as the Swift backup spells it.</summary>
    public string Kind { get; }
    /// <summary>As blocked: AO3's tag name, or the author's login.</summary>
    public string Value { get; }
    public DateTimeOffset CreatedAt { get => _createdAt; set => Set(ref _createdAt, value); }

    public static string KindName(BlockedTermKind kind) => kind == BlockedTermKind.Tag ? "tag" : "author";

    public static BlockedTermKind? ParseKind(string kind) => kind switch
    {
        "tag" => BlockedTermKind.Tag,
        "author" => BlockedTermKind.Author,
        _ => null,
    };

    public static string KeyFor(string kind, string value) => $"{kind}:{Blocklist.Fold(value)}";
    public static string KeyFor(BlockedTermKind kind, string value) => KeyFor(KindName(kind), value);

    internal override object?[] ToRow() => [Key, Kind, Value, Db.D(CreatedAt)];
    internal static BlockedTerm Read(SqliteDataReader r) => new(Db.Str(r, 2), Db.Str(r, 3), Db.Date(r, 4));
}

/// <summary>A mirror of one AO3 account subscription ("work:123", "series:9",
/// "user:name"), plus the new-chapter baseline the poller compares against.</summary>
public sealed class SubscriptionRecord : LibraryEntity
{
    internal static readonly string[] Columns = ["key", "kind", "display_name", "author_name", "last_seen_chapter_count", "last_checked_at"];
    private string _kind, _displayName, _authorName;
    private int? _lastSeenChapterCount;
    private DateTimeOffset? _lastCheckedAt;

    public SubscriptionRecord(string key, string kind, string displayName, string authorName = "")
    {
        Key = key;
        _kind = kind;
        _displayName = displayName;
        _authorName = authorName;
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.Subscriptions;
    internal override object? UniqueKey => Key;

    /// <summary>Unique.</summary>
    public string Key { get; }
    public string Kind { get => _kind; set => Set(ref _kind, value); }
    public string DisplayName { get => _displayName; set => Set(ref _displayName, value); }
    public string AuthorName { get => _authorName; set => Set(ref _authorName, value); }
    public int? LastSeenChapterCount { get => _lastSeenChapterCount; set => Set(ref _lastSeenChapterCount, value); }
    public DateTimeOffset? LastCheckedAt { get => _lastCheckedAt; set => Set(ref _lastCheckedAt, value); }

    internal override object?[] ToRow() =>
        [Key, Kind, DisplayName, AuthorName, Db.I(LastSeenChapterCount), Db.D(LastCheckedAt)];
    internal static SubscriptionRecord Read(SqliteDataReader r) =>
        new(Db.Str(r, 1), Db.Str(r, 2), Db.Str(r, 3), Db.Str(r, 4))
        {
            _lastSeenChapterCount = Db.IntN(r, 5),
            _lastCheckedAt = Db.DateN(r, 6),
        };
}

/// <summary>An AO3 author the user follows locally (no login required). The
/// poller checks each followed author's works page for newly-published works.
/// <see cref="KnownWorkIds"/> is the set of work ids already seen, so a new
/// work notifies exactly once; it's seeded at follow time so previously
/// published works don't all alert on the first poll.</summary>
public sealed class FollowedAuthor : LibraryEntity
{
    internal static readonly string[] Columns = ["username", "display_name", "followed_at", "last_checked_at", "known_work_ids"];
    private string _displayName;
    private DateTimeOffset _followedAt;
    private DateTimeOffset? _lastCheckedAt;
    private IReadOnlyList<int> _knownWorkIds;

    public FollowedAuthor(string username, string displayName, DateTimeOffset? followedAt = null,
                          DateTimeOffset? lastCheckedAt = null, IReadOnlyList<int>? knownWorkIds = null)
    {
        Username = username;
        _displayName = displayName;
        _followedAt = followedAt ?? DateTimeOffset.Now;
        _lastCheckedAt = lastCheckedAt;
        _knownWorkIds = knownWorkIds ?? [];
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.FollowedAuthors;
    internal override object? UniqueKey => Username;

    /// <summary>Unique.</summary>
    public string Username { get; }
    public string DisplayName { get => _displayName; set => Set(ref _displayName, value); }
    public DateTimeOffset FollowedAt { get => _followedAt; set => Set(ref _followedAt, value); }
    public DateTimeOffset? LastCheckedAt { get => _lastCheckedAt; set => Set(ref _lastCheckedAt, value); }
    public IReadOnlyList<int> KnownWorkIds { get => _knownWorkIds; set => Set(ref _knownWorkIds, value); }

    internal override object?[] ToRow() =>
        [Username, DisplayName, Db.D(FollowedAt), Db.D(LastCheckedAt), LibraryJson.Ints(KnownWorkIds)];
    internal static FollowedAuthor Read(SqliteDataReader r) =>
        new(Db.Str(r, 1), Db.Str(r, 2), Db.Date(r, 3), Db.DateN(r, 4), LibraryJson.ParseInts(Db.StrN(r, 5)));
}

/// <summary>Aggregated reading statistics for one work the user has read — the
/// source of truth for the Stats tab and the wrap-up. One row per work (keyed
/// by ao3Id), snapshotting the work's metadata at read time (so stats cover
/// fics never saved to the Library) plus active reading seconds bucketed per
/// calendar day, so any period rolls up from the one row.</summary>
public sealed class ReadingStat : LibraryEntity
{
    internal static readonly string[] Columns =
    [
        "ao3_id", "title", "author", "fandoms", "categories", "relationships", "rating", "word_count",
        "first_read_at", "last_read_at", "total_seconds", "day_seconds", "max_progress", "work_is_complete",
    ];
    private string _title, _author, _rating;
    private IReadOnlyList<string> _fandoms, _categories, _relationships;
    private int _wordCount;
    private DateTimeOffset _firstReadAt, _lastReadAt;
    private double _totalSeconds, _maxProgress;
    private IReadOnlyDictionary<string, double> _daySeconds;
    private bool _workIsComplete;

    public ReadingStat(int ao3Id, string title = "", string author = "",
                       IReadOnlyList<string>? fandoms = null, IReadOnlyList<string>? categories = null,
                       IReadOnlyList<string>? relationships = null,
                       string rating = "", int wordCount = 0,
                       DateTimeOffset? firstReadAt = null, DateTimeOffset? lastReadAt = null,
                       double totalSeconds = 0, IReadOnlyDictionary<string, double>? daySeconds = null,
                       double maxProgress = 0, bool workIsComplete = false)
    {
        Ao3Id = ao3Id;
        _title = title;
        _author = author;
        _fandoms = fandoms ?? [];
        _categories = categories ?? [];
        _relationships = relationships ?? [];
        _rating = rating;
        _wordCount = wordCount;
        var now = DateTimeOffset.Now;
        _firstReadAt = firstReadAt ?? now;
        _lastReadAt = lastReadAt ?? now;
        _totalSeconds = totalSeconds;
        _daySeconds = daySeconds ?? new Dictionary<string, double>();
        _maxProgress = maxProgress;
        _workIsComplete = workIsComplete;
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.ReadingStats;
    internal override object? UniqueKey => Ao3Id;

    /// <summary>Unique.</summary>
    public int Ao3Id { get; }
    public string Title { get => _title; set => Set(ref _title, value); }
    public string Author { get => _author; set => Set(ref _author, value); }
    public IReadOnlyList<string> Fandoms { get => _fandoms; set => Set(ref _fandoms, value); }
    public IReadOnlyList<string> Categories { get => _categories; set => Set(ref _categories, value); }
    public IReadOnlyList<string> Relationships { get => _relationships; set => Set(ref _relationships, value); }
    public string Rating { get => _rating; set => Set(ref _rating, value); }
    public int WordCount { get => _wordCount; set => Set(ref _wordCount, value); }
    public DateTimeOffset FirstReadAt { get => _firstReadAt; set => Set(ref _firstReadAt, value); }
    public DateTimeOffset LastReadAt { get => _lastReadAt; set => Set(ref _lastReadAt, value); }
    /// <summary>Total active reading time across all sessions, in seconds.</summary>
    public double TotalSeconds { get => _totalSeconds; set => Set(ref _totalSeconds, value); }
    /// <summary>Active reading seconds keyed by calendar day ("2026-06-26" →
    /// seconds). Assign a new dictionary to change it.</summary>
    public IReadOnlyDictionary<string, double> DaySeconds { get => _daySeconds; set => Set(ref _daySeconds, value); }
    /// <summary>Furthest reading position reached, 0…1. Drives "words read" and
    /// whether the work counts as a finished "story read".</summary>
    public double MaxProgress { get => _maxProgress; set => Set(ref _maxProgress, value); }
    /// <summary>Whether the work itself is a completed AO3 work (a complete work
    /// counts as read at ≥95%).</summary>
    public bool WorkIsComplete { get => _workIsComplete; set => Set(ref _workIsComplete, value); }

    /// <summary>A value-type copy for the pure aggregator.</summary>
    public ReadingStatSnapshot Snapshot => new(
        Ao3Id, Title, Author, Fandoms, Categories, Relationships, Rating, WordCount,
        FirstReadAt, LastReadAt, TotalSeconds, DaySeconds, MaxProgress, WorkIsComplete);

    internal override object?[] ToRow() =>
    [
        Db.I(Ao3Id), Title, Author, LibraryJson.Strings(Fandoms), LibraryJson.Strings(Categories),
        LibraryJson.Strings(Relationships), Rating, Db.I(WordCount), Db.D(FirstReadAt), Db.D(LastReadAt),
        TotalSeconds, LibraryJson.DoubleMap(DaySeconds), MaxProgress, Db.B(WorkIsComplete),
    ];

    internal static ReadingStat Read(SqliteDataReader r) => new(
        Db.Int(r, 1), Db.Str(r, 2), Db.Str(r, 3),
        LibraryJson.ParseStrings(Db.StrN(r, 4)), LibraryJson.ParseStrings(Db.StrN(r, 5)),
        LibraryJson.ParseStrings(Db.StrN(r, 6)), Db.Str(r, 7), Db.Int(r, 8),
        Db.Date(r, 9), Db.Date(r, 10), Db.Dbl(r, 11), LibraryJson.ParseDoubleMap(Db.StrN(r, 12)),
        Db.Dbl(r, 13), Db.Bool(r, 14));
}

/// <summary>A user-made Library folder. A work can be in many folders.</summary>
public sealed class CustomFolder : LibraryEntity
{
    internal static readonly string[] Columns = ["name", "created_at"];
    private DateTimeOffset _createdAt;

    public CustomFolder(string name, DateTimeOffset? createdAt = null)
    {
        Name = name;
        _createdAt = createdAt ?? DateTimeOffset.Now;
        Works = new EntityLinks<CustomFolder, Work>(this, w => w.Folders);
    }

    internal override LibraryEntityKinds EntityKind => LibraryEntityKinds.Folders;
    internal override object? UniqueKey => Name;

    /// <summary>Unique.</summary>
    public string Name { get; }
    public DateTimeOffset CreatedAt { get => _createdAt; set => Set(ref _createdAt, value); }

    /// <summary>The works in this folder (deleting the folder just unlinks them).</summary>
    public EntityLinks<CustomFolder, Work> Works { get; }

    internal override object?[] ToRow() => [Name, Db.D(CreatedAt)];
    internal static CustomFolder Read(SqliteDataReader r) => new(Db.Str(r, 1), Db.Date(r, 2));
}
