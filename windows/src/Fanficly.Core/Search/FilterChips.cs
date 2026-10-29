namespace Fanficly.Core;

/// <summary>ChipView's two looks: a tag or filter that's included, or one left out.</summary>
public enum ChipKind { Include, Exclude }

/// <summary>One active filter shown as a removable chip (FilterChip.swift).</summary>
public sealed record ActiveChip(string Id, string Label, ChipKind Kind, Action<AO3SearchFilters> Remove);

/// <summary>The active-filter chips Search's chip row and Browse's header both
/// show, so every field a search or saved filter can set is visible, removable,
/// and worded the same in both (#157).</summary>
public static class FilterChips
{
    /// <summary>Every active filter in <paramref name="f"/> as a removable chip
    /// (keywords stay in the box), in the Swift app's order.
    /// <paramref name="subject"/> is the tag a Browse screen is about (its fandom,
    /// ship or character): it's the screen's title, so it gets no chip.</summary>
    public static List<ActiveChip> For(AO3SearchFilters f, string? subject = null)
    {
        var chips = new List<ActiveChip>();
        void List(IEnumerable<string> names, string key, Func<AO3SearchFilters, List<string>> path, string prefix = "", ChipKind kind = ChipKind.Include)
        {
            foreach (var name in names.Where(n => n != subject).ToList())
                chips.Add(new ActiveChip($"{key}|{name}", prefix + name, kind, x => path(x).RemoveAll(n => n == name)));
        }
        if (f.Title.Length > 0) chips.Add(new("title", $"Title: {f.Title}", ChipKind.Include, x => x.Title = ""));
        if (f.Creators.Length > 0) chips.Add(new("creators", $"By {f.Creators}", ChipKind.Include, x => x.Creators = ""));
        List(f.OtherTagNames, "tag", x => x.OtherTagNames);
        List(f.FandomNames, "fandom", x => x.FandomNames);
        List(f.RelationshipNames, "ship", x => x.RelationshipNames);
        List(f.CharacterNames, "character", x => x.CharacterNames);
        List(f.FreeformNames, "freeform", x => x.FreeformNames);
        List(f.ExcludedTagNames, "-tag", x => x.ExcludedTagNames, "Not ", ChipKind.Exclude);
        List(f.ExcludedFreeforms, "exclude", x => x.ExcludedFreeforms, "Not ", ChipKind.Exclude);
        foreach (var rating in f.Ratings.OrderBy(r => r.RawValue(), StringComparer.Ordinal))
            chips.Add(new($"rating|{rating.RawValue()}", $"Rated {rating.DisplayName()}", ChipKind.Include, x => x.Ratings.Remove(rating)));
        foreach (var warning in f.Warnings.OrderBy(w => w.RawValue(), StringComparer.Ordinal))
            chips.Add(new($"warning|{warning.RawValue()}", warning.DisplayName(), ChipKind.Include, x => x.Warnings.Remove(warning)));
        foreach (var category in f.Categories.OrderBy(c => c.RawValue(), StringComparer.Ordinal))
            chips.Add(new($"category|{category.RawValue()}", category.DisplayName(), ChipKind.Include, x => x.Categories.Remove(category)));
        if (f.Complete != TriState.Any)
            chips.Add(new("complete", f.Complete == TriState.Yes ? "Complete works" : "Works in progress", ChipKind.Include, x => x.Complete = TriState.Any));
        if (f.Crossover != TriState.Any)
            chips.Add(new("crossover", f.Crossover == TriState.Yes ? "Crossovers" : "No crossovers", ChipKind.Include, x => x.Crossover = TriState.Any));
        if (f.SingleChapter) chips.Add(new("oneshot", "One-shots", ChipKind.Include, x => x.SingleChapter = false));
        if (f.WordCount.Length > 0)
            chips.Add(new("words", AO3SearchFilters.WordCountLabel(f.WordCount), ChipKind.Include, x => x.WordCount = ""));
        if (f.LanguageId.Length > 0)
        {
            var name = SearchSyntax.LanguageNames.TryGetValue(f.LanguageId, out var n) ? n : f.LanguageId;
            chips.Add(new("lang", $"In {name}", ChipKind.Include, x => x.LanguageId = ""));
        }
        if (f.KudosCount.Length > 0) chips.Add(new("kudos", $"Kudos {f.KudosCount}", ChipKind.Include, x => x.KudosCount = ""));
        if (f.Hits.Length > 0) chips.Add(new("hits", $"Hits {f.Hits}", ChipKind.Include, x => x.Hits = ""));
        if (f.CommentsCount.Length > 0) chips.Add(new("comments", $"Comments {f.CommentsCount}", ChipKind.Include, x => x.CommentsCount = ""));
        if (f.BookmarksCount.Length > 0) chips.Add(new("bookmarks", $"Bookmarks {f.BookmarksCount}", ChipKind.Include, x => x.BookmarksCount = ""));
        if (f.RevisedAt.Length > 0) chips.Add(new("updated", $"Updated {f.RevisedAt}", ChipKind.Include, x => x.RevisedAt = ""));
        return chips;
    }
}
