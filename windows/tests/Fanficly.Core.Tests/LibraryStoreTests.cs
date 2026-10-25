using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>The SQLite-backed store itself: persistence across reopen, lazy
/// chapter bodies, relationships, unique keys, change notifications and the
/// schema version.</summary>
public sealed class LibraryStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"fanficly_store_{Guid.NewGuid()}");

    private string DbPath => Path.Combine(_dir, "library.sqlite");

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    [Fact]
    public void EveryFieldSurvivesReopening()
    {
        var saved = new DateTimeOffset(2026, 5, 4, 3, 2, 1, 123, TimeSpan.FromHours(-7));
        using (var store = LibraryStore.Open(DbPath))
        {
            var folder = new CustomFolder("Faves", saved);
            var legacy = new CustomFolder("Legacy", saved);
            var work = new Work(1, "Title", "Author", summary: "S", rating: "Teen", warnings: ["W"], categories: ["F/M"],
                                fandoms: ["F"], characters: ["C"], relationships: ["R"], freeforms: ["Fluff", "Angst"],
                                language: "English", wordCount: 1234, chapterCount: 3, totalChapters: 5, kudos: 7, hits: 8,
                                bookmarksCount: 9, commentsCount: 10, isComplete: true, publishedAt: saved, updatedAt: saved,
                                savedAt: saved)
            {
                AuthorUsername = "auth",
                LastReadAt = saved,
                LastReadChapter = 2,
                LastReadProgress = 0.5,
                EpubLocalPath = "library/1.epub",
                IsFollowed = true,
                FollowedAt = saved,
                LastSeenChapterCount = 3,
                LastCheckedAt = saved,
                IsStarred = true,
                IsPinned = true,
                Folder = legacy,
            };
            store.Insert(work);
            work.Folders.Add(folder);
            store.Insert(new Chapter(work, 1, "One", "<p>first</p>", 900));
            store.Insert(new Chapter(work, 2, "Two", "<p>second</p>"));
            store.Insert(new TagRecord("Fluff", "freeform"));
            store.Insert(new BookmarkRecord(5, 1, "note", ["t1"], saved));
            store.Insert(new SavedFilter("F", "{}", saved));
            store.Insert(new ReadingProgress(1, 2, 7, "Title", "Author", saved));
            store.Insert(new RecentlyViewed(1, "Title", "Author", "Harry Potter - J. K. Rowling", saved));
            store.Insert(new SavedSearch("S", "prompt", "kudos_count", "asc", saved));
            store.Insert(new HiddenWork(6, "Hidden", saved));
            store.Insert(new SubscriptionRecord("work:1", "work", "Title", "Author") { LastSeenChapterCount = 3, LastCheckedAt = saved });
            store.Insert(new FollowedAuthor("auth", "Auth", saved, saved, [1, 2]));
            store.Insert(new ReadingStat(1, "Title", "Author", ["F"], ["F/M"], ["R"], "Teen", 1234, saved, saved, 60,
                                         new Dictionary<string, double> { ["2026-05-04"] = 60 }, 0.5, true));
            store.Save();
        }

        using (var store = LibraryStore.Open(DbPath))
        {
            var work = Assert.Single(store.All<Work>());
            Assert.Equal(("Title", "Author", "auth", "S", "Teen"), (work.Title, work.AuthorName, work.AuthorUsername, work.Summary, work.Rating));
            Assert.Equal(["Fluff", "Angst"], work.Freeforms);
            Assert.Equal(["W"], work.Warnings);
            Assert.Equal((1234, 3, 5, 7, 8, 9, 10), (work.WordCount, work.ChapterCount, work.TotalChapters!.Value, work.Kudos, work.Hits, work.BookmarksCount, work.CommentsCount));
            Assert.True(work.IsComplete && work.IsFollowed && work.IsStarred && work.IsPinned);
            Assert.Equal(saved, work.SavedAt);
            Assert.Equal(saved, work.PublishedAt);
            Assert.Equal(saved, work.LastCheckedAt);
            Assert.Equal(0.5, work.LastReadProgress);
            Assert.Equal("library/1.epub", work.EpubLocalPath);
            Assert.Equal("Legacy", work.Folder?.Name);
            Assert.Equal(["Faves"], work.Folders.Select(f => f.Name));
            Assert.Equal(["One", "Two"], store.ChaptersOf(work).Select(c => c.Title));
            Assert.Equal(900, store.ChaptersOf(work)[0].AoId);
            Assert.Equal("<p>second</p>", store.ChaptersOf(work)[1].BodyHtml);
            Assert.Equal("freeform", store.GetTag("Fluff")?.Kind);
            Assert.Equal(["t1"], store.GetBookmark(5)!.Tags);
            Assert.Equal("{}", store.GetSavedFilter("F")?.FiltersJson);
            Assert.Equal(7, store.GetReadingProgress(1)?.ParagraphIndex);
            Assert.Equal("Harry Potter", store.GetRecentlyViewed(1)?.FandomShort);
            Assert.Equal("asc", store.GetSavedSearch("S")?.SortDirection);
            Assert.Equal("Hidden", store.GetHiddenWork(6)?.Title);
            Assert.Equal(3, store.GetSubscription("work:1")?.LastSeenChapterCount);
            Assert.Equal([1, 2], store.GetFollowedAuthor("auth")!.KnownWorkIds);
            var stat = store.GetReadingStat(1)!;
            Assert.Equal(60, stat.DaySeconds["2026-05-04"]);
            Assert.True(stat.WorkIsComplete);
            Assert.Equal(0.5, stat.MaxProgress);
            Assert.False(store.HasChanges);
        }
    }

    [Fact]
    public void ChapterBodiesLoadLazilyAndUpdatesPersist()
    {
        using (var store = LibraryStore.Open(DbPath))
        {
            var work = new Work(1, "T", "A");
            store.Insert(work);
            store.Insert(new Chapter(work, 1, "One", new string('x', 100_000)));
            store.Save();
        }
        using (var store = LibraryStore.Open(DbPath))
        {
            var chapter = Assert.Single(store.All<Chapter>());
            Assert.False(chapter.BodyLoaded);
            Assert.Equal(100_000, chapter.BodyHtml.Length);
            Assert.True(chapter.BodyLoaded);
            Assert.False(store.HasChanges); // reading a body isn't a change
            chapter.BodyHtml = "<p>edited</p>";
            store.Save();
            chapter.UnloadBody();
            Assert.False(chapter.BodyLoaded);
            Assert.Equal("<p>edited</p>", chapter.BodyHtml);
        }
        using (var store = LibraryStore.Open(DbPath))
            Assert.Equal("<p>edited</p>", Assert.Single(store.All<Chapter>()).BodyHtml);
    }

    [Fact]
    public void DeletingAWorkCascadesChaptersAndUnlinksFolders()
    {
        using (var store = LibraryStore.Open(DbPath))
        {
            var folder = new CustomFolder("Faves");
            var work = new Work(1, "T", "A");
            store.Insert(work);
            work.Folders.Add(folder); // the folder is inserted with the work on save
            new Chapter(work, 1, "One", "<p>1</p>");
            store.Save();
            Assert.Equal(1, store.Count<CustomFolder>());
            Assert.Equal(1, store.Count<Chapter>());

            store.Delete(work);
            Assert.Empty(folder.Works);
            Assert.Equal(0, store.Count<Chapter>());
            store.Save();
        }
        using (var store = LibraryStore.Open(DbPath))
        {
            Assert.Equal(0, store.Count<Work>());
            Assert.Equal(0, store.Count<Chapter>());
            Assert.Empty(Assert.Single(store.All<CustomFolder>()).Works);
        }
    }

    [Fact]
    public void DeletingAFolderKeepsItsWorks()
    {
        using var store = LibraryStore.Open(DbPath);
        var folder = new CustomFolder("Faves");
        store.Insert(folder);
        var work = new Work(1, "T", "A") { Folder = folder };
        store.Insert(work);
        work.Folders.Add(folder);
        store.Save();

        store.Delete(folder);
        Assert.Empty(work.Folders);
        Assert.Null(work.Folder);
        store.Save();
        Assert.Equal(1, store.Count<Work>());
    }

    [Fact]
    public void InsertingADuplicateUniqueKeyReplacesTheRecord()
    {
        using (var store = LibraryStore.Open(DbPath))
        {
            store.Insert(new HiddenWork(1, "first"));
            store.Save();
            store.Insert(new HiddenWork(1, "second"));
            Assert.Equal("second", Assert.Single(store.All<HiddenWork>()).Title);
            store.Save();
        }
        using (var store = LibraryStore.Open(DbPath))
            Assert.Equal("second", Assert.Single(store.All<HiddenWork>()).Title);
    }

    [Fact]
    public void RowsAnotherProcessWroteDontBlockLaterSaves()
    {
        // Two stores on one file stand in for the app and its background task
        // (or a second copy of the app): both count new row ids from the same
        // starting point.
        Directory.CreateDirectory(_dir);
        using (var mine = LibraryStore.Open(DbPath))
        using (var other = LibraryStore.Open(DbPath))
        {
            other.Insert(new FollowedAuthor("first", "First"));
            other.Save();
            mine.Insert(new FollowedAuthor("second", "Second"));
            mine.Save();
            mine.Insert(new FollowedAuthor("third", "Third"));
            mine.Save();
        }
        using (var store = LibraryStore.Open(DbPath))
            Assert.Equal(["first", "second", "third"], store.All<FollowedAuthor>().Select(a => a.Username).Order());
    }

    [Fact]
    public void AKeyAnotherProcessSavedDoesntBlockLaterSaves()
    {
        // The background task saves a subscription after the app loaded its
        // library; the app's own poll then inserts the same key. The app's
        // record replaces the task's row, and later saves still go through.
        Directory.CreateDirectory(_dir);
        var failures = new List<string>();
        var saveFailed = LibraryHooks.SaveFailed;
        LibraryHooks.SaveFailed = failures.Add;
        try
        {
            using (var app = LibraryStore.Open(DbPath))
            {
                using (var task = LibraryStore.Open(DbPath))
                {
                    task.Insert(new SubscriptionRecord("work:7", "work", "From the task") { LastSeenChapterCount = 3 });
                    task.Save();
                }
                app.Insert(new SubscriptionRecord("work:7", "work", "From the app") { LastSeenChapterCount = 4 });
                Assert.True(app.TrySave());
                app.Insert(new FollowedAuthor("later", "Later"));
                Assert.True(app.TrySave());
                Assert.False(app.HasChanges);
                app.GetSubscription("work:7")!.DisplayName = "Renamed";
                Assert.True(app.TrySave());
            }
            Assert.Empty(failures);
            using var reopened = LibraryStore.Open(DbPath);
            var sub = Assert.Single(reopened.All<SubscriptionRecord>());
            Assert.Equal(("Renamed", 4), (sub.DisplayName, sub.LastSeenChapterCount));
            Assert.Equal("later", Assert.Single(reopened.All<FollowedAuthor>()).Username);
        }
        finally
        {
            LibraryHooks.SaveFailed = saveFailed;
        }
    }

    [Fact]
    public void AWorkAnotherProcessSavedIsReplacedWithItsChaptersAndFolderLinks()
    {
        Directory.CreateDirectory(_dir);
        using (var app = LibraryStore.Open(DbPath))
        {
            using (var other = LibraryStore.Open(DbPath))
            {
                var theirs = new Work(5, "Theirs", "A");
                other.Insert(theirs);
                other.Insert(new Chapter(theirs, 1, "Old", "<p>old</p>"));
                theirs.Folders.Add(new CustomFolder("Shelf"));
                other.Save();
            }
            var mine = new Work(5, "Mine", "A");
            app.Insert(mine);
            app.Insert(new Chapter(mine, 1, "New", "<p>new</p>"));
            app.Save();
        }
        using var store = LibraryStore.Open(DbPath);
        var work = Assert.Single(store.Works);
        Assert.Equal("Mine", work.Title);
        Assert.Equal("New", Assert.Single(store.All<Chapter>()).Title);
        Assert.Empty(work.Folders);
        Assert.Equal("Shelf", Assert.Single(store.Folders()).Name);
    }

    [Fact]
    public void ADeletedAndReinsertedKeyStillSaves()
    {
        // The store's own row with the key is deleted in the same save, before
        // the insert, so it isn't mistaken for another process's row.
        Directory.CreateDirectory(_dir);
        using (var store = LibraryStore.Open(DbPath))
        {
            store.Insert(new HiddenWork(9, "First"));
            store.Save();
            store.Insert(new HiddenWork(9, "Second"));
            store.Save();
        }
        using (var store = LibraryStore.Open(DbPath))
            Assert.Equal("Second", Assert.Single(store.All<HiddenWork>()).Title);
    }

    [Fact]
    public void EveryUniqueKeyIsItsTablesFirstColumn()
    {
        // Save finds another process's row for a new record's key by the
        // table's first column.
        using var store = LibraryStore.Open(DbPath);
        using var conn = new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={DbPath}");
        conn.Open();
        foreach (var t in LibrarySchema.Tables)
        {
            if (t.Type == typeof(Chapter)) continue;
            using var cmd = conn.CreateCommand();
            cmd.CommandText = $"SELECT COUNT(*) FROM pragma_index_list('{t.Table}') l JOIN pragma_index_info(l.name) i WHERE l.\"unique\" = 1 AND i.name = '{t.Columns[0]}'";
            Assert.True((long)cmd.ExecuteScalar()! == 1, $"{t.Table}.{t.Columns[0]} isn't UNIQUE");
        }
    }

    [Fact]
    public void QueriesSeeUnsavedInsertsAndDeletes()
    {
        using var store = LibraryStore.OpenInMemory();
        var w = new Work(1, "T", "A") { IsStarred = true };
        store.Insert(w);
        Assert.Same(w, store.GetWork(1));
        Assert.Single(store.StarredWorks());
        store.Delete(w);
        Assert.Null(store.GetWork(1));
        Assert.False(w.IsInserted);
        Assert.False(store.HasChanges); // inserted and deleted before any save
    }

    [Fact]
    public void ChangedReportsTheKindsSaved()
    {
        using var store = LibraryStore.OpenInMemory();
        var events = new List<LibraryEntityKinds>();
        store.Changed += events.Add;

        store.Insert(new Work(1, "T", "A"));
        store.Insert(new ReadingProgress(1));
        store.Save();
        Assert.Equal(LibraryEntityKinds.Works | LibraryEntityKinds.ReadingProgress, events.Single());

        store.Save(); // nothing to write → no event
        Assert.Single(events);

        store.GetReadingProgress(1)!.ParagraphIndex = 4;
        store.Save();
        Assert.Equal(LibraryEntityKinds.ReadingProgress, events[^1]);

        var folder = new CustomFolder("F");
        store.Insert(folder);
        store.Save();
        store.GetWork(1)!.Folders.Add(folder);
        store.Save();
        Assert.Equal(LibraryEntityKinds.Works | LibraryEntityKinds.Folders, events[^1]);
    }

    [Fact]
    public void PropertyChangesAreObservable()
    {
        var work = new Work(1, "T", "A");
        var changed = new List<string?>();
        work.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        work.IsStarred = true;
        work.IsStarred = true; // unchanged → no event
        work.Title = "New";
        Assert.Equal([nameof(Work.IsStarred), nameof(Work.Title)], changed);
    }

    [Fact]
    public void NoteAndPersonalTagsSurviveReopening()
    {
        using (var store = LibraryStore.Open(DbPath))
        {
            store.Insert(new Work(1, "T", "A")
            {
                Note = "Comfort read",
                PersonalTags = ["for a bad day", "reread at Christmas"],
                NotesUpdatedAt = new DateTimeOffset(2026, 5, 4, 3, 2, 1, TimeSpan.Zero),
            });
            store.Insert(new Work(2, "U", "A"));
            store.Save();
        }
        using (var store = LibraryStore.Open(DbPath))
        {
            var noted = store.All<Work>().Single(w => w.Ao3Id == 1);
            Assert.Equal("Comfort read", noted.Note);
            Assert.Equal(["for a bad day", "reread at Christmas"], noted.PersonalTags);
            Assert.Equal(new DateTimeOffset(2026, 5, 4, 3, 2, 1, TimeSpan.Zero), noted.NotesUpdatedAt);
            var plain = store.All<Work>().Single(w => w.Ao3Id == 2);
            Assert.Null(plain.Note);
            Assert.Empty(plain.PersonalTags);
        }
    }

    /// <summary>A library from before notes (schema version 1) gains the note
    /// columns on open and keeps its works.</summary>
    [Fact]
    public void VersionOneLibraryMigratesToNotes()
    {
        using (var store = LibraryStore.Open(DbPath))
        {
            store.Insert(new Work(1, "T", "A"));
            store.Save();
        }
        using (var conn = new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={DbPath};Pooling=False"))
        {
            conn.Open();
            foreach (var sql in new[] { "ALTER TABLE works DROP COLUMN note", "ALTER TABLE works DROP COLUMN personal_tags",
                                       "ALTER TABLE works DROP COLUMN notes_updated_at", "PRAGMA user_version = 1" })
            {
                using var cmd = conn.CreateCommand();
                cmd.CommandText = sql;
                cmd.ExecuteNonQuery();
            }
        }
        using (var store = LibraryStore.Open(DbPath))
        {
            Assert.Equal(LibrarySchema.CurrentVersion, store.SchemaVersion);
            var work = Assert.Single(store.All<Work>());
            Assert.Null(work.Note);
            Assert.Empty(work.PersonalTags);
            work.SetNotes("now", "tagged");
            store.Save();
        }
        using (var store = LibraryStore.Open(DbPath))
            Assert.Equal("now", Assert.Single(store.All<Work>()).Note);
    }

    [Fact]
    public void SchemaIsVersionedAndMigrationsAreAdditive()
    {
        using (var store = LibraryStore.Open(DbPath))
            Assert.Equal(LibrarySchema.CurrentVersion, store.SchemaVersion);

        // A column a later version adds (with a default) doesn't disturb this one.
        using (var conn = new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={DbPath};Pooling=False"))
        {
            conn.Open();
            LibrarySchema.AddColumnIfMissing(conn, "works", "future_field", "TEXT NOT NULL DEFAULT ''");
            LibrarySchema.AddColumnIfMissing(conn, "works", "future_field", "TEXT NOT NULL DEFAULT ''"); // idempotent
        }
        using (var store = LibraryStore.Open(DbPath))
        {
            store.Insert(new Work(1, "T", "A"));
            store.Save();
            Assert.Equal(LibrarySchema.CurrentVersion, store.SchemaVersion);
        }
        using (var store = LibraryStore.Open(DbPath))
            Assert.Equal("T", Assert.Single(store.All<Work>()).Title);
    }

    [Fact]
    public async Task ConcurrentWritersDoNotCorruptTheStore()
    {
        using var store = LibraryStore.OpenInMemory();
        await Task.WhenAll(Enumerable.Range(0, 8).Select(t => Task.Run(() =>
        {
            for (var i = 0; i < 50; i++)
            {
                store.Insert(new RecentlyViewed(t * 1000 + i, "T"));
                store.Save();
                _ = store.RecentlyViewedNewestFirst();
            }
        })));
        Assert.Equal(400, store.Count<RecentlyViewed>());
        Assert.False(store.HasChanges);
    }

    [Fact]
    public void RecentlyViewedHelpersRemoveAndClear()
    {
        using var store = LibraryStore.OpenInMemory();
        WorkPersistence.RecordView(1, "One", "A", "F", store);
        WorkPersistence.RecordView(2, "Two", "A", "F", store);
        WorkPersistence.RemoveViews([store.GetRecentlyViewed(1)!], store);
        Assert.Equal([2], store.All<RecentlyViewed>().Select(r => r.Ao3Id));
        WorkPersistence.ClearRecentlyViewed(store);
        Assert.Equal(0, store.Count<RecentlyViewed>());
    }

    [Fact]
    public void FolderActions()
    {
        using var store = LibraryStore.OpenInMemory();
        var work = new Work(1, "T", "A");
        store.Insert(work);
        Assert.Null(WorkPersistence.CreateFolder("   ", store));
        var faves = WorkPersistence.CreateFolder("  Faves ", store, work)!;
        Assert.Equal("Faves", faves.Name);
        Assert.Null(WorkPersistence.CreateFolder("Faves", store)); // taken
        Assert.Equal([work], faves.Works);

        Assert.False(WorkPersistence.ToggleFolder(work, faves, store));
        Assert.True(WorkPersistence.ToggleFolder(work, faves, store));
        WorkPersistence.ClearFolders(work, store);
        Assert.Empty(work.Folders);
        Assert.True(WorkPersistence.ToggleStar(work, store));
        Assert.True(WorkPersistence.TogglePin(work, store));
        WorkPersistence.DeleteFolder(faves, store);
        Assert.Null(store.GetFolder("Faves"));
    }

    [Fact]
    public void DemoSeedIsDeterministicAndIdempotent()
    {
        AO3WorkSummary W(int id, string title) => new()
        {
            Id = id, Title = title, Author = "author", Fandoms = [$"Fandom {id}"], Categories = ["Gen"],
            Rating = "General Audiences", WordCount = 10_000, ChapterCount = 3, IsComplete = id % 2 == 0,
            UpdatedAt = DateTimeOffset.FromUnixTimeSeconds(1_779_000_000),
        };
        var catalog = new[] { 90001, 90002, 90003, 90004, 90005, 90006, 90007 }.Select(id => W(id, $"Work {id}")).ToList();
        var oldFolder = WorkPersistence.LibraryFolder;
        WorkPersistence.LibraryFolder = _dir;
        try
        {
            using var store = LibraryStore.OpenInMemory();
            DemoSeed.Seed(store, catalog);
            Assert.Equal(7, store.Count<Work>());
            Assert.Equal(3, store.FollowedWorks().Count);
            Assert.Equal(5, store.Count<FollowedAuthor>());
            Assert.Equal(90003, store.RecentlyViewedNewestFirst()[0].Ao3Id);
            Assert.Equal(7, store.Count<ReadingStat>());
            Assert.Equal(1.0, store.GetWork(90006)!.LastReadProgress);
            Assert.NotNull(WorkPersistence.EpubPath(90001));
            Assert.Equal(3, store.Count<SavedSearch>());
            Assert.Equal(2, store.Count<SavedFilter>());
            Assert.Equal(0.45, store.GetReadingStat(90001)!.MaxProgress);

            DemoSeed.Seed(store, catalog); // already seeded → no-op
            Assert.Equal(5, store.Count<FollowedAuthor>());
        }
        finally
        {
            WorkPersistence.LibraryFolder = oldFolder;
        }
    }
}
