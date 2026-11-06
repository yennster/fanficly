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

    /// <summary>"1 new chapter on AO3", "3 new chapters on AO3".</summary>
    public static string BannerText(int count) =>
        count == 1 ? "1 new chapter on AO3" : $"{count} new chapters on AO3";
}
