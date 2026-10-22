using System.Text.Json;

namespace Fanficly.Core;

/// <summary>Library backup/restore through a synced folder — the Windows port
/// of the Swift app's <c>iCloudSyncManager</c>. There's no iCloud container on
/// Windows, so the backup file <c>library_backup.json</c> lives in a folder the
/// user picks (OneDrive, iCloud Drive via iCloud for Windows, Dropbox, …).
/// Pointed at the Fanficly folder in iCloud Drive, a PC and an iPhone/Mac share
/// one backup: the JSON is the Swift app's format exactly.
///
/// <para>The rules that make that sharing safe are the Swift app's:</para>
/// <list type="bullet">
/// <item>Backup never writes a whole-file snapshot: it unions with the backup
/// already there (<see cref="MergedBackup"/>), so a device holding part of the
/// library can't last-writer-wins away another device's records.</item>
/// <item>Restore is a strictly forward merge (it runs automatically at launch):
/// reading positions apply only when newer, flags merge as an OR, folder
/// assignments union, the new-chapter baseline only advances, chapters are
/// replaced only by a fuller copy, stats merge conservatively.</item>
/// <item>A backup file that exists but can't be read yet (a cloud placeholder
/// still downloading, a file locked by the sync client) or can't be decoded (a
/// truncated file, a newer app's format) is skipped — the next queued backup
/// retries — rather than overwritten. Each write first keeps the file it
/// replaces as <c>library_backup.prev.json</c>.</item>
/// </list></summary>
public sealed class LibrarySyncManager
{
    public const string BackupFileName = "library_backup.json";
    /// <summary>Settings key: whether library sync is on (shared name with the Swift app).</summary>
    public const string SyncEnabledKey = "settings.iCloudSyncEnabled";
    /// <summary>Settings key: the backup file date this device last applied or wrote.</summary>
    public const string LastRestoredStampKey = "icloud.lastRestoredBackupDate";

    private readonly IKeyValueStore _settings;
    private readonly Lock _queueGate = new();
    private CancellationTokenSource? _pendingBackup;

    /// <summary>The app-wide instance (Swift's <c>iCloudSyncManager.shared</c>),
    /// which the library actions queue backups on. Null until the app sets it.</summary>
    public static LibrarySyncManager? Shared { get; set; }

    /// <summary>Queue a backup on <see cref="Shared"/> (refreshing the widget data
    /// either way) — what every library mutation calls.</summary>
    public static void QueueBackupShared(LibraryStore store)
    {
        if (Shared is { } manager) manager.QueueBackup(store);
        else LibraryHooks.UpdateWidgetData?.Invoke(store);
    }

    /// <summary>The settings <see cref="Shared"/> keeps its deletion markers
    /// in (the app-wide store until the app sets it).</summary>
    public static IKeyValueStore SharedSettings => Shared?._settings ?? KeyValueStores.Default;

    /// <summary>Remembers on this device that a record was deleted, so the next
    /// backup carries the deletion to the other devices (#135).</summary>
    public static void RecordDeletionShared(DeletionKind kind, string key) => SyncDeletions.Record(SharedSettings, kind, key);

    public static void RecordDeletionShared(DeletionKind kind, int ao3Id) => SyncDeletions.Record(SharedSettings, kind, ao3Id);

    /// <summary>This device's settings, where its deletion markers and removed
    /// downloads live.</summary>
    public IKeyValueStore Settings => _settings;

    public LibrarySyncManager(IKeyValueStore? settings = null)
    {
        _settings = settings ?? KeyValueStores.Default;
    }

    /// <summary>The folder the user picked for sync; null when none is set.</summary>
    public string? SyncFolder { get; set; }

    /// <summary>A full backup-file path that overrides <see cref="SyncFolder"/> (tests).</summary>
    public string? BackupPathOverride { get; set; }

    /// <summary>How long <see cref="QueueBackup"/> waits for more changes before backing up.</summary>
    public TimeSpan BackupDebounce { get; set; } = TimeSpan.FromSeconds(2);

    /// <summary>Merges reader-profile JSON (<c>ReaderProfile.mergedProfiles(localJSON:incomingJSON:)</c>):
    /// (local, incoming) → merged. Installed by the app; ported elsewhere.</summary>
    public Func<string?, string, string>? MergeReaderProfiles { get; set; }

    /// <summary>Pushes merged profiles to the synced key/value store
    /// (<c>ReaderProfileSyncStore.publishLocalProfiles</c>).</summary>
    public Action<string>? PublishReaderProfiles { get; set; }

    public string? BackupPath =>
        BackupPathOverride ?? (string.IsNullOrEmpty(SyncFolder) ? null : Path.Combine(SyncFolder, BackupFileName));

    /// <summary>Where the copy of the backup a write replaces is kept, beside
    /// it: <c>library_backup.prev.json</c>.</summary>
    internal static string PreviousBackupPath(string path) =>
        Path.Combine(Path.GetDirectoryName(path) ?? "",
            $"{Path.GetFileNameWithoutExtension(path)}.prev{Path.GetExtension(path)}");

    /// <summary>A Mac-synced iCloud folder can hold an undownloaded
    /// <c>.library_backup.json.icloud</c> placeholder instead of the file.</summary>
    private static string PlaceholderPath(string path) =>
        Path.Combine(Path.GetDirectoryName(path) ?? "", $".{Path.GetFileName(path)}.icloud");

    /// <summary>Whether a backup exists in the sync folder (downloaded or as a placeholder).</summary>
    public bool IsBackupAvailable =>
        BackupPath is { } path && (File.Exists(path) || File.Exists(PlaceholderPath(path)));

    /// <summary>The backup file's modification date.</summary>
    public DateTimeOffset? LastBackupDate
    {
        get
        {
            if (BackupPath is not { } path || !File.Exists(path)) return null;
            try { return new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
        }
    }

    public bool IsSyncEnabled => _settings.GetBool(SyncEnabledKey);

    /// <summary>Triggers a debounced backup (when sync is on). Always refreshes
    /// the widget data first.</summary>
    public void QueueBackup(LibraryStore store)
    {
        LibraryHooks.UpdateWidgetData?.Invoke(store);
        if (!IsSyncEnabled) return;

        CancellationTokenSource cts;
        lock (_queueGate)
        {
            _pendingBackup?.Cancel();
            cts = _pendingBackup = new CancellationTokenSource();
        }
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(BackupDebounce, cts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            if (cts.IsCancellationRequested) return;
            Backup(store);
        });
    }

    /// <summary>Backs the library up to the sync folder, merging with the
    /// backup already there so a device that holds only part of the library (a
    /// fresh install, a metadata-only laptop) can never last-writer-wins away
    /// another device's records. Says whether the file was written, so Back
    /// Up Now can report what really happened.</summary>
    public BackupOutcome Backup(LibraryStore store)
    {
        if (BackupPath is not { } path) return BackupOutcome.NoFolder;

        // A backup that exists only as a not-yet-downloaded placeholder can't
        // be merged with, and overwriting would drop every record the other
        // device backed up. Let a later QueueBackup (they fire on every
        // mutation) retry once it's local.
        if (!File.Exists(path) && File.Exists(PlaceholderPath(path))) return BackupOutcome.NotDownloaded;

        try
        {
            // 1–2. Snapshot the store into the backup shape.
            var backup = MakeLocalBackup(store);

            // 3. Union with the backup already there. A file that's present but
            // unreadable (still hydrating, locked by the sync client) is the
            // placeholder case: skip and retry later. So is a file that won't
            // decode (truncated, or a newer app's format): writing this
            // library alone over it would drop every other device's records,
            // and restore couldn't bring them back. Only a missing file
            // starts from the local snapshot alone. Note
            // whether that file held changes this device hasn't applied yet:
            // they go into the file, not into this library, so the file we
            // write isn't "applied here" until a restore pulls them in.
            var mergedUnappliedChanges = false;
            byte[]? mergedWith = null;
            if (File.Exists(path))
            {
                byte[] existing;
                try
                {
                    existing = File.ReadAllBytes(path);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    LibraryHooks.Log?.Invoke($"Backup skipped, the sync folder's backup is busy: {e.Message}");
                    return BackupOutcome.FileBusy;
                }
                LibraryBackup cloud;
                try
                {
                    cloud = LibraryBackupJson.Decode(existing);
                }
                catch (JsonException e)
                {
                    LibraryHooks.Log?.Invoke($"Backup skipped, the sync folder's backup can't be read: {e.Message}");
                    LastBackupError = e.Message;
                    return BackupOutcome.Unreadable;
                }
                mergedUnappliedChanges = CloudBackupHasUnappliedChanges;
                backup = MergedBackup(backup, cloud);
                mergedWith = existing;
            }

            // 4. Serialize, keeping the keys this app doesn't know from the file
            // it merged with (the Apple app's newer fields), and write atomically.
            var data = LibraryBackupJson.Encode(backup);
            if (mergedWith is not null) data = BackupUnknownKeys.Preserve(data, mergedWith);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var tmp = path + ".tmp";
            File.WriteAllBytes(tmp, data);
            // Keep the file this write replaces (it decoded above), so one bad
            // write can be undone by hand.
            if (File.Exists(path))
            {
                try { File.Copy(path, PreviousBackupPath(path), overwrite: true); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    LibraryHooks.Log?.Invoke($"Couldn't keep the previous backup: {e.Message}");
                }
            }
            File.Move(tmp, path, overwrite: true);
            // When everything in the file came from this library (or was
            // already applied here), stamp it so the launch auto-sync doesn't
            // re-restore our own backup. When we merged in another device's
            // unapplied records, leave the stamp alone: the next launch sees
            // the file as changed and restores them into this library.
            if (!mergedUnappliedChanges) MarkCloudBackupApplied();
            return BackupOutcome.Written;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            LibraryHooks.Log?.Invoke($"Failed to back up the library: {e.Message}");
            LastBackupError = e.Message;
            return BackupOutcome.Failed;
        }
    }

    /// <summary>Why the last backup that failed to write failed.</summary>
    public string? LastBackupError { get; private set; }

    /// <summary>A work as its backup record. Restore passes no chapters to merge
    /// a local work with the backup's copy by the backup's rules
    /// (<see cref="MergedWork"/>) without copying its chapter text.</summary>
    internal static WorkBackup ToBackup(Work work, IReadOnlyList<ChapterBackup> chapters) => new(
        Ao3Id: work.Ao3Id,
        Title: work.Title,
        AuthorName: work.AuthorName,
        AuthorUsername: work.AuthorUsername,
        Summary: work.Summary,
        Rating: work.Rating,
        Warnings: work.Warnings,
        Categories: work.Categories,
        Fandoms: work.Fandoms,
        Characters: work.Characters,
        Relationships: work.Relationships,
        Freeforms: work.Freeforms,
        Language: work.Language,
        WordCount: work.WordCount,
        ChapterCount: work.ChapterCount,
        TotalChapters: work.TotalChapters,
        Kudos: work.Kudos,
        Hits: work.Hits,
        BookmarksCount: work.BookmarksCount,
        CommentsCount: work.CommentsCount,
        IsComplete: work.IsComplete,
        PublishedAt: work.PublishedAt,
        UpdatedAt: work.UpdatedAt,
        SavedAt: work.SavedAt,
        LastReadAt: work.LastReadAt,
        LastReadChapter: work.LastReadChapter,
        LastReadProgress: work.LastReadProgress,
        IsFollowed: work.IsFollowed,
        FollowedAt: work.FollowedAt,
        LastSeenChapterCount: work.LastSeenChapterCount,
        IsStarred: work.IsStarred,
        IsPinned: work.IsPinned,
        Chapters: chapters,
        FolderName: work.Folders.FirstOrDefault()?.Name,
        FolderNames: work.Folders.Select(f => f.Name).ToList());

    /// <summary>The library as a backup, mapping every record type.</summary>
    internal LibraryBackup MakeLocalBackup(LibraryStore store)
    {
        var works = store.All<Work>().Select(work => ToBackup(work,
            store.ChaptersOf(work).Select(ch => new ChapterBackup(ch.Index, ch.Title, ch.BodyHtml, ch.AoId)).ToList())).ToList();

        return new LibraryBackup(
            Works: works,
            Bookmarks: store.All<BookmarkRecord>().Select(b => new BookmarkBackup(b.Ao3Id, b.WorkAo3Id, b.Notes, b.Tags, b.SavedAt)).ToList(),
            Subscriptions: store.All<SubscriptionRecord>().Select(s => new SubscriptionBackup(
                s.Key, s.Kind, s.DisplayName, s.AuthorName, s.LastSeenChapterCount, s.LastCheckedAt)).ToList(),
            Searches: store.All<SavedSearch>().Select(s => new SearchBackup(s.Name, s.Prompt, s.SortColumn, s.SortDirection, s.SavedAt)).ToList(),
            Progress: store.All<ReadingProgress>().Select(p => new ProgressBackup(
                p.Ao3Id, p.ChapterIndex, p.ParagraphIndex, p.Title, p.Author, p.UpdatedAt)).ToList(),
            Filters: store.All<SavedFilter>().Select(f => new FilterBackup(f.Name, f.FiltersJson, f.SavedAt)).ToList(),
            Hidden: store.All<HiddenWork>().Select(h => new HiddenBackup(h.Ao3Id, h.Title, h.HiddenAt)).ToList(),
            Settings: SettingsBackup.Capture(_settings),
            Folders: store.All<CustomFolder>().Select(f => new FolderBackup(f.Name, f.CreatedAt)).ToList(),
            Stats: store.All<ReadingStat>().Select(s => new StatBackup(
                s.Ao3Id, s.Title, s.Author, s.Fandoms, s.Categories, s.Relationships, s.Rating, s.WordCount,
                s.FirstReadAt, s.LastReadAt, s.TotalSeconds, s.DaySeconds, s.MaxProgress, s.WorkIsComplete)).ToList(),
            Timestamp: DateTimeOffset.Now,
            FollowedAuthors: store.All<FollowedAuthor>().Where(a => a.Username.Length > 0).Select(a => new AuthorBackup(
                a.Username, a.DisplayName, a.FollowedAt, a.KnownWorkIds, a.LastCheckedAt)).ToList(),
            Blocked: store.All<BlockedTerm>().Select(t => new BlockedBackup(t.Kind, t.Value, t.CreatedAt)).ToList(),
            Deleted: SyncDeletions.Pruned(SyncDeletions.Local(_settings), DateTimeOffset.Now) is { Count: > 0 } deleted ? deleted : null);
    }

    // MARK: - Launch auto-sync bookkeeping

    /// <summary>Whether the backup changed since this device last applied (or
    /// wrote) it — the launch auto-sync's cheap "anything new?" check. True when
    /// we can't tell (no stamp yet, or no readable date): restore is a
    /// conservative merge, so restoring once too often is safe; skipping a real
    /// change is not. Any date other than the stamp counts, not just a later
    /// one: sync apps keep the writing device's modification date, so a backup
    /// written offline (or on a PC whose clock runs behind) can arrive older
    /// than this device's last write.</summary>
    public bool CloudBackupHasUnappliedChanges
    {
        get
        {
            if (_settings.GetDate(LastRestoredStampKey) is not { } applied || LastBackupDate is not { } cloudDate) return true;
            return cloudDate != applied;
        }
    }

    /// <summary>Stamps <paramref name="date"/> (the file's modification date
    /// when it was read, or just after it was written) as applied here. A
    /// restore passes the date from before its read, so a file another device
    /// swaps in while the restore runs isn't marked applied unread.</summary>
    private void MarkCloudBackupApplied(DateTimeOffset? date = null) =>
        _settings.SetDate(LastRestoredStampKey, date ?? LastBackupDate ?? DateTimeOffset.Now);

    /// <summary>Unions a freshly-built local backup with the one already in the
    /// sync folder. Records only the other device holds are kept; on conflicts
    /// the local record wins (this device just produced it), except where a
    /// field only moves forward: works and subscriptions merge by the restore's
    /// rules (<see cref="MergedWork"/>, <see cref="MergedSubscription"/>),
    /// reading positions keep the newer one, and reading stats merge
    /// conservatively. Deletion markers from both sides are kept, and a work,
    /// hidden work, folder, saved search or filter that a newer marker covers
    /// is left out, so a delete doesn't come back from another device's copy
    /// (#135).</summary>
    public static LibraryBackup MergedBackup(LibraryBackup local, LibraryBackup cloud)
    {
        var worksById = FirstByKey(cloud.Works, w => w.Ao3Id);
        foreach (var w in local.Works)
        {
            if (!worksById.TryGetValue(w.Ao3Id, out var cloudWork)) { worksById[w.Ao3Id] = w; continue; }
            // Follow, star and pin keep this PC's values here (restore ORs them):
            // the file is the only record of an un-follow, and without an edit
            // stamp an OR would bring every un-followed work back on a restore.
            worksById[w.Ao3Id] = MergedWork(w, cloudWork) with
            {
                IsFollowed = w.IsFollowed, FollowedAt = w.FollowedAt, IsStarred = w.IsStarred, IsPinned = w.IsPinned,
            };
        }

        var bookmarksById = FirstByKey(cloud.Bookmarks, b => b.Ao3Id);
        foreach (var b in local.Bookmarks) bookmarksById[b.Ao3Id] = b;

        var subscriptionsByKey = FirstByKey(cloud.Subscriptions, s => s.Key);
        foreach (var s in local.Subscriptions)
            subscriptionsByKey[s.Key] = subscriptionsByKey.TryGetValue(s.Key, out var cloudSub) ? MergedSubscription(s, cloudSub) : s;

        var searchesByName = FirstByKey(cloud.Searches, s => s.Name);
        foreach (var s in local.Searches) searchesByName[s.Name] = s;

        var progressById = FirstByKey(cloud.Progress, p => p.Ao3Id);
        foreach (var p in local.Progress)
        {
            if (progressById.TryGetValue(p.Ao3Id, out var c) && c.UpdatedAt > p.UpdatedAt) continue;
            progressById[p.Ao3Id] = p;
        }

        var filtersByName = FirstByKey(cloud.Filters, f => f.Name);
        foreach (var f in local.Filters) filtersByName[f.Name] = f;

        var hiddenById = FirstByKey(cloud.Hidden, h => h.Ao3Id);
        foreach (var h in local.Hidden) hiddenById[h.Ao3Id] = h;

        var foldersByName = FirstByKey(cloud.Folders ?? [], f => f.Name);
        foreach (var f in local.Folders ?? []) foldersByName[f.Name] = f;

        var blockedByKey = FirstByKey(cloud.Blocked ?? [], b => b.Key);
        foreach (var b in local.Blocked ?? []) blockedByKey[b.Key] = b;

        var statsById = FirstByKey(cloud.Stats ?? [], s => s.Ao3Id);
        foreach (var s in local.Stats ?? [])
            statsById[s.Ao3Id] = statsById.TryGetValue(s.Ao3Id, out var c) ? MergedStat(s, c) : s;

        // Authors: local wins, but the works either device already knows are
        // kept, so neither alerts for a work the other has seen.
        var authorsByName = new Dictionary<string, AuthorBackup>(StringComparer.OrdinalIgnoreCase);
        foreach (var a in cloud.FollowedAuthors ?? []) authorsByName.TryAdd(a.Username, a);
        foreach (var a in local.FollowedAuthors ?? [])
            authorsByName[a.Username] = authorsByName.TryGetValue(a.Username, out var other)
                ? a with
                {
                    FollowedAt = a.FollowedAt < other.FollowedAt ? a.FollowedAt : other.FollowedAt,
                    KnownWorkIds = a.KnownWorkIds.Union(other.KnownWorkIds).ToList(),
                    LastCheckedAt = Later(a.LastCheckedAt, other.LastCheckedAt),
                }
                : a;

        // Deletion markers from both sides remove the records they're newer
        // than, whichever side still held them (#135).
        var deleted = SyncDeletions.Pruned((cloud.Deleted ?? []).Concat(local.Deleted ?? []), local.Timestamp);
        var tombstones = new DeletionIndex(deleted);

        return new LibraryBackup(
            Works: worksById.Values.Where(w => !tombstones.Removes(DeletionKind.Work, w.Ao3Id, w.SavedAt)).OrderBy(w => w.Ao3Id).ToList(),
            Bookmarks: bookmarksById.Values.OrderBy(b => b.Ao3Id).ToList(),
            Subscriptions: subscriptionsByKey.Values.OrderBy(s => s.Key, StringComparer.Ordinal).ToList(),
            Searches: searchesByName.Values.Where(s => !tombstones.Removes(DeletionKind.Search, s.Name, s.SavedAt))
                .OrderBy(s => s.Name, StringComparer.Ordinal).ToList(),
            Progress: progressById.Values.OrderBy(p => p.Ao3Id).ToList(),
            Filters: filtersByName.Values.Where(f => !tombstones.Removes(DeletionKind.Filter, f.Name, f.SavedAt))
                .OrderBy(f => f.Name, StringComparer.Ordinal).ToList(),
            Hidden: hiddenById.Values.Where(h => !tombstones.Removes(DeletionKind.Hidden, h.Ao3Id, h.HiddenAt)).OrderBy(h => h.Ao3Id).ToList(),
            Settings: local.Settings ?? cloud.Settings,
            Folders: foldersByName.Values.Where(f => !tombstones.Removes(DeletionKind.Folder, f.Name, f.CreatedAt))
                .OrderBy(f => f.Name, StringComparer.Ordinal).ToList(),
            Stats: statsById.Values.OrderBy(s => s.Ao3Id).ToList(),
            Timestamp: local.Timestamp,
            FollowedAuthors: local.FollowedAuthors is null && cloud.FollowedAuthors is null
                ? null
                : authorsByName.Values.OrderBy(a => a.Username, StringComparer.Ordinal).ToList(),
            Blocked: local.Blocked is null && cloud.Blocked is null
                ? null
                : blockedByKey.Values.OrderBy(b => b.Key, StringComparer.Ordinal).ToList(),
            Deleted: deleted.Count == 0 ? null : deleted);
    }

    /// <summary>Two copies of one work merged so nothing moves backwards,
    /// whichever device merges first: the backup merge passes this device's
    /// record as <paramref name="local"/> and the file's as
    /// <paramref name="other"/>, and restore passes this device's work and the
    /// backup's copy the same way. The Swift app's
    /// <c>iCloudSyncManager.mergedWork</c> applies the same rules:
    /// AO3 metadata (Title through UpdatedAt) comes whole from the fresher copy
    /// (<see cref="HasFresherMetadata"/>) and SavedAt keeps the later date; the
    /// reading position comes from the copy read last; follow, star and pin are
    /// an OR (FollowedAt keeps local's when set; the backup merge then puts
    /// local's flags back, see <see cref="MergedBackup"/>); LastSeenChapterCount keeps the
    /// higher count, so an older copy never re-announces chapters; chapters come
    /// from the copy with more, and folders union.</summary>
    public static WorkBackup MergedWork(WorkBackup local, WorkBackup other)
    {
        var meta = HasFresherMetadata(other, local) ? other : local;
        var position = (other.LastReadAt ?? DateTimeOffset.MinValue) > (local.LastReadAt ?? DateTimeOffset.MinValue) ? other : local;
        var localFolders = local.FolderNames ?? (local.FolderName is { } lf ? [lf] : []);
        var otherFolders = other.FolderNames ?? (other.FolderName is { } of ? [of] : []);
        var folders = localFolders.Concat(otherFolders.Where(f => !localFolders.Contains(f))).ToList();
        return meta with
        {
            Ao3Id = local.Ao3Id,
            SavedAt = local.SavedAt > other.SavedAt ? local.SavedAt : other.SavedAt,
            LastReadAt = position.LastReadAt,
            LastReadChapter = position.LastReadChapter,
            LastReadProgress = position.LastReadProgress,
            IsFollowed = local.IsFollowed || other.IsFollowed,
            FollowedAt = local.FollowedAt ?? other.FollowedAt,
            LastSeenChapterCount = Higher(local.LastSeenChapterCount, other.LastSeenChapterCount),
            IsStarred = (local.IsStarred ?? false) || (other.IsStarred ?? false),
            IsPinned = (local.IsPinned ?? false) || (other.IsPinned ?? false),
            Chapters = other.Chapters.Count > local.Chapters.Count ? other.Chapters : local.Chapters,
            FolderName = folders.FirstOrDefault(),
            FolderNames = folders,
        };
    }

    /// <summary>Whether <paramref name="other"/> carries newer AO3 metadata than
    /// <paramref name="local"/>: a later UpdatedAt (AO3's "Updated" date), then,
    /// on the same date, more chapters, then more hits (they only grow, so the
    /// copy fetched last has the most). A full tie keeps local.</summary>
    public static bool HasFresherMetadata(WorkBackup other, WorkBackup local)
    {
        var otherDate = other.UpdatedAt ?? DateTimeOffset.MinValue;
        var localDate = local.UpdatedAt ?? DateTimeOffset.MinValue;
        if (otherDate != localDate) return otherDate > localDate;
        if (other.ChapterCount != local.ChapterCount) return other.ChapterCount > local.ChapterCount;
        return other.Hits > local.Hits;
    }

    /// <summary>A subscription's two copies merged: the notification baseline
    /// keeps the higher count and LastCheckedAt the later date, so an older copy
    /// can't re-announce chapters or turn alerts off with a null baseline. Its
    /// kind and names come from <paramref name="local"/>.</summary>
    public static SubscriptionBackup MergedSubscription(SubscriptionBackup local, SubscriptionBackup other) =>
        local with
        {
            LastSeenChapterCount = Higher(local.LastSeenChapterCount, other.LastSeenChapterCount),
            LastCheckedAt = Later(local.LastCheckedAt, other.LastCheckedAt),
        };

    private static int? Higher(int? a, int? b) =>
        a is null ? b : b is null ? a : Math.Max(a.Value, b.Value);

    private static DateTimeOffset? Later(DateTimeOffset? a, DateTimeOffset? b) =>
        a is null ? b : b is null ? a : a > b ? a : b;

    /// <summary>Dictionary keyed by <paramref name="key"/>, keeping the first of
    /// any duplicates (Swift's <c>uniquingKeysWith: { a, _ in a }</c>).</summary>
    private static Dictionary<TKey, T> FirstByKey<TKey, T>(IEnumerable<T> items, Func<T, TKey> key) where TKey : notnull
    {
        var d = new Dictionary<TKey, T>();
        foreach (var item in items) d.TryAdd(key(item), item);
        return d;
    }

    /// <summary>The conservative per-stat merge restore applies too: max of
    /// totals and per-day buckets, widest date span, non-empty metadata wins —
    /// and TotalSeconds lifted to at least Σ DaySeconds, because per-day maxima
    /// from two devices can sum past either device's own total.</summary>
    public static StatBackup MergedStat(StatBackup local, StatBackup cloud)
    {
        var daySeconds = new Dictionary<string, double>(local.DaySeconds);
        foreach (var (day, seconds) in cloud.DaySeconds)
            daySeconds[day] = Math.Max(daySeconds.GetValueOrDefault(day), seconds);
        var totalSeconds = Math.Max(Math.Max(local.TotalSeconds, cloud.TotalSeconds), daySeconds.Values.Sum());
        return new StatBackup(
            Ao3Id: local.Ao3Id,
            Title: local.Title.Length == 0 ? cloud.Title : local.Title,
            Author: local.Author.Length == 0 ? cloud.Author : local.Author,
            Fandoms: local.Fandoms.Count == 0 ? cloud.Fandoms : local.Fandoms,
            Categories: local.Categories.Count == 0 ? cloud.Categories : local.Categories,
            Relationships: local.Relationships.Count == 0 ? cloud.Relationships : local.Relationships,
            Rating: local.Rating.Length == 0 ? cloud.Rating : local.Rating,
            WordCount: local.WordCount > 0 ? local.WordCount : cloud.WordCount,
            FirstReadAt: local.FirstReadAt < cloud.FirstReadAt ? local.FirstReadAt : cloud.FirstReadAt,
            LastReadAt: local.LastReadAt > cloud.LastReadAt ? local.LastReadAt : cloud.LastReadAt,
            TotalSeconds: totalSeconds,
            DaySeconds: daySeconds,
            MaxProgress: Math.Max(local.MaxProgress ?? 0, cloud.MaxProgress ?? 0),
            WorkIsComplete: local.WorkIsComplete == true || cloud.WorkIsComplete == true);
    }

    /// <summary>Settings → Sync → Sync Now (the Swift app's
    /// <c>iCloudSyncManager.syncNow</c>): first brings in what other devices
    /// backed up since this PC last applied the file (the same forward-only
    /// restore the launch runs), then backs up. Restoring first means the
    /// backup's merge finds nothing unapplied, so it stamps the file it
    /// writes.</summary>
    public async Task<SyncNowResult> SyncNowAsync(LibraryStore store, CancellationToken ct = default)
    {
        var restored = false;
        try
        {
            restored = IsBackupAvailable && CloudBackupHasUnappliedChanges && await RestoreAsync(store, ct);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            // Still back up this PC's changes; the stamp didn't move, so the
            // next launch or Sync Now tries the restore again.
            LibraryHooks.Log?.Invoke($"Sync Now's restore failed: {e.Message}");
        }
        return new SyncNowResult(restored, Backup(store));
    }

    // MARK: - Restore

    /// <summary>Restores every record from the backup as a strictly forward
    /// merge. Returns true on success. When the file is only a placeholder,
    /// waits up to 5 s for it to arrive.</summary>
    public async Task<bool> RestoreAsync(LibraryStore store, CancellationToken ct = default)
    {
        if (BackupPath is not { } path) return false;

        if (!File.Exists(path) && File.Exists(PlaceholderPath(path)))
        {
            var downloaded = false;
            for (var i = 0; i < 25; i++)
            {
                if (File.Exists(path))
                {
                    downloaded = true;
                    break;
                }
                try { await Task.Delay(200, ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { return false; }
            }
            if (!downloaded)
            {
                LibraryHooks.Log?.Invoke("Library backup download timed out");
                return false;
            }
        }

        if (!File.Exists(path)) return false;

        var readDate = LastBackupDate;
        try
        {
            var backup = LibraryBackupJson.Decode(await File.ReadAllBytesAsync(path, ct).ConfigureAwait(false));
            Apply(backup, store);
            store.Save();
            MarkCloudBackupApplied(readDate);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException
                                      or Microsoft.Data.Sqlite.SqliteException or OperationCanceledException)
        {
            LibraryHooks.Log?.Invoke($"Failed to restore the library: {e.Message}");
            return false;
        }
    }

    private void Apply(LibraryBackup backup, LibraryStore store)
    {
        // Deletion markers: the file's (every device's) and this device's own,
        // which the file may not hold yet. A record they cover isn't restored,
        // and this device's copy of it is deleted at the end (#135).
        var tombstones = new DeletionIndex(SyncDeletions.Pruned(
            (backup.Deleted ?? []).Concat(SyncDeletions.Local(_settings)), DateTimeOffset.Now));
        // Works whose download was removed on this device keep their chapters
        // out: another device's copy mustn't bring the download back.
        var removedDownloads = SyncDeletions.RemovedDownloads(_settings);

        // 0. Settings and themes.
        if (backup.Settings is { } s)
        {
            foreach (var field in SettingsBackup.Fields)
            {
                if (field.JsonKey == SettingsBackup.ProfilesJsonKey) continue;
                switch (field.Kind)
                {
                    case SettingKind.String when s.GetString(field.JsonKey) is { } str:
                        _settings.SetString(field.DefaultsKey, str);
                        break;
                    case SettingKind.Double when s.GetDouble(field.JsonKey) is { } d:
                        _settings.SetDouble(field.DefaultsKey, d);
                        break;
                    case SettingKind.Bool when s.GetBool(field.JsonKey) is { } b:
                        _settings.SetBool(field.DefaultsKey, b);
                        break;
                }
            }
            if (s.GetString(SettingsBackup.ProfilesJsonKey) is { } profiles)
            {
                var local = _settings.GetString(SettingsBackup.ProfilesDefaultsKey);
                // Without the profile merger installed, never clobber local profiles.
                var merged = MergeReaderProfiles?.Invoke(local, profiles) ?? (string.IsNullOrEmpty(local) ? profiles : local);
                _settings.SetString(SettingsBackup.ProfilesDefaultsKey, merged);
                PublishReaderProfiles?.Invoke(merged);
            }
        }

        // 0.5. Folders.
        foreach (var f in backup.Folders ?? [])
            if (!tombstones.Removes(DeletionKind.Folder, f.Name, f.CreatedAt) && store.GetFolder(f.Name) is null) store.Insert(new CustomFolder(f.Name, f.CreatedAt));

        // 1. Works and their chapters.
        foreach (var w in backup.Works)
        {
            if (tombstones.Removes(DeletionKind.Work, w.Ao3Id, w.SavedAt)) continue;
            // Merge with the local copy by the backup's rules (MergedWork), so a
            // background launch sync never rewinds this device to an older
            // backup: fresher AO3 metadata, the position read last, OR'd flags
            // and the higher notification baseline (regressing it would re-fire
            // "new chapter" alerts).
            var work = store.GetWork(w.Ao3Id);
            var m = w;
            if (work is null)
            {
                work = new Work(w.Ao3Id, w.Title, w.AuthorName);
                store.Insert(work);
            }
            else
            {
                m = MergedWork(ToBackup(work, []), w);
            }

            work.Title = m.Title;
            work.AuthorName = m.AuthorName;
            work.AuthorUsername = m.AuthorUsername;
            work.Summary = m.Summary;
            work.Rating = m.Rating;
            work.Warnings = m.Warnings;
            work.Categories = m.Categories;
            work.Fandoms = m.Fandoms;
            work.Characters = m.Characters;
            work.Relationships = m.Relationships;
            work.Freeforms = m.Freeforms;
            work.Language = m.Language;
            work.WordCount = m.WordCount;
            work.ChapterCount = m.ChapterCount;
            work.TotalChapters = m.TotalChapters;
            work.Kudos = m.Kudos;
            work.Hits = m.Hits;
            work.BookmarksCount = m.BookmarksCount;
            work.CommentsCount = m.CommentsCount;
            work.IsComplete = m.IsComplete;
            work.PublishedAt = m.PublishedAt;
            work.UpdatedAt = m.UpdatedAt;
            work.SavedAt = m.SavedAt;
            work.LastReadAt = m.LastReadAt;
            work.LastReadChapter = m.LastReadChapter;
            work.LastReadProgress = m.LastReadProgress;
            work.IsFollowed = m.IsFollowed;
            work.FollowedAt = m.FollowedAt;
            work.LastSeenChapterCount = m.LastSeenChapterCount;
            work.IsStarred = m.IsStarred ?? false;
            work.IsPinned = m.IsPinned ?? false;

            work.Folder = null; // clear the legacy single-folder reference
            // Folders union, not replace: a launch sync must not drop an
            // assignment made locally since the last backup.
            var folderNames = m.FolderNames ?? (m.FolderName is { } single ? [single] : []);
            foreach (var name in folderNames)
            {
                if (work.Folders.Any(f => f.Name == name)) continue;
                if (store.GetFolder(name) is { } folder) work.Folders.Add(folder);
            }

            // Replace chapters only when the backup carries more than we hold: a
            // metadata-only backup (chapters: []) or a stale partial download
            // must not wipe a fuller offline download.
            if (w.Chapters.Count > work.Chapters.Count && !removedDownloads.Contains(w.Ao3Id))
            {
                foreach (var ch in work.Chapters.ToList()) store.Delete(ch);
                foreach (var ch in w.Chapters)
                    store.Insert(new Chapter(work, ch.Index, ch.Title, ch.BodyHtml, ch.AoId));
            }
        }

        // 2. Bookmarks.
        foreach (var b in backup.Bookmarks)
        {
            if (store.GetBookmark(b.Ao3Id) is { } existing)
            {
                existing.WorkAo3Id = b.WorkAo3Id;
                existing.Notes = b.Notes;
                existing.Tags = b.Tags;
                existing.SavedAt = b.SavedAt;
            }
            else
            {
                store.Insert(new BookmarkRecord(b.Ao3Id, b.WorkAo3Id, b.Notes, b.Tags, b.SavedAt));
            }
        }

        // 3. Subscriptions.
        foreach (var sub in backup.Subscriptions)
        {
            if (store.GetSubscription(sub.Key) is { } existing)
            {
                // The baseline and last check only move forward: an older backup
                // must not re-announce chapters, and a null baseline must not
                // switch alerts off until the next poll. Names come from the backup.
                var m = MergedSubscription(sub, new SubscriptionBackup(
                    existing.Key, existing.Kind, existing.DisplayName, existing.AuthorName,
                    existing.LastSeenChapterCount, existing.LastCheckedAt));
                existing.Kind = m.Kind;
                existing.DisplayName = m.DisplayName;
                existing.AuthorName = m.AuthorName;
                existing.LastSeenChapterCount = m.LastSeenChapterCount;
                existing.LastCheckedAt = m.LastCheckedAt;
            }
            else
            {
                store.Insert(new SubscriptionRecord(sub.Key, sub.Kind, sub.DisplayName, sub.AuthorName)
                {
                    LastSeenChapterCount = sub.LastSeenChapterCount,
                    LastCheckedAt = sub.LastCheckedAt,
                });
            }
        }

        // 4. Saved searches.
        foreach (var search in backup.Searches)
        {
            if (tombstones.Removes(DeletionKind.Search, search.Name, search.SavedAt)) continue;
            if (store.GetSavedSearch(search.Name) is { } existing)
            {
                existing.Prompt = search.Prompt;
                existing.SortColumn = search.SortColumn;
                existing.SortDirection = search.SortDirection;
                existing.SavedAt = search.SavedAt;
            }
            else
            {
                store.Insert(new SavedSearch(search.Name, search.Prompt, search.SortColumn, search.SortDirection, search.SavedAt));
            }
        }

        // 5. Reading progress — newer side wins, so a background sync can only
        // advance a position, never rewind it.
        foreach (var p in backup.Progress)
        {
            if (store.GetReadingProgress(p.Ao3Id) is { } existing)
            {
                if (p.UpdatedAt > existing.UpdatedAt)
                {
                    existing.ChapterIndex = p.ChapterIndex;
                    existing.ParagraphIndex = p.ParagraphIndex;
                    existing.Title = p.Title;
                    existing.Author = p.Author;
                    existing.UpdatedAt = p.UpdatedAt;
                }
            }
            else
            {
                store.Insert(new ReadingProgress(p.Ao3Id, p.ChapterIndex, p.ParagraphIndex, p.Title, p.Author, p.UpdatedAt));
            }
        }

        // 6. Saved filters.
        foreach (var f in backup.Filters)
        {
            if (tombstones.Removes(DeletionKind.Filter, f.Name, f.SavedAt)) continue;
            if (store.GetSavedFilter(f.Name) is { } existing)
            {
                existing.FiltersJson = f.FiltersJson;
                existing.SavedAt = f.SavedAt;
            }
            else
            {
                store.Insert(new SavedFilter(f.Name, f.FiltersJson, f.SavedAt));
            }
        }

        // 7. Hidden works.
        foreach (var h in backup.Hidden)
        {
            if (tombstones.Removes(DeletionKind.Hidden, h.Ao3Id, h.HiddenAt)) continue;
            if (store.GetHiddenWork(h.Ao3Id) is { } existing)
            {
                existing.Title = h.Title;
                existing.HiddenAt = h.HiddenAt;
            }
            else
            {
                store.Insert(new HiddenWork(h.Ao3Id, h.Title, h.HiddenAt));
            }
        }

        // 7b. Blocked tags and authors: add any this device lacks (a union, so
        // unblocking on one device doesn't propagate, like hidden works).
        foreach (var b in backup.Blocked ?? [])
        {
            if (BlockedTerm.ParseKind(b.Kind) is not { } kind || Blocklist.Fold(b.Value).Length == 0
                || store.GetBlockedTerm(kind, b.Value) is not null) continue;
            store.Insert(new BlockedTerm(kind, b.Value, b.CreatedAt));
        }

        // 8. Reading stats, merged conservatively — the larger of the totals and
        // the per-day maxima, and the widest date span — so syncing two devices
        // never double-counts or loses reading time.
        foreach (var st in backup.Stats ?? [])
        {
            if (store.GetReadingStat(st.Ao3Id) is { } existing)
            {
                if (st.Fandoms.Count > 0) existing.Fandoms = st.Fandoms;
                if (st.Categories.Count > 0) existing.Categories = st.Categories;
                if (st.Relationships.Count > 0) existing.Relationships = st.Relationships;
                if (st.Rating.Length > 0) existing.Rating = st.Rating;
                if (st.WordCount > 0) existing.WordCount = st.WordCount;
                if (st.Title.Length > 0) existing.Title = st.Title;
                if (st.Author.Length > 0) existing.Author = st.Author;
                existing.TotalSeconds = Math.Max(existing.TotalSeconds, st.TotalSeconds);
                if (st.FirstReadAt < existing.FirstReadAt) existing.FirstReadAt = st.FirstReadAt;
                if (st.LastReadAt > existing.LastReadAt) existing.LastReadAt = st.LastReadAt;
                existing.MaxProgress = Math.Max(existing.MaxProgress, st.MaxProgress ?? 0);
                if (st.WorkIsComplete == true) existing.WorkIsComplete = true;
                var merged = new Dictionary<string, double>(existing.DaySeconds);
                foreach (var (day, seconds) in st.DaySeconds)
                    merged[day] = Math.Max(merged.GetValueOrDefault(day), seconds);
                existing.DaySeconds = merged;
                // Per-day maxima from two devices can sum past either device's
                // own total, which would leave All Time showing less than a
                // single period. Lift the total back to Σ DaySeconds.
                existing.TotalSeconds = Math.Max(existing.TotalSeconds, merged.Values.Sum());
            }
            else
            {
                store.Insert(new ReadingStat(
                    st.Ao3Id, st.Title, st.Author, st.Fandoms, st.Categories, st.Relationships, st.Rating, st.WordCount,
                    st.FirstReadAt, st.LastReadAt, st.TotalSeconds, new Dictionary<string, double>(st.DaySeconds),
                    st.MaxProgress ?? 0, st.WorkIsComplete ?? false));
            }
        }

        // 9. Followed authors: added when missing; known works only grow, so a
        // restored follow doesn't announce the back catalogue.
        foreach (var a in backup.FollowedAuthors ?? [])
        {
            if (a.Username.Length == 0) continue;
            var existing = store.GetFollowedAuthor(a.Username)
                ?? store.Where<FollowedAuthor>(f => string.Equals(f.Username, a.Username, StringComparison.OrdinalIgnoreCase)).FirstOrDefault();
            if (existing is not null)
            {
                var known = existing.KnownWorkIds.Union(a.KnownWorkIds).ToList();
                if (known.Count != existing.KnownWorkIds.Count) existing.KnownWorkIds = known;
                if (a.FollowedAt < existing.FollowedAt) existing.FollowedAt = a.FollowedAt;
                if (Later(existing.LastCheckedAt, a.LastCheckedAt) != existing.LastCheckedAt) existing.LastCheckedAt = a.LastCheckedAt;
            }
            else
            {
                store.Insert(new FollowedAuthor(a.Username, a.DisplayName.Length == 0 ? a.Username : a.DisplayName,
                    a.FollowedAt, a.LastCheckedAt, a.KnownWorkIds));
            }
        }

        // 10. Deletions made on other devices: remove this device's copy of a
        // record a marker covers, unless the file holds a newer copy (saved
        // again since), which the steps above applied.
        ApplyDeletions(tombstones, backup, store);
    }

    /// <summary>Deletes this device's records that a deletion marker covers:
    /// ones stamped no later than the marker, when the backup has no newer copy.</summary>
    private static void ApplyDeletions(DeletionIndex tombstones, LibraryBackup backup, LibraryStore store)
    {
        var liveWorks = backup.Works.Where(w => !tombstones.Removes(DeletionKind.Work, w.Ao3Id, w.SavedAt)).Select(w => w.Ao3Id).ToHashSet();
        foreach (var work in store.All<Work>().ToList())
            if (!liveWorks.Contains(work.Ao3Id) && tombstones.Removes(DeletionKind.Work, work.Ao3Id, work.SavedAt))
                WorkPersistence.RemoveWork(work, store);

        var liveHidden = backup.Hidden.Where(h => !tombstones.Removes(DeletionKind.Hidden, h.Ao3Id, h.HiddenAt)).Select(h => h.Ao3Id).ToHashSet();
        foreach (var hidden in store.All<HiddenWork>().ToList())
            if (!liveHidden.Contains(hidden.Ao3Id) && tombstones.Removes(DeletionKind.Hidden, hidden.Ao3Id, hidden.HiddenAt))
                store.Delete(hidden);

        var liveFolders = (backup.Folders ?? []).Where(f => !tombstones.Removes(DeletionKind.Folder, f.Name, f.CreatedAt))
            .Select(f => f.Name).ToHashSet(StringComparer.Ordinal);
        foreach (var folder in store.All<CustomFolder>().ToList())
            if (!liveFolders.Contains(folder.Name) && tombstones.Removes(DeletionKind.Folder, folder.Name, folder.CreatedAt))
                store.Delete(folder);

        var liveSearches = backup.Searches.Where(s => !tombstones.Removes(DeletionKind.Search, s.Name, s.SavedAt))
            .Select(s => s.Name).ToHashSet(StringComparer.Ordinal);
        foreach (var search in store.All<SavedSearch>().ToList())
            if (!liveSearches.Contains(search.Name) && tombstones.Removes(DeletionKind.Search, search.Name, search.SavedAt))
                store.Delete(search);

        var liveFilters = backup.Filters.Where(f => !tombstones.Removes(DeletionKind.Filter, f.Name, f.SavedAt))
            .Select(f => f.Name).ToHashSet(StringComparer.Ordinal);
        foreach (var filter in store.All<SavedFilter>().ToList())
            if (!liveFilters.Contains(filter.Name) && tombstones.Removes(DeletionKind.Filter, filter.Name, filter.SavedAt))
                store.Delete(filter);
    }

    /// <summary>Deletes the backup file (and the copy of the previous one) from the sync folder.</summary>
    public bool Clear()
    {
        if (BackupPath is not { } path) return false;
        try { File.Delete(PreviousBackupPath(path)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            LibraryHooks.Log?.Invoke($"Failed to clear the previous library backup: {e.Message}");
        }
        if (!File.Exists(path)) return false;
        try
        {
            File.Delete(path);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            LibraryHooks.Log?.Invoke($"Failed to clear the library backup: {e.Message}");
            return false;
        }
    }
}

/// <summary>What Sync Now did: whether it restored other devices' changes
/// into the library, and how the backup after it went.</summary>
public readonly record struct SyncNowResult(bool Restored, BackupOutcome Backup);

/// <summary>What <see cref="LibrarySyncManager.Backup"/> did.</summary>
public enum BackupOutcome
{
    Written,
    /// <summary>Sync is off or has no folder.</summary>
    NoFolder,
    /// <summary>The backup there is a cloud placeholder that isn't downloaded yet.</summary>
    NotDownloaded,
    /// <summary>The backup there couldn't be read (locked by the sync app).</summary>
    FileBusy,
    /// <summary>The backup there couldn't be decoded (damaged, or a newer app's
    /// format), so it was left alone rather than overwritten.</summary>
    Unreadable,
    Failed,
}
