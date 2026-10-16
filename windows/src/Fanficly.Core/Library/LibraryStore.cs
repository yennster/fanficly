using Microsoft.Data.Sqlite;

namespace Fanficly.Core;

/// <summary>The on-device library database — the Windows stand-in for
/// SwiftData's <c>ModelContainer</c> + <c>ModelContext</c>, backed by SQLite.
///
/// <para>Every record is loaded once when the store opens (chapter bodies
/// excepted: they load on first access) and kept in an identity map, so a
/// query always returns the same instances, includes records inserted but
/// not yet saved, and excludes ones deleted but not yet saved — the way a
/// SwiftData fetch sees pending changes. Mutate records, <see cref="Insert"/>
/// and <see cref="Delete"/>, then <see cref="Save"/>: it writes every change
/// in one transaction, found by comparing each record with what was last
/// written, and then raises <see cref="Changed"/> with the kinds of record
/// that changed so screens can refresh like <c>@Query</c>.</para>
///
/// <para>Thread-safe: every store call takes one lock, so the background
/// poller and the UI can share a store. Records themselves aren't locked
/// (like SwiftData models), so mutate a given record from one thread at a
/// time.</para>
///
/// <para>Relationships follow SwiftData's rules: a work's chapters cascade
/// with it; deleting a folder or a work just unlinks the many-to-many; a
/// chapter or folder reachable from an inserted record is inserted on save.
/// Unique attributes are enforced (in memory and by UNIQUE constraints):
/// inserting a record whose unique key matches a stored one replaces it, as
/// a SwiftData upsert does.</para></summary>
public sealed class LibraryStore : IDisposable
{
    private readonly SqliteConnection _conn;
    private readonly Lock _gate = new();
    private readonly Dictionary<Type, List<LibraryEntity>> _live = new();
    private readonly Dictionary<Type, Dictionary<object, LibraryEntity>> _unique = new();
    private readonly Dictionary<Type, long> _lastId = new();
    private readonly List<(string Table, long Id, LibraryEntityKinds Kind)> _pendingDeletes = [];
    private HashSet<(long Work, long Folder)> _persistedLinks = [];
    private bool _disposed;

    /// <summary>Raised after a <see cref="Save"/> that changed anything, with
    /// the kinds of record that changed. Raised on the saving thread, outside
    /// the store's lock; UI subscribers marshal to their own thread.</summary>
    public event Action<LibraryEntityKinds>? Changed;

    /// <summary>The database file, or ":memory:".</summary>
    public string DatabasePath { get; }

    private LibraryStore(string path)
    {
        DatabasePath = path;
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = path == ":memory:" ? SqliteOpenMode.Memory : SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        };
        _conn = new SqliteConnection(builder.ToString());
        _conn.Open();
        if (path != ":memory:")
        {
            using var wal = _conn.CreateCommand();
            wal.CommandText = "PRAGMA journal_mode = WAL";
            wal.ExecuteNonQuery();
        }
        foreach (var t in LibrarySchema.Tables)
        {
            _live[t.Type] = [];
            _unique[t.Type] = new Dictionary<object, LibraryEntity>();
            _lastId[t.Type] = 0;
        }
        LibrarySchema.Migrate(_conn);
        LoadAll();
    }

    /// <summary>Opens (creating and migrating as needed) the database at
    /// <paramref name="path"/>; the app passes a file in its data folder.</summary>
    public static LibraryStore Open(string path)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        return new LibraryStore(path);
    }

    /// <summary>A private, in-memory database (tests, demo mode).</summary>
    public static LibraryStore OpenInMemory() => new(":memory:");

    /// <summary>The schema version the database is at (SQLite <c>user_version</c>).</summary>
    public int SchemaVersion
    {
        get { lock (_gate) return LibrarySchema.UserVersion(_conn); }
    }

    // MARK: - Loading

    private void LoadAll()
    {
        var foldersById = new Dictionary<long, CustomFolder>();
        var worksById = new Dictionary<long, Work>();

        ReadTable<CustomFolder>("custom_folders", CustomFolder.Columns, r =>
        {
            var f = CustomFolder.Read(r);
            foldersById[r.GetInt64(0)] = f;
            return f;
        });
        ReadTable<Work>("works", Work.Columns, r =>
        {
            var w = Work.Read(r, out var legacyFolder);
            if (legacyFolder is { } fid && foldersById.TryGetValue(fid, out var folder)) w.Folder = folder;
            worksById[r.GetInt64(0)] = w;
            return w;
        });
        ReadTable<Chapter>("chapters", Chapter.Columns, r =>
        {
            var c = Chapter.Read(r, out var workId);
            if (workId is { } wid && worksById.TryGetValue(wid, out var work)) c.Work = work;
            return c;
        });
        ReadTable("tags", TagRecord.Columns, TagRecord.Read);
        ReadTable("bookmarks", BookmarkRecord.Columns, BookmarkRecord.Read);
        ReadTable("saved_filters", SavedFilter.Columns, SavedFilter.Read);
        ReadTable("reading_progress", ReadingProgress.Columns, ReadingProgress.Read);
        ReadTable("recently_viewed", RecentlyViewed.Columns, RecentlyViewed.Read);
        ReadTable("saved_searches", SavedSearch.Columns, SavedSearch.Read);
        ReadTable("hidden_works", HiddenWork.Columns, HiddenWork.Read);
        ReadTable("subscriptions", SubscriptionRecord.Columns, SubscriptionRecord.Read);
        ReadTable("followed_authors", FollowedAuthor.Columns, FollowedAuthor.Read);
        ReadTable("reading_stats", ReadingStat.Columns, ReadingStat.Read);

        using (var cmd = _conn.CreateCommand())
        {
            cmd.CommandText = $"SELECT work_id, folder_id FROM {LibrarySchema.LinkTable}";
            using var r = cmd.ExecuteReader();
            while (r.Read())
            {
                var wid = r.GetInt64(0);
                var fid = r.GetInt64(1);
                if (worksById.TryGetValue(wid, out var w) && foldersById.TryGetValue(fid, out var f))
                {
                    w.Folders.Add(f);
                    _persistedLinks.Add((wid, fid));
                }
            }
        }

        // Snapshot rows only once every relationship is wired up.
        foreach (var list in _live.Values)
            foreach (var e in list) e.PersistedRow = e.ToRow();
    }

    private void ReadTable<T>(string table, string[] columns, Func<SqliteDataReader, T> read) where T : LibraryEntity
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = $"SELECT id, {string.Join(", ", columns)} FROM {table} ORDER BY id";
        using var r = cmd.ExecuteReader();
        var list = _live[typeof(T)];
        var unique = _unique[typeof(T)];
        while (r.Read())
        {
            var e = read(r);
            e.RowId = r.GetInt64(0);
            e.Store = this;
            if (e is Chapter c)
            {
                c.BodyLoaded = false;
                c.BodyDirty = false;
            }
            list.Add(e);
            if (e.UniqueKey is { } key) unique[key] = e;
            if (e.RowId > _lastId[typeof(T)]) _lastId[typeof(T)] = e.RowId;
        }
    }

    internal string LoadChapterBody(long rowId)
    {
        lock (_gate)
        {
            if (_disposed || rowId <= 0) return "";
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "SELECT body_html FROM chapters WHERE id = $id";
            cmd.Parameters.AddWithValue("$id", rowId);
            return cmd.ExecuteScalar() as string ?? "";
        }
    }

    // MARK: - Insert / delete

    /// <summary>Adds a record (and any chapters/folders reachable from it) to
    /// the store; it's written on the next <see cref="Save"/>. A stored record
    /// with the same unique key is replaced.</summary>
    public void Insert(LibraryEntity entity)
    {
        lock (_gate) Attach(entity);
    }

    private void Attach(LibraryEntity e)
    {
        if (ReferenceEquals(e.Store, this)) return;
        if (e.Store is not null) throw new InvalidOperationException("The record belongs to another library store.");
        var type = e.GetType();
        if (e.UniqueKey is { } key && _unique[type].TryGetValue(key, out var existing) && !ReferenceEquals(existing, e))
            DeleteCore(existing);
        e.RowId = ++_lastId[type];
        e.PersistedRow = null;
        e.Store = this;
        _live[type].Add(e);
        if (e.UniqueKey is { } k) _unique[type][k] = e;
        if (e is Chapter chapter) chapter.BodyDirty = true;

        // The related graph comes along, as SwiftData inserts it.
        switch (e)
        {
            case Work w:
                foreach (var ch in w.ChapterList.ToList()) Attach(ch);
                foreach (var f in w.Folders.ToList()) Attach(f);
                if (w.Folder is { } legacy) Attach(legacy);
                break;
            case Chapter { Work: { } owner }:
                Attach(owner);
                break;
            case CustomFolder folder:
                foreach (var w in folder.Works.ToList()) Attach(w);
                break;
        }
    }

    /// <summary>Removes a record; the row is deleted on the next <see cref="Save"/>.
    /// A work's chapters are deleted with it; folder links are just removed.</summary>
    public void Delete(LibraryEntity entity)
    {
        lock (_gate) DeleteCore(entity);
    }

    private void DeleteCore(LibraryEntity e)
    {
        if (!ReferenceEquals(e.Store, this)) return;
        var type = e.GetType();
        var table = LibrarySchema.Tables.First(t => t.Type == type);
        _live[type].Remove(e);
        if (e.UniqueKey is { } key && _unique[type].TryGetValue(key, out var mapped) && ReferenceEquals(mapped, e))
            _unique[type].Remove(key);
        if (e.PersistedRow is not null) _pendingDeletes.Add((table.Table, e.RowId, table.Kind));
        e.Store = null;
        e.PersistedRow = null;
        e.RowId = 0;

        switch (e)
        {
            case Work w:
                foreach (var ch in w.ChapterList.ToList())
                {
                    DeleteCore(ch);
                    ch.DetachFromWork();
                }
                w.Folders.Clear();
                break;
            case Chapter c:
                c.DetachFromWork();
                break;
            case CustomFolder f:
                f.Works.Clear();
                foreach (var w in _live[typeof(Work)].Cast<Work>())
                    if (ReferenceEquals(w.Folder, f)) w.Folder = null;
                break;
        }
    }

    // MARK: - Queries

    /// <summary>Every live record of a type, in insertion order (a snapshot).</summary>
    public IReadOnlyList<T> All<T>() where T : LibraryEntity
    {
        lock (_gate) return _live[typeof(T)].Cast<T>().ToList();
    }

    /// <summary>The live records of a type matching <paramref name="predicate"/>.</summary>
    public IReadOnlyList<T> Where<T>(Func<T, bool> predicate) where T : LibraryEntity
    {
        lock (_gate) return _live[typeof(T)].Cast<T>().Where(predicate).ToList();
    }

    public int Count<T>() where T : LibraryEntity
    {
        lock (_gate) return _live[typeof(T)].Count;
    }

    private T? FindUnique<T>(object key) where T : LibraryEntity
    {
        lock (_gate) return _unique[typeof(T)].TryGetValue(key, out var e) ? (T)e : null;
    }

    public Work? GetWork(int ao3Id) => FindUnique<Work>(ao3Id);
    public ReadingProgress? GetReadingProgress(int ao3Id) => FindUnique<ReadingProgress>(ao3Id);
    public ReadingStat? GetReadingStat(int ao3Id) => FindUnique<ReadingStat>(ao3Id);
    public RecentlyViewed? GetRecentlyViewed(int ao3Id) => FindUnique<RecentlyViewed>(ao3Id);
    public HiddenWork? GetHiddenWork(int ao3Id) => FindUnique<HiddenWork>(ao3Id);
    public BookmarkRecord? GetBookmark(int ao3Id) => FindUnique<BookmarkRecord>(ao3Id);
    public SubscriptionRecord? GetSubscription(string key) => FindUnique<SubscriptionRecord>(key);
    public FollowedAuthor? GetFollowedAuthor(string username) => FindUnique<FollowedAuthor>(username);
    public CustomFolder? GetFolder(string name) => FindUnique<CustomFolder>(name);
    public SavedSearch? GetSavedSearch(string name) => FindUnique<SavedSearch>(name);
    public SavedFilter? GetSavedFilter(string name) => FindUnique<SavedFilter>(name);
    public TagRecord? GetTag(string name) => FindUnique<TagRecord>(name);

    public IReadOnlyList<Work> Works => All<Work>();
    public IReadOnlyList<Work> FollowedWorks() => Where<Work>(w => w.IsFollowed);
    public IReadOnlyList<Work> StarredWorks() => Where<Work>(w => w.IsStarred);
    public IReadOnlyList<Work> WorksInFolder(CustomFolder folder)
    {
        lock (_gate) return folder.Works.ToList();
    }
    public IReadOnlyList<CustomFolder> Folders() => All<CustomFolder>().OrderBy(f => f.Name, StringComparer.Ordinal).ToList();
    /// <summary>Recently viewed, newest first.</summary>
    public IReadOnlyList<RecentlyViewed> RecentlyViewedNewestFirst() =>
        All<RecentlyViewed>().OrderByDescending(r => r.ViewedAt).ToList();
    public IReadOnlyList<SubscriptionRecord> Subscriptions(string? kind = null) =>
        kind is null ? All<SubscriptionRecord>() : Where<SubscriptionRecord>(s => s.Kind == kind);
    public IReadOnlyList<Chapter> ChaptersOf(Work work)
    {
        lock (_gate) return work.ChapterList.OrderBy(c => c.Index).ToList();
    }

    /// <summary>Whether a <see cref="Save"/> would write anything.</summary>
    public bool HasChanges
    {
        get
        {
            lock (_gate)
            {
                if (_pendingDeletes.Count > 0) return true;
                foreach (var list in _live.Values)
                    foreach (var e in list)
                        if (e.PersistedRow is null || !RowEquals(e.PersistedRow, e.ToRow()) || e is Chapter { BodyDirty: true })
                            return true;
                return !CurrentLinks().SetEquals(_persistedLinks);
            }
        }
    }

    // MARK: - Save

    /// <summary>Writes every pending change in one transaction; throws (leaving
    /// the database as it was) if SQLite refuses. Raises <see cref="Changed"/>.</summary>
    public void Save()
    {
        LibraryEntityKinds changed;
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            AttachReachable();
            var writes = new List<(LibraryEntity Entity, object?[] Row, bool Insert, LibraryEntityKinds Kind, string Table, string[] Columns)>();
            var bodies = new List<Chapter>();
            foreach (var t in LibrarySchema.Tables)
            {
                foreach (var e in _live[t.Type])
                {
                    var row = e.ToRow();
                    if (e.PersistedRow is null) writes.Add((e, row, true, t.Kind, t.Table, t.Columns));
                    else if (!RowEquals(e.PersistedRow, row)) writes.Add((e, row, false, t.Kind, t.Table, t.Columns));
                    if (e is Chapter { BodyDirty: true } c) bodies.Add(c);
                }
            }
            var links = CurrentLinks();
            var addedLinks = links.Where(l => !_persistedLinks.Contains(l)).ToList();
            var removedLinks = _persistedLinks.Where(l => !links.Contains(l)).ToList();
            if (_pendingDeletes.Count == 0 && writes.Count == 0 && bodies.Count == 0 && addedLinks.Count == 0 && removedLinks.Count == 0)
                return;

            changed = LibraryEntityKinds.None;
            using (var tx = _conn.BeginTransaction())
            {
                try
                {
                    foreach (var (table, id, kind) in _pendingDeletes)
                    {
                        Execute($"DELETE FROM {table} WHERE id = $id", ("$id", id));
                        if (table == "works") Execute($"DELETE FROM {LibrarySchema.LinkTable} WHERE work_id = $id", ("$id", id));
                        if (table == "custom_folders") Execute($"DELETE FROM {LibrarySchema.LinkTable} WHERE folder_id = $id", ("$id", id));
                        changed |= kind;
                    }
                    foreach (var w in writes)
                    {
                        WriteRow(w.Table, w.Columns, w.Entity.RowId, w.Row, w.Insert);
                        changed |= w.Kind;
                    }
                    foreach (var c in bodies)
                    {
                        Execute("UPDATE chapters SET body_html = $b WHERE id = $id", ("$b", c.BodyHtml), ("$id", c.RowId));
                        changed |= LibraryEntityKinds.Chapters;
                    }
                    foreach (var (wid, fid) in removedLinks)
                        Execute($"DELETE FROM {LibrarySchema.LinkTable} WHERE work_id = $w AND folder_id = $f", ("$w", wid), ("$f", fid));
                    foreach (var (wid, fid) in addedLinks)
                        Execute($"INSERT OR IGNORE INTO {LibrarySchema.LinkTable} (work_id, folder_id) VALUES ($w, $f)", ("$w", wid), ("$f", fid));
                    if (addedLinks.Count > 0 || removedLinks.Count > 0) changed |= LibraryEntityKinds.Folders | LibraryEntityKinds.Works;
                    tx.Commit();
                }
                catch
                {
                    tx.Rollback();
                    throw;
                }
            }

            _pendingDeletes.Clear();
            foreach (var w in writes) w.Entity.PersistedRow = w.Row;
            foreach (var c in bodies) c.BodyDirty = false;
            _persistedLinks = links;
        }
        if (changed != LibraryEntityKinds.None) Changed?.Invoke(changed);
    }

    /// <summary><see cref="Save"/> that reports failure instead of throwing —
    /// Swift's <c>try? context.save()</c>.</summary>
    public bool TrySave()
    {
        try
        {
            Save();
            return true;
        }
        catch (Exception e) when (e is SqliteException or InvalidOperationException)
        {
            return false;
        }
    }

    /// <summary>Inserts chapters and folders reachable from live records that
    /// were never inserted themselves (SwiftData inserts the related graph).</summary>
    private void AttachReachable()
    {
        foreach (var w in _live[typeof(Work)].Cast<Work>().ToList())
        {
            foreach (var ch in w.ChapterList.ToList()) Attach(ch);
            foreach (var f in w.Folders.ToList()) Attach(f);
            if (w.Folder is { } legacy) Attach(legacy);
        }
        foreach (var c in _live[typeof(Chapter)].Cast<Chapter>().ToList())
            if (c.Work is { } owner) Attach(owner);
        foreach (var f in _live[typeof(CustomFolder)].Cast<CustomFolder>().ToList())
            foreach (var w in f.Works.ToList()) Attach(w);
    }

    private HashSet<(long, long)> CurrentLinks()
    {
        var links = new HashSet<(long, long)>();
        foreach (var w in _live[typeof(Work)].Cast<Work>())
            foreach (var f in w.Folders)
                if (ReferenceEquals(f.Store, this)) links.Add((w.RowId, f.RowId));
        return links;
    }

    private void WriteRow(string table, string[] columns, long id, object?[] row, bool insert)
    {
        using var cmd = _conn.CreateCommand();
        if (insert)
        {
            cmd.CommandText = $"INSERT INTO {table} (id, {string.Join(", ", columns)}) VALUES ($id, {string.Join(", ", columns.Select((_, i) => "$p" + i))})";
        }
        else
        {
            cmd.CommandText = $"UPDATE {table} SET {string.Join(", ", columns.Select((c, i) => $"{c} = $p{i}"))} WHERE id = $id";
        }
        cmd.Parameters.AddWithValue("$id", id);
        for (var i = 0; i < row.Length; i++) cmd.Parameters.AddWithValue("$p" + i, row[i] ?? DBNull.Value);
        cmd.ExecuteNonQuery();
    }

    private void Execute(string sql, params (string Name, object Value)[] parameters)
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = sql;
        foreach (var (name, value) in parameters) cmd.Parameters.AddWithValue(name, value);
        cmd.ExecuteNonQuery();
    }

    private static bool RowEquals(object?[] a, object?[] b)
    {
        if (a.Length != b.Length) return false;
        for (var i = 0; i < a.Length; i++)
            if (!Equals(a[i], b[i])) return false;
        return true;
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            _conn.Dispose();
        }
    }
}
