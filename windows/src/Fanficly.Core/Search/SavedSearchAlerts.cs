namespace Fanficly.Core;

/// <summary>New-fic alerts for saved searches (#309; Swift <c>SavedSearchAlerts</c>).
/// A saved search with alerts on works like a feed: <see cref="SubscriptionPoller"/>
/// runs it, newest posted first, and posts a toast for works posted since it last
/// looked. Each check is one throttled AO3 search; nothing leaves the device.</summary>
public static class SavedSearchAlerts
{
    /// <summary>How many saved searches can have alerts on at once. Every
    /// alerting search costs one AO3 search per poll, and AO3's search is slow
    /// (20–30 s before it answers is normal), so this keeps the load on AO3 small.</summary>
    public const int MaxAlertingSearches = 10;

    /// <summary>How many seen work ids a search keeps. The newest are kept, which
    /// always includes the newest one <see cref="NewMatches"/> compares against.</summary>
    public const int KnownWorkIdLimit = 200;

    /// <summary>What a check runs: exactly the saved search's keywords and
    /// filters, nothing inferred, sorted by date posted, newest first.</summary>
    public static AO3SearchFilters Filters(string prompt)
    {
        var parsed = SearchSyntax.Parse(prompt);
        var filters = new AO3SearchFilters().Merging(parsed);
        filters.Query = SearchSyntax.CollapseWhitespace(parsed.Query);
        filters.SortColumn = SortColumn.CreatedAt;
        filters.SortDirection = SortDirection.Desc;
        return filters;
    }

    /// <summary>The works in a check's results that were posted since the
    /// baseline. Nothing before a baseline exists: the first check only records
    /// what's there, so turning alerts on never alerts for the back catalogue.
    /// With a baseline but no seen ids (the search had no results), every work is
    /// new. Otherwise an unseen work is new when it's newer than every seen one
    /// (AO3 work ids only grow). An unseen work with a lower id is usually an old
    /// work that now matches (its tags were edited) and never alerts, unless it
    /// has one chapter and a date since the last check: a long-held draft just
    /// posted, or a gift revealed from an anonymous collection. Blurbs carry the
    /// day only, so the date gets 36 hours' slack.</summary>
    public static IReadOnlyList<AO3WorkSummary> NewMatches(IReadOnlyList<AO3WorkSummary> works, IReadOnlySet<int> known,
                                                           bool baselined, DateTimeOffset? lastCheckedAt)
    {
        if (!baselined) return [];
        var unseen = works.Where(w => !known.Contains(w.Id)).ToList();
        if (known.Count == 0) return unseen;
        var newestKnown = known.Max();
        var cutoff = lastCheckedAt?.AddHours(-36);
        return unseen.Where(w =>
        {
            if (w.Id > newestKnown) return true;
            if (w.ChapterCount != 1) return false;
            return cutoff is not { } c || w.UpdatedAt is not { } date || date >= c;
        }).ToList();
    }

    /// <summary>The seen ids after a check: the union, newest first, capped at
    /// <see cref="KnownWorkIdLimit"/>.</summary>
    public static IReadOnlyList<int> Baseline(IEnumerable<int> known, IEnumerable<int> adding) =>
        known.Union(adding).OrderByDescending(id => id).Take(KnownWorkIdLimit).ToList();

    /// <summary>Whether another saved search may have alerts switched on.</summary>
    public static bool CanEnableMore(LibraryStore store) =>
        store.All<SavedSearch>().Count(s => s.AlertsEnabled) < MaxAlertingSearches;

    /// <summary>Switches a search's alerts on or off. Switching on starts a fresh
    /// baseline, taken by the next check (the caller runs one right away), so works
    /// posted while alerts were off don't all alert at once.</summary>
    public static void SetAlerts(bool on, SavedSearch search, LibraryStore store)
    {
        search.AlertsEnabled = on;
        search.AlertsChangedAt = DateTimeOffset.Now;
        ResetBaseline(search);
        store.TrySave();
        if (on) NotificationsAuthorization.RequestAfterFollow();
    }

    /// <summary>Forgets what a search has seen, for a new start or an edited
    /// search (the old results say nothing about the new one).</summary>
    public static void ResetBaseline(SavedSearch search)
    {
        search.AlertKnownWorkIds = [];
        search.AlertsBaselineAt = null;
        search.AlertsLastCheckedAt = null;
        search.AlertsAttemptedAt = null;
        search.AlertNewWorkIds = [];
    }

    /// <summary>Clears a search's "New" count once its results have been opened.</summary>
    public static void MarkSeen(SavedSearch search, LibraryStore store)
    {
        if (search.AlertNewWorkIds.Count == 0) return;
        search.AlertNewWorkIds = [];
        store.TrySave();
    }

    public static void MarkSeen(string name, LibraryStore store)
    {
        if (store.GetSavedSearch(name) is { } search) MarkSeen(search, store);
    }

    /// <summary>Takes one opened work off every search's "New" count.</summary>
    public static void MarkWorkSeen(int workId, LibraryStore store)
    {
        var changed = false;
        foreach (var search in store.All<SavedSearch>().Where(s => s.AlertNewWorkIds.Contains(workId)))
        {
            search.AlertNewWorkIds = search.AlertNewWorkIds.Where(id => id != workId).ToList();
            changed = true;
        }
        if (changed) store.TrySave();
    }
}
