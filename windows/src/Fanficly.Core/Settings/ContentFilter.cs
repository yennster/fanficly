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
/// hidden, anything the blocklist matches, and (when enabled) anything rated
/// Mature or Explicit.</summary>
public static class ContentFilter
{
    public static IReadOnlySet<string> MatureRatings { get; } = new HashSet<string> { "Mature", "Explicit" };

    public static IReadOnlyList<AO3WorkSummary> Apply(IEnumerable<AO3WorkSummary> works, IReadOnlySet<int> hiddenIds, bool filterMature,
                                                      Blocklist? blocklist = null) =>
        works.Where(work =>
        {
            if (hiddenIds.Contains(work.Id)) return false;
            if (filterMature && MatureRatings.Contains(work.Rating)) return false;
            if (blocklist is not null && blocklist.Blocks(work)) return false;
            return true;
        }).ToList();

    /// <summary>Ratings whose works may load the images authors embed, with
    /// "Show images in stories" on. Windows only: the Microsoft Store forbids an app
    /// that displays pornographic content (policy 11.7), and an image embedded in a
    /// Mature, Explicit or unrated work can be anything, so those works and works of
    /// unknown rating stay text-only. Their text is unaffected.</summary>
    public static IReadOnlySet<string> ImageSafeRatings { get; } =
        new HashSet<string> { "General Audiences", "Teen And Up Audiences" };

    /// <summary>Whether the reader may show embedded images for a work with this rating.</summary>
    public static bool AllowsStoryImages(string? rating) =>
        rating is not null && ImageSafeRatings.Contains(rating.Trim());
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

/// <summary>The user's blocked tags and authors (Blocklist, RM-006), folded for
/// matching. Tags match any of a work's tags (fandoms, relationships,
/// characters, freeforms, warnings, categories) by AO3 name, ignoring case and
/// surrounding spaces; authors match the byline login or display name the
/// same way.
///
/// Lists only: the reader, the Library and the user's own AO3 subscriptions
/// and bookmarks never consult it, so a work opened on purpose always shows.</summary>
public sealed class Blocklist
{
    private readonly HashSet<string> _tags;
    private readonly HashSet<string> _authors;

    public static Blocklist Empty { get; } = new([], []);

    public Blocklist(IEnumerable<string> tags, IEnumerable<string> authors)
    {
        _tags = tags.Select(Fold).Where(t => t.Length > 0).ToHashSet(StringComparer.Ordinal);
        _authors = authors.Select(Fold).Where(a => a.Length > 0).ToHashSet(StringComparer.Ordinal);
    }

    /// <summary>The blocklist for these stored terms.</summary>
    public static Blocklist From(IEnumerable<BlockedTerm> terms)
    {
        var list = terms.ToList();
        return new Blocklist(
            list.Where(t => t.Kind == BlockedTerm.KindName(BlockedTermKind.Tag)).Select(t => t.Value),
            list.Where(t => t.Kind == BlockedTerm.KindName(BlockedTermKind.Author)).Select(t => t.Value));
    }

    /// <summary>Every blocked term in the store.</summary>
    public static Blocklist From(LibraryStore store) => From(store.All<BlockedTerm>());

    public bool IsEmpty => _tags.Count == 0 && _authors.Count == 0;
    public IReadOnlySet<string> Tags => _tags;
    public IReadOnlySet<string> Authors => _authors;

    /// <summary>Trimmed and lowercased (culture-invariant, like Swift's <c>lowercased()</c>).</summary>
    public static string Fold(string value) => value.Trim().ToLowerInvariant();

    /// <summary>Every name a work's byline answers to, folded: the first
    /// author's login, the whole byline, and each co-author's pseud and login
    /// (AO3 writes a byline as "pseud (login)" when they differ, joined by ", ").</summary>
    public static HashSet<string> AuthorNames(AO3WorkSummary work)
    {
        var names = new HashSet<string>(StringComparer.Ordinal) { Fold(work.AuthorUsername), Fold(work.Author) };
        foreach (var part in work.Author.Split(", "))
        {
            names.Add(Fold(part));
            var open = part.LastIndexOf(" (", StringComparison.Ordinal);
            if (part.EndsWith(')') && open >= 0)
            {
                names.Add(Fold(part[..open]));
                names.Add(Fold(part[(open + 2)..^1]));
            }
        }
        names.Remove("");
        return names;
    }

    public bool Blocks(AO3WorkSummary work)
    {
        if (IsEmpty) return false;
        if (_authors.Count > 0 && AuthorNames(work).Overlaps(_authors)) return true;
        if (_tags.Count == 0) return false;
        return work.Fandoms.Concat(work.Relationships).Concat(work.Characters)
            .Concat(work.Freeforms).Concat(work.Warnings).Concat(work.Categories)
            .Any(t => _tags.Contains(Fold(t)));
    }

    /// <summary>The blocklist minus whatever a list was asked for by name: the
    /// tags and creators a search or browse filters on. Asking for a blocked
    /// tag on purpose (clicking its chip, searching for it) shows its works.</summary>
    public Blocklist Lifting(AO3SearchFilters filters) =>
        Lifting(
            filters.FandomNames.Concat(filters.RelationshipNames).Concat(filters.CharacterNames)
                .Concat(filters.FreeformNames).Concat(filters.OtherTagNames)
                .Concat(filters.Warnings.Select(w => w.DisplayName()))
                .Concat(filters.Categories.Select(c => c.DisplayName())),
            filters.Creators.Split(','));

    public Blocklist Lifting(IEnumerable<string> tags, IEnumerable<string> authors)
    {
        var liftedTags = tags.Select(Fold).ToHashSet(StringComparer.Ordinal);
        var liftedAuthors = authors.Select(Fold).ToHashSet(StringComparer.Ordinal);
        return new Blocklist(_tags.Where(t => !liftedTags.Contains(t)), _authors.Where(a => !liftedAuthors.Contains(a)));
    }
}

/// <summary>Local blocklist storage (BlocklistStore): block and unblock tags and
/// authors. Stored on the PC, and in the optional synced backup as a union.</summary>
public static class BlocklistStore
{
    public static bool IsBlocked(BlockedTermKind kind, string value, LibraryStore store) =>
        store.GetBlockedTerm(kind, value) is not null;

    public static void Block(BlockedTermKind kind, string value, LibraryStore store)
    {
        if (Blocklist.Fold(value).Length == 0 || IsBlocked(kind, value, store)) return;
        store.Insert(new BlockedTerm(kind, value));
        store.TrySave();
    }

    public static void Unblock(BlockedTermKind kind, string value, LibraryStore store)
    {
        if (store.GetBlockedTerm(kind, value) is { } record) store.Delete(record);
        store.TrySave();
    }
}
