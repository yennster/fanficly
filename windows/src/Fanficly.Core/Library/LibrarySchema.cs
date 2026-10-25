using Microsoft.Data.Sqlite;

namespace Fanficly.Core;

/// <summary>The library database's tables and their migrations.
///
/// Versioned with SQLite's <c>user_version</c>: <see cref="Migrations"/>[i]
/// takes a database from version i to i+1, each in its own transaction. Like
/// SwiftData's automatic migrations, changes should be <b>additive</b>: add a
/// table, or a column with a default (<see cref="AddColumnIfMissing"/>), and
/// add the column to the entity's <c>Columns</c>/<c>ToRow</c>/<c>Read</c>. An
/// older app version opening a newer database keeps working, because every
/// statement names its columns and every added column has a default.</summary>
internal static class LibrarySchema
{
    /// <summary>The tables in load/save order: folders before works (the
    /// legacy folder reference), works before chapters.</summary>
    internal static readonly (Type Type, string Table, string[] Columns, LibraryEntityKinds Kind)[] Tables =
    [
        (typeof(CustomFolder), "custom_folders", CustomFolder.Columns, LibraryEntityKinds.Folders),
        (typeof(Work), "works", Work.Columns, LibraryEntityKinds.Works),
        (typeof(Chapter), "chapters", Chapter.Columns, LibraryEntityKinds.Chapters),
        (typeof(TagRecord), "tags", TagRecord.Columns, LibraryEntityKinds.Tags),
        (typeof(BookmarkRecord), "bookmarks", BookmarkRecord.Columns, LibraryEntityKinds.Bookmarks),
        (typeof(SavedFilter), "saved_filters", SavedFilter.Columns, LibraryEntityKinds.SavedFilters),
        (typeof(ReadingProgress), "reading_progress", ReadingProgress.Columns, LibraryEntityKinds.ReadingProgress),
        (typeof(RecentlyViewed), "recently_viewed", RecentlyViewed.Columns, LibraryEntityKinds.RecentlyViewed),
        (typeof(SavedSearch), "saved_searches", SavedSearch.Columns, LibraryEntityKinds.SavedSearches),
        (typeof(HiddenWork), "hidden_works", HiddenWork.Columns, LibraryEntityKinds.HiddenWorks),
        (typeof(SubscriptionRecord), "subscriptions", SubscriptionRecord.Columns, LibraryEntityKinds.Subscriptions),
        (typeof(FollowedAuthor), "followed_authors", FollowedAuthor.Columns, LibraryEntityKinds.FollowedAuthors),
        (typeof(ReadingStat), "reading_stats", ReadingStat.Columns, LibraryEntityKinds.ReadingStats),
        (typeof(BlockedTerm), "blocked_terms", BlockedTerm.Columns, LibraryEntityKinds.BlockedTerms),
    ];

    internal const string LinkTable = "work_folders";

    /// <summary>Version 1: every SwiftData model as of the port.</summary>
    private static readonly string[] V1 =
    [
        """
        CREATE TABLE custom_folders (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            created_at INTEGER NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE works (
            id INTEGER PRIMARY KEY,
            ao3_id INTEGER NOT NULL UNIQUE,
            title TEXT NOT NULL DEFAULT '',
            author_name TEXT NOT NULL DEFAULT '',
            author_username TEXT NOT NULL DEFAULT '',
            summary TEXT NOT NULL DEFAULT '',
            rating TEXT NOT NULL DEFAULT '',
            warnings TEXT NOT NULL DEFAULT '[]',
            categories TEXT NOT NULL DEFAULT '[]',
            fandoms TEXT NOT NULL DEFAULT '[]',
            characters TEXT NOT NULL DEFAULT '[]',
            relationships TEXT NOT NULL DEFAULT '[]',
            freeforms TEXT NOT NULL DEFAULT '[]',
            language TEXT NOT NULL DEFAULT '',
            word_count INTEGER NOT NULL DEFAULT 0,
            chapter_count INTEGER NOT NULL DEFAULT 1,
            total_chapters INTEGER,
            kudos INTEGER NOT NULL DEFAULT 0,
            hits INTEGER NOT NULL DEFAULT 0,
            bookmarks_count INTEGER NOT NULL DEFAULT 0,
            comments_count INTEGER NOT NULL DEFAULT 0,
            is_complete INTEGER NOT NULL DEFAULT 0,
            published_at INTEGER,
            updated_at INTEGER,
            saved_at INTEGER NOT NULL DEFAULT 0,
            last_read_at INTEGER,
            last_read_chapter INTEGER,
            last_read_progress REAL,
            epub_local_path TEXT,
            is_followed INTEGER NOT NULL DEFAULT 0,
            followed_at INTEGER,
            last_seen_chapter_count INTEGER,
            last_checked_at INTEGER,
            is_starred INTEGER NOT NULL DEFAULT 0,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            folder_id INTEGER)
        """,
        """
        CREATE TABLE chapters (
            id INTEGER PRIMARY KEY,
            work_id INTEGER,
            idx INTEGER NOT NULL DEFAULT 0,
            title TEXT NOT NULL DEFAULT '',
            body_html TEXT NOT NULL DEFAULT '',
            ao_id INTEGER)
        """,
        "CREATE INDEX chapters_work ON chapters(work_id)",
        """
        CREATE TABLE work_folders (
            work_id INTEGER NOT NULL,
            folder_id INTEGER NOT NULL,
            PRIMARY KEY (work_id, folder_id))
        """,
        """
        CREATE TABLE tags (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL DEFAULT '')
        """,
        """
        CREATE TABLE bookmarks (
            id INTEGER PRIMARY KEY,
            ao3_id INTEGER NOT NULL UNIQUE,
            work_ao3_id INTEGER NOT NULL DEFAULT 0,
            notes TEXT NOT NULL DEFAULT '',
            tags TEXT NOT NULL DEFAULT '[]',
            saved_at INTEGER NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE saved_filters (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            filters_json TEXT NOT NULL DEFAULT '',
            saved_at INTEGER NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE reading_progress (
            id INTEGER PRIMARY KEY,
            ao3_id INTEGER NOT NULL UNIQUE,
            chapter_index INTEGER NOT NULL DEFAULT 1,
            paragraph_index INTEGER NOT NULL DEFAULT 0,
            title TEXT NOT NULL DEFAULT '',
            author TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE recently_viewed (
            id INTEGER PRIMARY KEY,
            ao3_id INTEGER NOT NULL UNIQUE,
            title TEXT NOT NULL DEFAULT '',
            author TEXT NOT NULL DEFAULT '',
            fandom TEXT NOT NULL DEFAULT '',
            viewed_at INTEGER NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE saved_searches (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            prompt TEXT NOT NULL DEFAULT '',
            sort_column TEXT NOT NULL DEFAULT '_score',
            sort_direction TEXT NOT NULL DEFAULT 'desc',
            saved_at INTEGER NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE hidden_works (
            id INTEGER PRIMARY KEY,
            ao3_id INTEGER NOT NULL UNIQUE,
            title TEXT NOT NULL DEFAULT '',
            hidden_at INTEGER NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE subscriptions (
            id INTEGER PRIMARY KEY,
            key TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL DEFAULT '',
            display_name TEXT NOT NULL DEFAULT '',
            author_name TEXT NOT NULL DEFAULT '',
            last_seen_chapter_count INTEGER,
            last_checked_at INTEGER)
        """,
        """
        CREATE TABLE followed_authors (
            id INTEGER PRIMARY KEY,
            username TEXT NOT NULL UNIQUE,
            display_name TEXT NOT NULL DEFAULT '',
            followed_at INTEGER NOT NULL DEFAULT 0,
            last_checked_at INTEGER,
            known_work_ids TEXT NOT NULL DEFAULT '[]')
        """,
        """
        CREATE TABLE reading_stats (
            id INTEGER PRIMARY KEY,
            ao3_id INTEGER NOT NULL UNIQUE,
            title TEXT NOT NULL DEFAULT '',
            author TEXT NOT NULL DEFAULT '',
            fandoms TEXT NOT NULL DEFAULT '[]',
            categories TEXT NOT NULL DEFAULT '[]',
            relationships TEXT NOT NULL DEFAULT '[]',
            rating TEXT NOT NULL DEFAULT '',
            word_count INTEGER NOT NULL DEFAULT 0,
            first_read_at INTEGER NOT NULL DEFAULT 0,
            last_read_at INTEGER NOT NULL DEFAULT 0,
            total_seconds REAL NOT NULL DEFAULT 0,
            day_seconds TEXT NOT NULL DEFAULT '{}',
            max_progress REAL NOT NULL DEFAULT 0,
            work_is_complete INTEGER NOT NULL DEFAULT 0)
        """,
    ];

    /// <summary>Version 2: blocked tags and authors (RM-006's <c>BlockedTerm</c>).</summary>
    private static readonly string[] V2 =
    [
        """
        CREATE TABLE IF NOT EXISTS blocked_terms (
            id INTEGER PRIMARY KEY,
            key TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL DEFAULT '',
            value TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL DEFAULT 0)
        """,
    ];

    /// <summary>Each entry migrates from version <c>index</c> to <c>index + 1</c>.
    /// Append only; never edit a shipped entry.</summary>
    internal static readonly Action<SqliteConnection>[] Migrations =
    [
        conn => Exec(conn, V1),
        conn => Exec(conn, V2),
    ];

    internal static int CurrentVersion => Migrations.Length;

    internal static void Migrate(SqliteConnection conn)
    {
        var version = UserVersion(conn);
        for (var v = version; v < Migrations.Length; v++)
        {
            using var tx = conn.BeginTransaction();
            Migrations[v](conn);
            using (var cmd = conn.CreateCommand())
            {
                cmd.CommandText = $"PRAGMA user_version = {v + 1}";
                cmd.ExecuteNonQuery();
            }
            tx.Commit();
        }
    }

    internal static int UserVersion(SqliteConnection conn)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "PRAGMA user_version";
        return Convert.ToInt32(cmd.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture);
    }

    /// <summary>The additive-migration building block: adds a column (whose
    /// definition must carry a DEFAULT or allow NULL) unless it already exists.</summary>
    internal static void AddColumnIfMissing(SqliteConnection conn, string table, string column, string definition)
    {
        using (var check = conn.CreateCommand())
        {
            check.CommandText = $"SELECT COUNT(*) FROM pragma_table_info('{table}') WHERE name = $c";
            check.Parameters.AddWithValue("$c", column);
            if (Convert.ToInt64(check.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) > 0) return;
        }
        Exec(conn, [$"ALTER TABLE {table} ADD COLUMN {column} {definition}"]);
    }

    private static void Exec(SqliteConnection conn, string[] statements)
    {
        foreach (var sql in statements)
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = sql;
            cmd.ExecuteNonQuery();
        }
    }
}
