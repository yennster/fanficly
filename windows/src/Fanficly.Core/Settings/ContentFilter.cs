namespace Fanficly.Core;

/// <summary>App-wide content-control keys backing the UGC safeguards (App Store
/// guideline 1.2), centralized so Search, Browse, Settings and the age gate all
/// agree on the same settings keys.</summary>
public static class ContentControl
{
    /// <summary>User toggle: hide Mature/Explicit-rated works from results. Default on.</summary>
    public const string FilterMatureKey = "content.filterMatureExplicit";
    /// <summary>Set once the user confirms they are 17+. Gates the whole app.</summary>
    public const string AgeConfirmedKey = "content.ageConfirmed";
}

/// <summary>Filters a list of works for display: drops anything the user has
/// hidden, and (when enabled) anything rated Mature or Explicit.</summary>
public static class ContentFilter
{
    public static IReadOnlySet<string> MatureRatings { get; } = new HashSet<string> { "Mature", "Explicit" };

    public static IReadOnlyList<AO3WorkSummary> Apply(IEnumerable<AO3WorkSummary> works, IReadOnlySet<int> hiddenIds, bool filterMature) =>
        works.Where(work =>
        {
            if (hiddenIds.Contains(work.Id)) return false;
            if (filterMature && MatureRatings.Contains(work.Rating)) return false;
            return true;
        }).ToList();
}

/// <summary>Local "block" mechanism — the user can hide a work so it never
/// shows in results again. Stored on-device only.</summary>
public static class HiddenWorkStore
{
    public static IReadOnlySet<int> Ids(IEnumerable<HiddenWork> hidden) => hidden.Select(h => h.Ao3Id).ToHashSet();

    /// <summary>Every hidden work id in the store.</summary>
    public static IReadOnlySet<int> Ids(LibraryStore store) => Ids(store.All<HiddenWork>());

    public static bool IsHidden(int ao3Id, LibraryStore store) => store.GetHiddenWork(ao3Id) is not null;

    public static void Hide(int ao3Id, string title, LibraryStore store)
    {
        if (IsHidden(ao3Id, store)) return;
        store.Insert(new HiddenWork(ao3Id, title));
        store.TrySave();
    }

    public static void Unhide(int ao3Id, LibraryStore store)
    {
        foreach (var record in store.Where<HiddenWork>(h => h.Ao3Id == ao3Id)) store.Delete(record);
        store.TrySave();
    }
}
