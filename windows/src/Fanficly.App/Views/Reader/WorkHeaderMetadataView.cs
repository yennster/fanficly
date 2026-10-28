using System.Globalization;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// The work's metadata under the reader's title (WorkHeaderMetadata): the rating
/// badge, warning and category chips and the stats row always show; fandoms,
/// relationships, characters and tags sit behind "Tags &amp; relationships". On
/// Windows each tag is a button that opens the works with that tag (sorted by
/// kudos, like the Popular tab's tags).
/// </summary>
internal static class WorkHeaderMetadataView
{
    private enum ChipKind { Warning, Category, Fandom, Relationship, Character, Tag }

    public static FrameworkElement Build(AO3WorkSummary summary, ReaderBrushes brushes)
    {
        var root = new StackPanel { Spacing = 10 };

        // Always visible: rating, warnings, categories, stats.
        var top = UI.UI.Flow(6, 6);
        top.Children.Add(RatingBadge(summary.Rating));
        foreach (var warning in summary.Warnings) top.Children.Add(Chip(warning, ChipKind.Warning, brushes));
        foreach (var category in summary.Categories) top.Children.Add(Chip(category, ChipKind.Category, brushes));
        root.Children.Add(top);
        root.Children.Add(StatsRow(summary, brushes));
        foreach (var part in summary.Series) root.Children.Add(SeriesRow(part, brushes));

        var hasDetails = summary.Fandoms.Count > 0 || summary.Relationships.Count > 0
                         || summary.Characters.Count > 0 || summary.Freeforms.Count > 0;
        if (!hasDetails) return root;

        var details = new StackPanel { Spacing = 10, Visibility = Visibility.Collapsed };
        if (summary.Fandoms.Count > 0) details.Children.Add(MetadataRow("Fandom", summary.Fandoms, ChipKind.Fandom, brushes));
        if (summary.Relationships.Count > 0) details.Children.Add(MetadataRow("Relationship", summary.Relationships, ChipKind.Relationship, brushes));
        if (summary.Characters.Count > 0) details.Children.Add(MetadataRow("Characters", summary.Characters, ChipKind.Character, brushes));
        if (summary.Freeforms.Count > 0) details.Children.Add(MetadataRow("Tags", summary.Freeforms, ChipKind.Tag, brushes));

        var toggleText = new TextBlock { FontSize = 12, FontWeight = FontWeights.Medium, Foreground = brushes.Accent, VerticalAlignment = VerticalAlignment.Center };
        var chevron = (FontIcon)Symbols.Icon("chevron.down", 9).A11yHidden();
        chevron.Foreground = brushes.Accent;
        chevron.VerticalAlignment = VerticalAlignment.Center;
        var toggle = new Button
        {
            Content = UI.UI.HStack(4, toggleText, chevron),
            Padding = new Thickness(0, 2, 4, 2),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        brushes.StyleFlat(toggle);
        AutomationProperties.SetHelpText(toggle, "Shows the work's fandoms, relationships, characters, and tags.");
        void Refresh()
        {
            var open = details.Visibility == Visibility.Visible;
            toggleText.Text = open ? "Hide tags & relationships" : "Tags & relationships";
            chevron.Glyph = Symbols.Glyph(open ? "chevron.up" : "chevron.down");
            AutomationProperties.SetName(toggle, toggleText.Text);
        }
        toggle.Click += (_, _) =>
        {
            details.Visibility = details.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
            Refresh();
        };
        Refresh();
        root.Children.Add(toggle);
        root.Children.Add(details);
        return root;
    }

    /// <summary>"Part 2 of &lt;series&gt; ›", which opens the series, and "Next in
    /// series →" when AO3 links a next work (SeriesPartRow).</summary>
    private static FrameworkElement SeriesRow(AO3SeriesPart part, ReaderBrushes brushes)
    {
        var row = UI.UI.Flow(14, 4);
        var label = $"Part {part.Position.ToString(CultureInfo.CurrentCulture)} of {part.Title}";
        var books = Symbols.Icon("books.vertical", 11).A11yHidden();
        books.Foreground = brushes.Accent;
        books.VerticalAlignment = VerticalAlignment.Center;
        var chevron = Symbols.Icon("chevron.right", 9).A11yHidden();
        chevron.Foreground = brushes.Accent;
        chevron.VerticalAlignment = VerticalAlignment.Center;
        // A grid, not a horizontal stack, so a long series title wraps.
        var text = LinkText(label, brushes, maxLines: 2);
        var content = new Grid { ColumnSpacing = 4 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(text, 1);
        Grid.SetColumn(chevron, 2);
        content.Children.Add(books);
        content.Children.Add(text);
        content.Children.Add(chevron);
        var open = FlatLink(content, brushes);
        AutomationProperties.SetAutomationId(open, $"work.series.{part.SeriesId}");
        AutomationProperties.SetName(open, label);
        AutomationProperties.SetHelpText(open, "Shows every work in this series.");
        ToolTipService.SetToolTip(open, label);
        open.Click += (_, _) => Routes.OpenSeries(part.SeriesId, part.Title);
        row.Children.Add(open);

        if (part.NextWorkId is { } next)
        {
            var nextButton = FlatLink(LinkText("Next in series →", brushes), brushes);
            AutomationProperties.SetAutomationId(nextButton, $"work.series.{part.SeriesId}.next");
            AutomationProperties.SetName(nextButton, $"Next in {part.Title}");
            AutomationProperties.SetHelpText(nextButton,
                $"Opens part {(part.Position + 1).ToString(CultureInfo.CurrentCulture)} of this series.");
            ToolTipService.SetToolTip(nextButton, $"Next in {part.Title}");
            nextButton.Click += (_, _) => Routes.OpenWork(next);
            row.Children.Add(nextButton);
        }
        return row;
    }

    private static TextBlock LinkText(string text, ReaderBrushes brushes, int maxLines = 1) => new()
    {
        Text = text,
        FontSize = 12,
        FontWeight = FontWeights.Medium,
        Foreground = brushes.Accent,
        MaxLines = UI.UI.LineLimit(maxLines),
        TextWrapping = TextWrapping.Wrap,
        TextTrimming = TextTrimming.CharacterEllipsis,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private static Button FlatLink(UIElement content, ReaderBrushes brushes)
    {
        var button = new Button
        {
            Content = content,
            Padding = new Thickness(0, 2, 4, 2),
            MinHeight = 0,
            MinWidth = 0,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        brushes.StyleFlat(button);
        return button;
    }

    private static FrameworkElement MetadataRow(string label, IReadOnlyList<string> values, ChipKind kind, ReaderBrushes brushes)
    {
        var flow = UI.UI.Flow(6, 6);
        foreach (var value in values) flow.Children.Add(Chip(value, kind, brushes));
        return new StackPanel
        {
            Spacing = 4,
            Children =
            {
                new TextBlock { Text = label.ToUpperInvariant(), FontSize = 10.5, CharacterSpacing = 40, Foreground = brushes.Fg55 }.A11yHeading(),
                flow,
            },
        };
    }

    private static (Color Fg, string Spoken) Style(ChipKind kind, ReaderBrushes brushes) => kind switch
    {
        ChipKind.Warning => (Color.FromArgb(0xFF, 0xE5, 0x3E, 0x3E), "Warning"),
        ChipKind.Category => (brushes.Scheme == ReaderColorScheme.Dark ? Color.FromArgb(0xFF, 0x8E, 0x8C, 0xF5) : Color.FromArgb(0xFF, 0x58, 0x56, 0xD6), "Category"),
        ChipKind.Fandom => (brushes.Scheme == ReaderColorScheme.Dark ? Color.FromArgb(0xFF, 0x4C, 0xA3, 0xFF) : Color.FromArgb(0xFF, 0x00, 0x6E, 0xE6), "Fandom"),
        ChipKind.Relationship => (brushes.Scheme == ReaderColorScheme.Dark ? Color.FromArgb(0xFF, 0xFF, 0x5C, 0x8A) : Color.FromArgb(0xFF, 0xD6, 0x2E, 0x5F), "Relationship"),
        ChipKind.Character => (brushes.Scheme == ReaderColorScheme.Dark ? Color.FromArgb(0xFF, 0x4F, 0xD1, 0xD9) : Color.FromArgb(0xFF, 0x00, 0x8C, 0x94), "Character"),
        _ => (brushes.Accent.Color, "Tag"),
    };

    /// <summary>A tag chip; clicking it opens the works with that tag.</summary>
    private static Button Chip(string text, ChipKind kind, ReaderBrushes brushes)
    {
        var (fg, spoken) = Style(kind, brushes);
        var foreground = new SolidColorBrush(fg);
        var background = new SolidColorBrush(ReaderBrushes.WithOpacity(fg, 0.15));
        var chip = new Button
        {
            Content = new TextBlock { Text = text, FontSize = 12, MaxLines = 2, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis },
            Padding = new Thickness(8, 4, 8, 4),
            MinHeight = 0,
            MinWidth = 0,
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(0),
            Background = background,
            Foreground = foreground,
        };
        var r = chip.Resources;
        r["ButtonBackground"] = background;
        r["ButtonBackgroundPointerOver"] = new SolidColorBrush(ReaderBrushes.WithOpacity(fg, 0.25));
        r["ButtonBackgroundPressed"] = new SolidColorBrush(ReaderBrushes.WithOpacity(fg, 0.32));
        r["ButtonForeground"] = foreground;
        r["ButtonForegroundPointerOver"] = foreground;
        r["ButtonForegroundPressed"] = foreground;
        r["ButtonBorderBrush"] = Theme.Transparent;
        r["ButtonBorderBrushPointerOver"] = Theme.Transparent;
        r["ButtonBorderBrushPressed"] = Theme.Transparent;
        AutomationProperties.SetName(chip, $"{spoken}: {text}");
        AutomationProperties.SetHelpText(chip, "Shows works with this tag.");
        ToolTipService.SetToolTip(chip, $"Works tagged “{text}”");
        chip.Click += (_, _) => Routes.OpenFilteredWorks(Filters(text, kind), text);
        chip.ContextFlyout = Account.ContentSafetyViews.BlockMenu(BlockedTermKind.Tag, text);
        return chip;
    }

    private static AO3SearchFilters Filters(string tag, ChipKind kind)
    {
        var filters = new AO3SearchFilters { SortColumn = SortColumn.KudosCount };
        switch (kind)
        {
            case ChipKind.Fandom: filters.FandomNames = [tag]; break;
            case ChipKind.Relationship: filters.RelationshipNames = [tag]; break;
            case ChipKind.Character: filters.CharacterNames = [tag]; break;
            case ChipKind.Tag: filters.FreeformNames = [tag]; break;
            // Warnings and categories are tags too; AO3 matches other_tag_names
            // against every tag type.
            default: filters.OtherTagNames = [tag]; break;
        }
        return filters;
    }

    private static FrameworkElement RatingBadge(string rating)
    {
        var (color, abbreviation) = rating switch
        {
            "Explicit" => (Color.FromArgb(0xFF, 0xE5, 0x3E, 0x3E), "E"),
            "Mature" => (Color.FromArgb(0xFF, 0xF0, 0x8A, 0x00), "M"),
            "Teen And Up Audiences" => (Color.FromArgb(0xFF, 0xE0, 0xB0, 0x00), "T"),
            "General Audiences" => (Color.FromArgb(0xFF, 0x2E, 0xA0, 0x43), "G"),
            _ => (Color.FromArgb(0xFF, 0x8E, 0x8E, 0x93), "?"),
        };
        var badge = new Border
        {
            Child = new TextBlock { Text = abbreviation, FontSize = 12, FontWeight = FontWeights.Bold, Foreground = new SolidColorBrush(Colors.White) },
            Background = new SolidColorBrush(color),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(8, 4, 8, 4),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(badge, rating.Length == 0 ? "Rating not specified" : $"Rating: {rating}");
        ToolTipService.SetToolTip(badge, rating.Length == 0 ? "Rating not specified" : rating);
        return badge;
    }

    private static FrameworkElement StatsRow(AO3WorkSummary summary, ReaderBrushes brushes)
    {
        var culture = CultureInfo.CurrentCulture;
        var row = UI.UI.Flow(14, 4);
        // What Narrator reads for each stat, in order (the estimate's spoken form).
        var spoken = new List<string>();
        void Stat(string symbol, string value, string? spokenValue = null)
        {
            spoken.Add(spokenValue ?? value);
            var icon = Symbols.Icon(symbol, 10).A11yHidden();
            icon.Foreground = brushes.Fg75;
            icon.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 4,
                Children = { icon, new TextBlock { Text = value, FontSize = 12, Foreground = brushes.Fg75, VerticalAlignment = VerticalAlignment.Center } },
            });
        }
        Stat("text.alignleft", $"{summary.WordCount.ToString("N0", culture)} words");
        var wordsPerMinute = ReadingSpeed.WordsPerMinute(AppHost.Library);
        if (ReadingSpeed.Estimate(summary.WordCount, wordsPerMinute) is { } estimate)
            Stat("clock", estimate, ReadingSpeed.SpokenEstimate(summary.WordCount, wordsPerMinute));
        Stat("book.closed", ChapterText(summary));
        if (summary.Kudos > 0) Stat("heart", summary.Kudos.ToString("N0", culture));
        if (summary.Hits > 0) Stat("eye", summary.Hits.ToString("N0", culture));

        var stack = new StackPanel { Spacing = 4, Children = { row } };
        string? footer = null;
        if (summary.UpdatedAt is { } date)
            footer = $"Updated {date.LocalDateTime.ToString("MMMM d, yyyy", culture)} · {summary.Language}";
        else if (summary.Language.Length > 0)
            footer = summary.Language;
        if (footer is not null)
            stack.Children.Add(new TextBlock { Text = footer, FontSize = 11, Foreground = brushes.Fg55, TextWrapping = TextWrapping.Wrap });
        AutomationProperties.SetName(row, string.Join(", ", spoken));
        return stack;
    }

    private static string ChapterText(AO3WorkSummary summary)
    {
        if (summary.TotalChapters is { } total)
            return summary.ChapterCount == total
                ? $"{total} ch{(total == 1 ? "" : "s")} · complete"
                : $"{summary.ChapterCount} / {total} · WIP";
        return $"{summary.ChapterCount} / ? · WIP";
    }
}
