using System.Collections.Concurrent;
using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Backup and restore read and change library records only on the
/// thread the UI uses them on, and do the merge and file IO elsewhere (#139).</summary>
public sealed class SyncThreadingTests : IDisposable
{
    private readonly List<string> _tempFiles = [];
    private readonly RecordsThread _ui = new();

    public void Dispose()
    {
        _ui.Dispose();
        foreach (var f in _tempFiles)
        {
            try { File.Delete(f); } catch (IOException) { }
        }
    }

    private string MakeTempBackupPath()
    {
        var path = Path.Combine(Path.GetTempPath(), $"test_backup_{Guid.NewGuid()}.json");
        _tempFiles.Add(path);
        _tempFiles.Add(LibrarySyncManager.PreviousBackupPath(path));
        return path;
    }

    private static AO3WorkPayload Payload(int id, int chapters)
    {
        var summary = new AO3WorkSummary
        {
            Id = id, Title = $"Test Work {id}", Author = "tester", Fandoms = ["Fandom"],
            WordCount = 5000, ChapterCount = chapters, TotalChapters = chapters, Language = "English", IsComplete = true,
        };
        var chs = Enumerable.Range(1, chapters).Select(i => new AO3ChapterPayload(i, $"Ch {i}", $"<p>Body {i}</p>")).ToList();
        return new AO3WorkPayload(summary, chs);
    }

    /// <summary>A sync manager whose records context is <see cref="_ui"/>,
    /// set on that thread as the app does.</summary>
    private Task<LibrarySyncManager> MakeSync(string path, IKeyValueStore settings) =>
        _ui.Run(() => new LibrarySyncManager(settings) { BackupPathOverride = path, RecordsContext = _ui });

    [Fact]
    public async Task RestoreChangesTheLibraryOnTheRecordsThread()
    {
        var path = MakeTempBackupPath();
        using (var other = LibraryStore.OpenInMemory())
        {
            WorkPersistence.Upsert(Payload(1, 2), other);
            WorkPersistence.CreateFolder("Faves", other, other.GetWork(1));
            Assert.Equal(BackupOutcome.Written, new LibrarySyncManager(new InMemoryKeyValueStore()) { BackupPathOverride = path }.Backup(other));
        }

        using var store = LibraryStore.OpenInMemory();
        var savedOn = new ConcurrentBag<int>();
        store.Changed += _ => savedOn.Add(Environment.CurrentManagedThreadId);
        var sync = await MakeSync(path, new InMemoryKeyValueStore());

        // Called from the test's thread, as a pool thread would.
        Assert.True(await Task.Run(() => sync.RestoreAsync(store)));

        Assert.Equal(["Faves"], store.GetWork(1)!.Folders.Select(f => f.Name));
        Assert.NotEmpty(savedOn);
        Assert.All(savedOn, id => Assert.Equal(_ui.ThreadId, id));
    }

    [Fact]
    public async Task QueuedBackupSnapshotsOnTheRecordsThread()
    {
        var path = MakeTempBackupPath();
        var settings = new InMemoryKeyValueStore();
        settings.SetBool(LibrarySyncManager.SyncEnabledKey, true);
        var sync = await MakeSync(path, settings);
        sync.BackupDebounce = TimeSpan.Zero;
        using var store = LibraryStore.OpenInMemory();
        var work = WorkPersistence.Upsert(Payload(1, 2), store);
        // A body left in the database is still backed up, read off that thread.
        foreach (var chapter in work.Chapters) chapter.UnloadBody();

        var postsBefore = _ui.Posts;
        sync.QueueBackup(store);
        for (var i = 0; i < 100 && sync.LastBackupOutcome is null; i++) await Task.Delay(20);

        Assert.Equal(BackupOutcome.Written, sync.LastBackupOutcome);
        Assert.True(_ui.Posts > postsBefore, "the snapshot was taken on the records thread");
        var backup = LibraryBackupJson.Decode(File.ReadAllBytes(path));
        Assert.Equal(["<p>Body 1</p>", "<p>Body 2</p>"], backup.Works.Single().Chapters.Select(c => c.BodyHtml));
    }

    /// <summary>Called on the records thread itself (Sync Now, closing), a
    /// backup takes its snapshot there and then, rather than waiting on a
    /// post it would itself have to run.</summary>
    [Fact]
    public async Task BackupOnTheRecordsThreadDoesntWaitForItself()
    {
        var path = MakeTempBackupPath();
        var sync = await MakeSync(path, new InMemoryKeyValueStore());
        using var store = LibraryStore.OpenInMemory();
        WorkPersistence.Upsert(Payload(1, 1), store);

        var outcome = await _ui.Run(() => sync.Backup(store)).WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(BackupOutcome.Written, outcome);
    }

    /// <summary>Snapshots are taken in order but may reach the file out of
    /// order; one older than what's written (or than a clear) is dropped,
    /// so it can't undo a newer change.</summary>
    [Fact]
    public void AnOlderSnapshotIsntWrittenOverANewerOne()
    {
        var path = MakeTempBackupPath();
        var sync = new LibrarySyncManager(new InMemoryKeyValueStore()) { BackupPathOverride = path };
        using var store = LibraryStore.OpenInMemory();
        var work = WorkPersistence.Upsert(Payload(1, 1), store);

        var older = sync.TakeSnapshot(store);
        work.IsStarred = true;
        store.Save();
        var newer = sync.TakeSnapshot(store);
        Assert.Equal(BackupOutcome.Written, sync.Write(store, newer));
        sync.Write(store, older);
        Assert.True(LibraryBackupJson.Decode(File.ReadAllBytes(path)).Works.Single().IsStarred);

        var beforeClear = sync.TakeSnapshot(store);
        Assert.Equal(ClearOutcome.Cleared, sync.Clear());
        sync.Write(store, beforeClear);
        Assert.False(File.Exists(path));

        Assert.Equal(BackupOutcome.Written, sync.Backup(store));
        Assert.True(File.Exists(path));
    }

    /// <summary>Chapter text left in the database is read when the backup is
    /// written; a chapter deleted in between is left out, not backed up
    /// empty over another device's copy.</summary>
    [Fact]
    public void AChapterDeletedAfterTheSnapshotIsntBackedUpEmpty()
    {
        var path = MakeTempBackupPath();
        var sync = new LibrarySyncManager(new InMemoryKeyValueStore()) { BackupPathOverride = path };
        using var store = LibraryStore.OpenInMemory();
        var work = WorkPersistence.Upsert(Payload(1, 2), store);
        foreach (var chapter in work.Chapters) chapter.UnloadBody();

        var snapshot = sync.TakeSnapshot(store);
        WorkPersistence.RemoveDownload(work, store);
        Assert.Equal(BackupOutcome.Written, sync.Write(store, snapshot));
        Assert.Empty(LibraryBackupJson.Decode(File.ReadAllBytes(path)).Works.Single().Chapters);
    }

    /// <summary>A single-threaded context standing in for the UI thread.</summary>
    private sealed class RecordsThread : SynchronizationContext, IDisposable
    {
        private readonly BlockingCollection<(SendOrPostCallback Callback, object? State)> _queue = new();
        private readonly Thread _thread;
        private int _posts;

        public RecordsThread()
        {
            _thread = new Thread(() =>
            {
                SetSynchronizationContext(this);
                foreach (var (callback, state) in _queue.GetConsumingEnumerable()) callback(state);
            }) { IsBackground = true };
            _thread.Start();
        }

        public int ThreadId => _thread.ManagedThreadId;
        public int Posts => Volatile.Read(ref _posts);

        public override void Post(SendOrPostCallback d, object? state)
        {
            Interlocked.Increment(ref _posts);
            _queue.Add((d, state));
        }

        public Task<T> Run<T>(Func<T> body)
        {
            var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
            Post(_ =>
            {
                try { done.SetResult(body()); }
                catch (Exception e) { done.SetException(e); }
            }, null);
            return done.Task;
        }

        public void Dispose() => _queue.CompleteAdding();
    }
}
