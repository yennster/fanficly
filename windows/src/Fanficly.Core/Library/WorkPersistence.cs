namespace Fanficly.Core;

/// <summary>Saving works into the library and the local follow / star / pin /
/// folder / history actions on them.</summary>
public static class WorkPersistence
{
    /// <summary>Where downloaded EPUBs live (Swift: <c>Documents/library</c>).
    /// The app sets it at launch; the default is a folder under LocalAppData.</summary>
    public static string LibraryFolder { get; set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Fanficly", "library");

    /// <summary>Saves a fully-fetched work: its metadata plus all its chapters,
    /// replacing any chapters already stored.</summary>
    public static Work Upsert(AO3WorkPayload payload, LibraryStore store)
    {
        var work = UpsertMetadata(payload.Summary, store, save: false);

        foreach (var ch in work.Chapters.ToList()) store.Delete(ch);
        foreach (var ch in payload.Chapters)
        {
            var chapter = new Chapter(work, ch.Index, ch.Title, ch.BodyHtml, ch.AoId);
            store.Insert(chapter);
        }
        // Saved for offline again, so restores may update its chapters again.
        SyncDeletions.SetDownloadRemoved(LibrarySyncManager.SharedSettings, work.Ao3Id, removed: false);

        store.TrySave();
        return work;
    }

    /// <summary>Upsert just the metadata (no chapter bodies). Used by the local
    /// follow action, which doesn't need to download the full work.</summary>
    public static Work UpsertMetadata(AO3WorkSummary summary, LibraryStore store, bool save = true)
    {
        var work = store.GetWork(summary.Id);
        if (work is null)
        {
            work = new Work(summary.Id, summary.Title, summary.Author);
            store.Insert(work);
        }

        work.Title = summary.Title;
        work.AuthorName = summary.Author;
        work.AuthorUsername = summary.AuthorUsername;
        work.Summary = summary.Summary;
        work.Rating = summary.Rating;
        work.Warnings = summary.Warnings;
        work.Categories = summary.Categories;
        work.Fandoms = summary.Fandoms;
        work.Characters = summary.Characters;
        work.Relationships = summary.Relationships;
        work.Freeforms = summary.Freeforms;
        work.Language = summary.Language;
        work.WordCount = summary.WordCount;
        work.ChapterCount = summary.ChapterCount;
        work.TotalChapters = summary.TotalChapters;
        work.Kudos = summary.Kudos;
        work.Hits = summary.Hits;
        work.IsComplete = summary.IsComplete;
        work.UpdatedAt = summary.UpdatedAt;

        if (save) store.TrySave();
        // Every library work is searchable, followed or not (Swift: RM-016).
        IndexWork(work);
        return work;
    }

    public static void IndexWork(Work work) => LibraryHooks.SearchIndexer?.Index(work);

    public static void DeindexWork(int ao3Id) => LibraryHooks.SearchIndexer?.Remove(ao3Id);

    public static bool IsFollowed(int workId, LibraryStore store) => store.GetWork(workId)?.IsFollowed ?? false;

    /// <summary>Toggle the local follow flag, persisting metadata if needed.
    /// Returns the new follow state.</summary>
    public static bool ToggleFollow(AO3WorkSummary summary, LibraryStore store)
    {
        var work = UpsertMetadata(summary, store, save: false);
        work.IsFollowed = !work.IsFollowed;
        if (work.IsFollowed)
        {
            work.FollowedAt = DateTimeOffset.Now;
            work.LastSeenChapterCount = summary.ChapterCount;
            // Following opts into the poller's new-chapter alerts — the one
            // notification source that works fully logged out — so this is the
            // moment to ask for permission, not the login-gated Subscriptions tab.
            NotificationsAuthorization.RequestAfterFollow();
        }
        else
        {
            work.FollowedAt = null;
        }
        store.TrySave();
        LibrarySyncManager.QueueBackupShared(store);
        return work.IsFollowed;
    }

    /// <summary>The Library row's Unfollow action (offered on in-progress works).</summary>
    public static void Unfollow(Work work, LibraryStore store)
    {
        work.IsFollowed = false;
        work.FollowedAt = null;
        store.TrySave();
        LibrarySyncManager.QueueBackupShared(store);
    }

    /// <summary>Star / unstar a saved work. Returns the new state.</summary>
    public static bool ToggleStar(Work work, LibraryStore store)
    {
        work.IsStarred = !work.IsStarred;
        store.TrySave();
        LibrarySyncManager.QueueBackupShared(store);
        return work.IsStarred;
    }

    /// <summary>Pin / unpin a saved work (pinned works sort first). Returns the new state.</summary>
    public static bool TogglePin(Work work, LibraryStore store)
    {
        work.IsPinned = !work.IsPinned;
        store.TrySave();
        LibrarySyncManager.QueueBackupShared(store);
        return work.IsPinned;
    }

    /// <summary>Removes a work from the library, with its downloaded EPUB, and
    /// records the deletion so sync carries it to the other devices.</summary>
    public static void DeleteWork(Work work, LibraryStore store)
    {
        LibrarySyncManager.RecordDeletionShared(DeletionKind.Work, work.Ao3Id);
        RemoveWork(work, store);
        store.TrySave();
        LibrarySyncManager.QueueBackupShared(store);
    }

    /// <summary>Removes a work with its downloaded EPUB and search-index entry,
    /// without saving or recording a deletion (a restore applying another
    /// device's delete uses it).</summary>
    internal static void RemoveWork(Work work, LibraryStore store)
    {
        if (EpubPath(work.Ao3Id) is { } path)
        {
            try { File.Delete(path); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        DeindexWork(work.Ao3Id);
        store.Delete(work);
    }

    /// <summary>Deletes the offline copy (EPUB and stored chapters); the work
    /// stays in the library and reads on demand. Marked on this device so a
    /// restore doesn't put the chapters back from another device's copy and
    /// offer to re-download it.</summary>
    public static void RemoveDownload(Work work, LibraryStore store)
    {
        if (EpubPath(work.Ao3Id) is { } path)
        {
            try { File.Delete(path); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { LibraryHooks.Log?.Invoke($"Removing {path} failed: {e.Message}"); }
        }
        foreach (var chapter in work.Chapters.ToList()) store.Delete(chapter);
        SyncDeletions.SetDownloadRemoved(LibrarySyncManager.SharedSettings, work.Ao3Id, removed: true);
        store.TrySave();
        LibrarySyncManager.QueueBackupShared(store);
    }

    // MARK: - Folders

    /// <summary>Creates a folder named <paramref name="name"/> (trimmed) unless
    /// one exists, optionally putting <paramref name="work"/> in the new folder.
    /// Returns the new folder, or null for a blank or taken name.</summary>
    public static CustomFolder? CreateFolder(string name, LibraryStore store, Work? work = null)
    {
        var trimmed = name.Trim();
        if (trimmed.Length == 0) return null;
        if (store.GetFolder(trimmed) is not null) return null;
        var folder = new CustomFolder(trimmed);
        store.Insert(folder);
        work?.Folders.Add(folder);
        store.TrySave();
        LibrarySyncManager.QueueBackupShared(store);
        return folder;
    }

    /// <summary>Deletes a folder; its works stay in the library.</summary>
    public static void DeleteFolder(CustomFolder folder, LibraryStore store)
    {
        LibrarySyncManager.RecordDeletionShared(DeletionKind.Folder, folder.Name);
        store.Delete(folder);
        store.TrySave();
        LibrarySyncManager.QueueBackupShared(store);
    }

    /// <summary>Adds the work to the folder, or removes it when already there.
    /// Returns whether the work is now in the folder.</summary>
    public static bool ToggleFolder(Work work, CustomFolder folder, LibraryStore store)
    {
        var nowIn = !work.Folders.Contains(folder);
        if (nowIn) work.Folders.Add(folder);
        else work.Folders.Remove(folder);
        store.TrySave();
        LibrarySyncManager.QueueBackupShared(store);
        return nowIn;
    }

    /// <summary>Takes works out of a folder (the folder view's multi-select remove).</summary>
    public static void RemoveFromFolder(IEnumerable<Work> works, CustomFolder folder, LibraryStore store)
    {
        foreach (var work in works) work.Folders.Remove(folder);
        store.TrySave();
        LibrarySyncManager.QueueBackupShared(store);
        LibraryHooks.UpdateWidgetData?.Invoke(store);
    }

    /// <summary>Takes a work out of every folder.</summary>
    public static void ClearFolders(Work work, LibraryStore store)
    {
        work.Folders.Clear();
        store.TrySave();
        LibrarySyncManager.QueueBackupShared(store);
    }

    // MARK: - Recently viewed

    /// <summary>Record (or bump to "now") a work in the recently-viewed history.</summary>
    public static void RecordView(AO3WorkSummary summary, LibraryStore store, int limit = 50) =>
        RecordView(summary.Id, summary.Title, summary.Author, summary.Fandoms.FirstOrDefault() ?? "", store, limit);

    /// <summary>Overload for Library reads, which carry a <see cref="Work"/>.</summary>
    public static void RecordView(Work work, LibraryStore store, int limit = 50) =>
        RecordView(work.Ao3Id, work.Title, work.AuthorName, work.Fandoms.FirstOrDefault() ?? "", store, limit);

    /// <summary>Upsert a recently-viewed entry, then trim the list to the newest <paramref name="limit"/>.</summary>
    public static void RecordView(int ao3Id, string title, string author, string fandom, LibraryStore store, int limit = 50)
    {
        if (store.GetRecentlyViewed(ao3Id) is { } existing)
        {
            existing.ViewedAt = DateTimeOffset.Now;
            existing.Title = title;
            existing.Author = author;
            existing.Fandom = fandom;
        }
        else
        {
            store.Insert(new RecentlyViewed(ao3Id, title, author, fandom));
        }

        var all = store.RecentlyViewedNewestFirst();
        if (all.Count > limit)
            foreach (var stale in all.Skip(limit)) store.Delete(stale);
        store.TrySave();
    }

    /// <summary>Removes entries from the history (swipe / Edit-mode delete).</summary>
    public static void RemoveViews(IEnumerable<RecentlyViewed> items, LibraryStore store)
    {
        foreach (var item in items) store.Delete(item);
        store.TrySave();
    }

    /// <summary>Clears the whole history. Nothing is deleted from AO3 or the library.</summary>
    public static void ClearRecentlyViewed(LibraryStore store) =>
        RemoveViews(store.All<RecentlyViewed>(), store);

    // MARK: - Followed authors

    public static bool IsAuthorFollowed(string username, LibraryStore store)
    {
        if (username.Length == 0) return false;
        return store.GetFollowedAuthor(username) is not null;
    }

    /// <summary>Toggle following an author. <paramref name="seedWorkIds"/> are the
    /// work ids currently visible for the author at follow time, recorded so the
    /// poller doesn't alert for already-published works on its first check.
    /// An empty username (anonymous byline) can't be followed. Returns the new
    /// follow state.</summary>
    public static bool ToggleFollowAuthor(string username, string displayName, LibraryStore store,
                                          IReadOnlyList<int>? seedWorkIds = null)
    {
        if (username.Length == 0) return false;
        if (store.GetFollowedAuthor(username) is { } existing)
        {
            store.Delete(existing);
            store.TrySave();
            LibrarySyncManager.QueueBackupShared(store);
            return false;
        }
        store.Insert(new FollowedAuthor(
            username,
            displayName.Length == 0 ? username : displayName,
            knownWorkIds: seedWorkIds ?? []));
        store.TrySave();
        LibrarySyncManager.QueueBackupShared(store);
        NotificationsAuthorization.RequestAfterFollow(); // see ToggleFollow
        return true;
    }

    // MARK: - Result-row badges (RM-002)

    /// <summary>Badges for one page of search/browse results, keyed by work id
    /// (Swift: <c>WorkPersistence.resultBadges(for:in:)</c>). The store is an
    /// in-memory identity map, so each id is a dictionary lookup, not a query.</summary>
    public static Dictionary<int, ResultBadge> ResultBadges(IEnumerable<AO3WorkSummary> works, LibraryStore store)
    {
        var badges = new Dictionary<int, ResultBadge>();
        foreach (var work in works)
        {
            if (ResultBadgeFor(work, store) is { } badge) badges[work.Id] = badge;
        }
        return badges;
    }

    /// <summary>One result's badge, from its saved <see cref="Work"/>, its
    /// <see cref="ReadingProgress"/> and, for a story read without saving,
    /// its <see cref="ReadingStat"/>'s furthest point.</summary>
    public static ResultBadge? ResultBadgeFor(AO3WorkSummary work, LibraryStore store)
    {
        var saved = store.GetWork(work.Id);
        // The saved position, as the Library row shows it; a story read
        // without saving only has its stats row's furthest point.
        double? progress = null;
        if (saved?.LastReadProgress is { } own && own > 0) progress = own;
        else if (store.GetReadingStat(work.Id)?.MaxProgress is { } max && max > 0) progress = max;
        return ResultBadgeFor(
            inLibrary: saved is not null,
            started: store.GetReadingProgress(work.Id) is not null || saved?.LastReadAt is not null,
            progress: progress,
            isComplete: work.IsComplete);
    }

    /// <summary>The pure mapping behind a result row's badge (Swift:
    /// <c>WorkPersistence.resultBadge(inLibrary:started:progress:isComplete:)</c>).
    /// Reading status wins over "In Library"; "Finished" uses the Library row's
    /// rule (99%, or 95% of a complete work).</summary>
    public static ResultBadge? ResultBadgeFor(bool inLibrary, bool started, double? progress, bool isComplete)
    {
        if (progress is { } raw && double.IsFinite(raw) && raw > 0)
        {
            var p = Math.Min(raw, 1);
            if (p >= 0.99 || (isComplete && p >= 0.95)) return ResultBadge.Finished;
            return ResultBadge.Read(Math.Clamp((int)(p * 100), 1, 99));
        }
        if (started) return ResultBadge.Started;
        return inLibrary ? ResultBadge.InLibrary : null;
    }

    // MARK: - EPUB files

    /// <summary>Where a work's EPUB is (or will be) stored.</summary>
    public static string EpubTargetPath(int workId) => Path.Combine(LibraryFolder, $"{workId}.epub");

    /// <summary>The downloaded EPUB's path, or null when there's no file — the
    /// Library's "Downloaded" state keys off the file, not a flag.</summary>
    public static string? EpubPath(int workId)
    {
        var path = EpubTargetPath(workId);
        return File.Exists(path) ? path : null;
    }
}

public enum ResultBadgeKind { Finished, Percent, Started, InLibrary }

/// <summary>The small status badge on a search or browse result row (Swift:
/// <c>ResultBadge</c>): Finished, a percent read, Started (opened, no fraction
/// known yet), or In Library.</summary>
public readonly record struct ResultBadge(ResultBadgeKind Kind, int Percent = 0)
{
    public static ResultBadge Finished => new(ResultBadgeKind.Finished);
    public static ResultBadge Started => new(ResultBadgeKind.Started);
    public static ResultBadge InLibrary => new(ResultBadgeKind.InLibrary);
    public static ResultBadge Read(int percent) => new(ResultBadgeKind.Percent, percent);

    public string Text => Kind switch
    {
        ResultBadgeKind.Finished => "Finished",
        ResultBadgeKind.Percent => $"{Percent}%",
        ResultBadgeKind.Started => "Started",
        _ => "In Library",
    };

    public string AccessibilityLabel => Kind switch
    {
        ResultBadgeKind.Finished => "Finished reading",
        ResultBadgeKind.Percent => $"{Percent} percent read",
        ResultBadgeKind.Started => "Started reading",
        _ => "In your Library",
    };

    /// <summary>SF Symbol name, mapped by the app's <c>Symbols</c>.</summary>
    public string Symbol => Kind switch
    {
        ResultBadgeKind.Finished => "checkmark.circle.fill",
        ResultBadgeKind.InLibrary => "books.vertical",
        _ => "book",
    };
}
