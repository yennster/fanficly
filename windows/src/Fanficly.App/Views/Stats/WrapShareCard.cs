using System.Globalization;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
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

    /// <summary>The app icon for the footer (the Swift card's `AppIconMark`),
    /// decoded before the card is built so <c>RenderTargetBitmap</c> never
    /// captures it half-loaded. Null when it can't be read; the footer then
    /// shows the text alone.</summary>
    public static async Task<ImageSource?> LoadAppIconAsync()
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Assets", "Square44x44Logo.targetsize-96.png");
            using var file = File.OpenRead(path);
            var icon = new BitmapImage();
            await icon.SetSourceAsync(file.AsRandomAccessStream());
            return icon;
        }
        catch (Exception e)
        {
            AppHost.Log($"Loading the wrap-up card's icon failed: {e.Message}");
            return null;
        }
    }

    /// <param name="goal">This year's goal, shown as a ring row when set and the
    /// card covers this year.</param>
    /// <param name="year">The goal's year, named on the card since the All Time card shows it too.</param>
    /// <param name="appIcon">The app icon from <see cref="LoadAppIconAsync"/>.</param>
    public static FrameworkElement Build(string scopeTitle, ReadingStatsSummary summary, ReadingGoalProgress? goal = null, int year = 0, ImageSource? appIcon = null)
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
        // Stories counts finished works only; the lists below count every work
        // opened, so each number says which it is.
        stats.Children.Add(BigStat(summary.StoriesRead.ToString(CultureInfo.CurrentCulture), summary.StoriesRead == 1 ? "story finished" : "stories finished").Col(0));
        stats.Children.Add(BigStat(StatsFormat.FormatDuration(summary.TotalSeconds), "read").Col(1));
        stats.Children.Add(BigStat(StatsFormat.FormatWords(summary.TotalWords), "words read").Col(2));
        root.Children.Add(stats.Row(1));

        // The goal row and the two lists share rows 2–3 in one stack, so an
        // absent block adds no row spacing (SwiftUI's VStack). A goal row takes
        // a list line from each block so the card keeps its size.
        var blocks = UI.UI.VStack(20,
            goal is null ? null : GoalRow(goal, year),
            summary.TopFandoms.Count > 0 ? ListBlock("Top Fandoms", summary.TopFandoms.Take(goal is null ? 4 : 3)) : null,
            summary.TopRelationships.Count > 0 ? ListBlock("Top Ships", summary.TopRelationships.Take(goal is null ? 3 : 2)) : null);
        root.Children.Add(blocks.Row(2));
        Grid.SetRowSpan(blocks, 2);

        // The app icon itself, in its tile's rounded corners with a faint edge
        // so it doesn't melt into the indigo canvas.
        var footer = UI.UI.HStack(6,
            appIcon is null ? null : new Border
            {
                Width = 18,
                Height = 18,
                CornerRadius = new CornerRadius(4),
                BorderBrush = White(0x59),
                BorderThickness = new Thickness(0.5),
                VerticalAlignment = VerticalAlignment.Center,
                Background = new ImageBrush { ImageSource = appIcon, Stretch = Stretch.UniformToFill },
            }.A11yHidden(),
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

    private static FrameworkElement GoalRow(ReadingGoalProgress goal, int year)
    {
        var ring = GoalRing.Build(goal.Fraction, 36, 5, White(0x33), White(0xFF));
        var text = UI.UI.VStack(1,
            new TextBlock
            {
                Text = $"{goal.Finished} of {goal.Goal} {(goal.Goal == 1 ? "story" : "stories")} · {(year > 0 ? year : DateTimeOffset.Now.Year)} goal",
                FontSize = 13,
                FontWeight = FontWeights.SemiBold,
                Foreground = White(0xFF),
                FontFamily = Theme.UIFont,
            },
            new TextBlock { Text = goal.PaceLabel, FontSize = 11, Foreground = White(0xB3), FontFamily = Theme.UIFont });
        text.VerticalAlignment = VerticalAlignment.Center;
        return UI.UI.HStack(12, ring, text);
    }

    private static FrameworkElement ListBlock(string title, IEnumerable<ReadingTagCount> items)
    {
        var header = UI.UI.Grid("*,Auto", columnSpacing: 8);
        header.Children.Add(HeaderText(title.ToUpperInvariant()).Col(0));
        header.Children.Add(HeaderText("STORIES OPENED").Col(1));
        var stack = UI.UI.VStack(6, header);
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

    private static TextBlock HeaderText(string text) =>
        new() { Text = text, FontSize = 11, FontWeight = FontWeights.Bold, Foreground = White(0x99), CharacterSpacing = 40, FontFamily = Theme.UIFont };
}
