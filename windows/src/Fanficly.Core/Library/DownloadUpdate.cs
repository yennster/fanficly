namespace Fanficly.Core;

/// <summary>
/// Bringing a downloaded work up to date with AO3 (#180; Swift's
/// <c>DownloadUpdate</c>). The Library reader reads saved chapters without asking
/// AO3, so a work in progress would keep its old ending forever; the counts the
/// app already has (the work's own metadata, the poller's new-chapter baselines)
/// tell it when AO3 is ahead.
/// </summary>
public static class DownloadUpdate
{
    /// <summary>How many chapters AO3 has that the saved copy doesn't, as far as
    /// the app knows: the highest known count minus the saved chapters. Zero when
    /// nothing is saved (that work reads live) or nothing is known.</summary>
    public static int NewChapterCount(int saved, IEnumerable<int?> known)
    {
        if (saved <= 0) return 0;
        var counts = known.Where(c => c.HasValue).Select(c => c!.Value).ToList();
        return counts.Count == 0 ? 0 : Math.Max(0, counts.Max() - saved);
    }

    /// <summary>Every chapter count the app has for a library work: its metadata,
    /// its local follow's baseline, and its AO3 subscription's baseline.</summary>
    public static IReadOnlyList<int?> KnownChapterCounts(Work work, LibraryStore store) =>
        [work.ChapterCount, work.LastSeenChapterCount, store.GetSubscription($"work:{work.Ao3Id}")?.LastSeenChapterCount];

    /// <summary><see cref="NewChapterCount(int, IEnumerable{int?})"/> for a library work.</summary>
    public static int NewChapterCount(Work work, LibraryStore store) =>
        NewChapterCount(store.ChaptersOf(work).Count, KnownChapterCounts(work, store));

    /// <summary>How <see cref="Apply"/> went.</summary>
    /// <param name="Updated">The saved copy now matches AO3.</param>
    /// <param name="Added">Chapters that are new.</param>
    /// <param name="Saved">Chapters saved before.</param>
    /// <param name="OnAO3">Chapters AO3 has.</param>
    public readonly record struct Outcome(bool Updated, int Added, int Saved, int OnAO3);

    /// <summary>Saves <paramref name="fetched"/> over a library work's chapters,
    /// unless AO3 now has fewer than are saved: an update never throws away offline
    /// text. The follow's and the subscription's new-chapter baselines move to AO3's
    /// count, as the poller's next check would set them: chapters already saved
    /// don't alert, and a baseline above AO3's (chapters deleted there) doesn't keep
    /// offering an update that brings nothing.</summary>
    public static Outcome Apply(AO3WorkPayload fetched, Work work, LibraryStore store)
    {
        var saved = store.ChaptersOf(work).Count;
        var onAO3 = fetched.Chapters.Count;
        if (onAO3 < saved) return new Outcome(false, 0, saved, onAO3);
        WorkPersistence.Upsert(fetched, store);
        var count = fetched.Summary.ChapterCount;
        if (work.LastSeenChapterCount is not null) work.LastSeenChapterCount = count;
        if (store.GetSubscription($"work:{work.Ao3Id}") is { LastSeenChapterCount: not null } record)
            record.LastSeenChapterCount = count;
        store.TrySave();
        return new Outcome(true, Math.Max(0, onAO3 - saved), saved, onAO3);
    }

    /// <summary>"1 new chapter on AO3", "3 new chapters on AO3".</summary>
    public static string BannerText(int count) =>
        count == 1 ? "1 new chapter on AO3" : $"{count} new chapters on AO3";
}
