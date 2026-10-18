using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Fanficly.App.Views.Search;

/// <summary>ChipView's two looks: a tag or filter that's included, or one left out.</summary>
public enum ChipKind { Include, Exclude }

/// <summary>One active filter shown as a removable chip (SearchView.ActiveChip).</summary>
internal sealed record ActiveChip(string Id, string Label, ChipKind Kind, Action<AO3SearchFilters> Remove);

internal static class SearchChips
{
    /// <summary>Every active filter as a removable chip (keywords stay in the box),
    /// in the Swift view's order.</summary>
    public static List<ActiveChip> For(AO3SearchFilters f)
    {
        var chips = new List<ActiveChip>();
        void List(IEnumerable<string> names, string key, Func<AO3SearchFilters, List<string>> path, string prefix = "", ChipKind kind = ChipKind.Include)
        {
            foreach (var name in names.ToList())
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

    private static SolidColorBrush? _dangerSubtle;

    /// <summary>The exclude chip's fill: the palette's red at the include chip's
    /// strength, kept in step with light / dark / high contrast.</summary>
    public static SolidColorBrush DangerSubtle
    {
        get
        {
            if (_dangerSubtle is null)
            {
                _dangerSubtle = new SolidColorBrush();
                UpdateDangerSubtle();
                Theme.Changed += UpdateDangerSubtle;
            }
            return _dangerSubtle;
        }
    }

    private static void UpdateDangerSubtle()
    {
        if (_dangerSubtle is null) return;
        if (Theme.IsHighContrast) { _dangerSubtle.Color = Theme.AccentSubtle.Color; return; }
        var c = Theme.Danger.Color;
        _dangerSubtle.Color = Color.FromArgb(Theme.Current == ElementTheme.Dark ? (byte)0x40 : (byte)0x24, c.R, c.G, c.B);
    }

    /// <summary>ChipView: a token (Windows' tokenizing text box style: 4 px
    /// corners and a hairline edge, rather than the Mac's capsule) with the
    /// label and, when removable, a small ✕.
    /// The whole chip is the button (tapping it removes the filter).</summary>
    public static Button RemovableChip(ActiveChip chip, bool hasSearched, Action onRemove)
    {
        var foreground = chip.Kind == ChipKind.Include ? Theme.Accent : Theme.Danger;
        var background = chip.Kind == ChipKind.Include ? Theme.AccentSubtle : DangerSubtle;
        var label = new TextBlock
        {
            Text = chip.Label,
            FontSize = 12,
            Foreground = foreground,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 360,
        };
        var x = (FontIcon)UI.UI.Icon("xmark", 9, foreground);
        x.Opacity = 0.6;
        x.FontWeight = FontWeights.Bold;
        x.VerticalAlignment = VerticalAlignment.Center;
        var button = new Button
        {
            Content = UI.UI.HStack(6, label, x),
            Background = background,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(8, 3, 7, 4),
            MinHeight = 0,
            MinWidth = 0,
        };
        AutomationProperties.SetName(button, $"Remove filter: {chip.Label}");
        AutomationProperties.SetHelpText(button, hasSearched ? "Removes this filter and searches again." : "Removes this filter.");
        AutomationProperties.SetAutomationId(button, $"search.chip.{chip.Id}");
        ToolTipService.SetToolTip(button, $"Remove {chip.Label}");
        button.Click += (_, _) => onRemove();
        return button;
    }

    /// <summary>One suggestion in the row under the box: a tinted token with the
    /// suggestion's icon and label. Clicking it doesn't take focus from the box
    /// (typing carries on); the keyboard still reaches it (↓ from the box, ← →).</summary>
    public static Button SuggestionButton(SuggestionCandidate candidate, Action onApply)
    {
        var s = candidate.Suggestion;
        var content = UI.UI.Label(s.SystemImage, s.Label, Theme.Style.Subheadline, Theme.Accent, spacing: 6, maxLines: UI.UI.LineLimit(1));
        var button = new Button
        {
            Content = content,
            Background = Theme.AccentSubtle,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(8, 4, 9, 5),
            MinHeight = 0,
            MinWidth = 0,
            AllowFocusOnInteraction = false,
        };
        AutomationProperties.SetName(button, $"Add filter: {s.Label}");
        AutomationProperties.SetAutomationId(button, $"search.suggestion.{candidate.Id}");
        button.Click += (_, _) => onApply();
        return button;
    }
}
