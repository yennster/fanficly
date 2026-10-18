using System.Globalization;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;

namespace Fanficly.App.Views.Stats;

/// <summary>
/// The portrait "My Reading" wrap-up card rendered to an image for sharing
/// (WrapShareCard): 360×480 on the indigo brand canvas — the period, stories
/// / time / words, top fandoms and ships, "Made with Fanficly". Its colours
/// are fixed (it's an image, the same in light and dark), like the Swift card.
/// </summary>
public static class WrapShareCard
{
    public const double Width = 360;
    public const double Height = 480;

    private static SolidColorBrush White(byte alpha) => new(Color.FromArgb(alpha, 0xFF, 0xFF, 0xFF));

    public static FrameworkElement Build(string scopeTitle, ReadingStatsSummary summary)
    {
        var brand = Theme.BrandLight; // #3B2E8C, the App Store canvas indigo
        var background = new LinearGradientBrush
        {
            StartPoint = new Point(0, 0),
            EndPoint = new Point(1, 1),
            GradientStops =
            {
                new GradientStop { Color = brand, Offset = 0 },
                new GradientStop { Color = Color.FromArgb(0xFF, 0x2E, 0x24, 0x6D), Offset = 0.5 },
                new GradientStop { Color = Color.FromArgb(0xFF, 0x1A, 0x14, 0x40), Offset = 1 },
            },
        };

        var root = UI.UI.Grid("*", "Auto,Auto,Auto,Auto,*,Auto", rowSpacing: 20);

        var header = UI.UI.VStack(2,
            new TextBlock { Text = "My Reading", FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = White(0xB3), FontFamily = Theme.UIFont },
            new TextBlock
            {
                Text = scopeTitle,
                FontSize = 34,
                FontWeight = FontWeights.Black,
                FontFamily = Theme.SerifDisplayFont,
                Foreground = White(0xFF),
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.NoWrap,
            });
        root.Children.Add(header.Row(0));

        var stats = UI.UI.Grid("*,*,*", columnSpacing: 14);
        stats.Children.Add(BigStat(summary.StoriesRead.ToString(CultureInfo.CurrentCulture), summary.StoriesRead == 1 ? "story" : "stories").Col(0));
        stats.Children.Add(BigStat(StatsFormat.FormatDuration(summary.TotalSeconds), "read").Col(1));
        stats.Children.Add(BigStat(StatsFormat.FormatWords(summary.TotalWords), "words").Col(2));
        root.Children.Add(stats.Row(1));

        if (summary.TopFandoms.Count > 0) root.Children.Add(ListBlock("Top Fandoms", summary.TopFandoms.Take(4)).Row(2));
        if (summary.TopRelationships.Count > 0) root.Children.Add(ListBlock("Top Ships", summary.TopRelationships.Take(3)).Row(3));

        var footer = UI.UI.HStack(6,
            Symbols.Icon("book.pages", 12).Also(i => { i.Foreground = White(0xD9); i.VerticalAlignment = VerticalAlignment.Center; }),
            new TextBlock { Text = "Made with Fanficly", FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = White(0xD9), FontFamily = Theme.UIFont });
        root.Children.Add(footer.Row(5));

        return new Border
        {
            Width = Width,
            Height = Height,
            Padding = new Thickness(28),
            Background = background,
            Child = root,
            RequestedTheme = ElementTheme.Dark,
        };
    }

    private static FrameworkElement BigStat(string value, string label)
    {
        var valueText = new TextBlock
        {
            Text = value,
            FontSize = 26,
            FontWeight = FontWeights.Bold,
            FontFamily = Theme.DisplayFont,
            Foreground = White(0xFF),
            TextWrapping = TextWrapping.NoWrap,
        };
        // minimumScaleFactor(0.5): shrink long values ("123h 45m") to fit.
        var fit = new Viewbox { Child = valueText, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, HorizontalAlignment = HorizontalAlignment.Left, Height = 34 };
        return UI.UI.VStack(1, fit,
            new TextBlock { Text = label, FontSize = 11, Foreground = White(0xB3), FontFamily = Theme.UIFont });
    }

    private static FrameworkElement ListBlock(string title, IEnumerable<ReadingTagCount> items)
    {
        var stack = UI.UI.VStack(6,
            new TextBlock { Text = title.ToUpperInvariant(), FontSize = 11, FontWeight = FontWeights.Bold, Foreground = White(0x99), CharacterSpacing = 40, FontFamily = Theme.UIFont });
        foreach (var item in items)
        {
            var row = UI.UI.Grid("*,Auto", columnSpacing: 8);
            row.Children.Add(new TextBlock
            {
                Text = item.Name,
                FontSize = 13,
                FontWeight = FontWeights.Medium,
                Foreground = White(0xFF),
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.NoWrap,
                FontFamily = Theme.UIFont,
            }.Col(0));
            row.Children.Add(new TextBlock
            {
                Text = item.Count.ToString(CultureInfo.CurrentCulture),
                FontSize = 13,
                Foreground = White(0xB3),
                FontFamily = Theme.UIFont,
            }.Col(1));
            stack.Children.Add(row);
        }
        return stack;
    }
}
