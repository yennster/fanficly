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
            }

            // 4. Serialize and write atomically.
            var data = LibraryBackupJson.Encode(backup);
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

    /// <summary>The library as a backup, mapping every record type.</summary>
    internal LibraryBackup MakeLocalBackup(LibraryStore store)
    {
        var works = store.All<Work>().Select(work => new WorkBackup(
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
            Chapters: store.ChaptersOf(work).Select(ch => new ChapterBackup(ch.Index, ch.Title, ch.BodyHtml, ch.AoId)).ToList(),
            FolderName: work.Folders.FirstOrDefault()?.Name,
            FolderNames: work.Folders.Select(f => f.Name).ToList())).ToList();

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
                a.Username, a.DisplayName, a.FollowedAt, a.KnownWorkIds, a.LastCheckedAt)).ToList());
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
    /// the local record wins (this device just produced it), except that
    /// chapters survive from whichever side has more, reading positions keep
    /// the newer one, and reading stats merge conservatively.</summary>
    public static LibraryBackup MergedBackup(LibraryBackup local, LibraryBackup cloud)
    {
        var worksById = FirstByKey(cloud.Works, w => w.Ao3Id);
        foreach (var w in local.Works)
        {
            var merged = w;
            if (worksById.TryGetValue(w.Ao3Id, out var cloudWork) && cloudWork.Chapters.Count > w.Chapters.Count)
                merged = w with { Chapters = cloudWork.Chapters };
            worksById[w.Ao3Id] = merged;
        }

        var bookmarksById = FirstByKey(cloud.Bookmarks, b => b.Ao3Id);
        foreach (var b in local.Bookmarks) bookmarksById[b.Ao3Id] = b;

        var subscriptionsByKey = FirstByKey(cloud.Subscriptions, s => s.Key);
        foreach (var s in local.Subscriptions) subscriptionsByKey[s.Key] = s;

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

        return new LibraryBackup(
            Works: worksById.Values.OrderBy(w => w.Ao3Id).ToList(),
            Bookmarks: bookmarksById.Values.OrderBy(b => b.Ao3Id).ToList(),
            Subscriptions: subscriptionsByKey.Values.OrderBy(s => s.Key, StringComparer.Ordinal).ToList(),
            Searches: searchesByName.Values.OrderBy(s => s.Name, StringComparer.Ordinal).ToList(),
            Progress: progressById.Values.OrderBy(p => p.Ao3Id).ToList(),
            Filters: filtersByName.Values.OrderBy(f => f.Name, StringComparer.Ordinal).ToList(),
            Hidden: hiddenById.Values.OrderBy(h => h.Ao3Id).ToList(),
            Settings: local.Settings ?? cloud.Settings,
            Folders: foldersByName.Values.OrderBy(f => f.Name, StringComparer.Ordinal).ToList(),
            Stats: statsById.Values.OrderBy(s => s.Ao3Id).ToList(),
            Timestamp: local.Timestamp,
            FollowedAuthors: local.FollowedAuthors is null && cloud.FollowedAuthors is null
                ? null
                : authorsByName.Values.OrderBy(a => a.Username, StringComparer.Ordinal).ToList());
    }

    /// <summary>Dictionary keyed by <paramref name="key"/>, keeping the first of
    /// any duplicates (Swift's <c>uniquingKeysWith: { a, _ in a }</c>).</summary>
    private static DateTimeOffset? Later(DateTimeOffset? a, DateTimeOffset? b) =>
        a is null ? b : b is null ? a : a > b ? a : b;

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
            if (store.GetFolder(f.Name) is null) store.Insert(new CustomFolder(f.Name, f.CreatedAt));

        // 1. Works and their chapters.
        foreach (var w in backup.Works)
        {
            var work = store.GetWork(w.Ao3Id);
            if (work is null)
            {
                work = new Work(w.Ao3Id, w.Title, w.AuthorName);
                store.Insert(work);
            }

            work.Title = w.Title;
            work.AuthorName = w.AuthorName;
            work.AuthorUsername = w.AuthorUsername;
            work.Summary = w.Summary;
            work.Rating = w.Rating;
            work.Warnings = w.Warnings;
            work.Categories = w.Categories;
            work.Fandoms = w.Fandoms;
            work.Characters = w.Characters;
            work.Relationships = w.Relationships;
            work.Freeforms = w.Freeforms;
            work.Language = w.Language;
            work.WordCount = w.WordCount;
            work.ChapterCount = w.ChapterCount;
            work.TotalChapters = w.TotalChapters;
            work.Kudos = w.Kudos;
            work.Hits = w.Hits;
            work.BookmarksCount = w.BookmarksCount;
            work.CommentsCount = w.CommentsCount;
            work.IsComplete = w.IsComplete;
            work.PublishedAt = w.PublishedAt;
            work.UpdatedAt = w.UpdatedAt;
            work.SavedAt = w.SavedAt;
            // Reading position: keep whichever side read more recently. Restore
            // runs as a background launch sync, which must never rewind this
            // device to an older backup.
            if ((w.LastReadAt ?? DateTimeOffset.MinValue) > (work.LastReadAt ?? DateTimeOffset.MinValue))
            {
                work.LastReadAt = w.LastReadAt;
                work.LastReadChapter = w.LastReadChapter;
                work.LastReadProgress = w.LastReadProgress;
            }
            // Follow/star/pin merge as an OR: the cloud union can lag a flag set
            // locally moments ago, and un-flagging deliberately doesn't propagate.
            work.IsFollowed = work.IsFollowed || w.IsFollowed;
            work.FollowedAt ??= w.FollowedAt;
            // Notification baseline only advances — regressing it would re-fire
            // "new chapter" alerts for chapters already seen.
            if (w.LastSeenChapterCount is { } cloudSeen)
                work.LastSeenChapterCount = Math.Max(work.LastSeenChapterCount ?? 0, cloudSeen);
            work.IsStarred = work.IsStarred || (w.IsStarred ?? false);
            work.IsPinned = work.IsPinned || (w.IsPinned ?? false);

            work.Folder = null; // clear the legacy single-folder reference
            // Folders union, not replace: a launch sync must not drop an
            // assignment made locally since the last backup.
            var folderNames = w.FolderNames ?? (w.FolderName is { } single ? [single] : []);
            foreach (var name in folderNames)
            {
                if (work.Folders.Any(f => f.Name == name)) continue;
                if (store.GetFolder(name) is { } folder) work.Folders.Add(folder);
            }

            // Replace chapters only when the backup carries more than we hold: a
            // metadata-only backup (chapters: []) or a stale partial download
            // must not wipe a fuller offline download.
            if (w.Chapters.Count > work.Chapters.Count)
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
                existing.Kind = sub.Kind;
                existing.DisplayName = sub.DisplayName;
                existing.AuthorName = sub.AuthorName;
                existing.LastSeenChapterCount = sub.LastSeenChapterCount;
                existing.LastCheckedAt = sub.LastCheckedAt;
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
