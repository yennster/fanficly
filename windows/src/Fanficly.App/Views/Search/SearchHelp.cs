using Fanficly.App.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Fanficly.App.Views.Search;

/// <summary>SearchHelpView: how search works, as a sheet.</summary>
internal static class SearchHelp
{
    private static FontFamily? _mono;
    private static FontFamily Mono => _mono ??= new FontFamily("Cascadia Mono,Consolas");

    public static Task ShowAsync() => Dialogs.SheetAsync("Search Tips", Build(), close: "Done", width: 600);

    private static FrameworkElement Build()
    {
        var stack = UI.UI.VStack(20,
            UI.UI.Text("How search works", Theme.Style.Title2).A11yHeading(),
            UI.UI.Secondary("Type anything — AO3 searches titles, summaries, tags and authors, and a work has to match every word. A few distinctive words beat a long sentence."),
            UI.UI.Divider(),
            Section("Select a suggestion for an exact tag", "tag.fill", Theme.Accent,
            [
                ("teen wolf", "Suggests the Teen Wolf (TV) fandom — select it to filter by the tag instead of the words."),
                ("derek stiles", "Suggests their ship and characters."),
                ("slow burn", "Suggests the Slow Burn tag."),
            ]),
            Section("Filters", "line.3.horizontal.decrease.circle.fill", Theme.Accent,
            [
                ("Filters button", "Rating, warnings, categories, complete or in progress, length, language, sort and more."),
            ]),
            Section("Shortcuts you can type", "bolt.fill", Theme.Warning,
            [
                ("complete · wip · one shot", "Completion and single-chapter works."),
                ("explicit · nsfw · sfw", "Ratings (\"teen\" and \"mature\" stay words — use a suggestion or Filters)."),
                ("m/m · f/f · f/m", "Categories."),
                ("under 10k · over 50k · between 10k and 50k", "Word count."),
                ("in spanish · no crossovers · no mcd", "Language, crossovers, and leaving out Major Character Death."),
            ]),
            Section("Precise searching", "scope", Theme.Success,
            [
                ("\"enemies to lovers\"", "An exact phrase."),
                ("-angst", "Leave out works mentioning a word."),
                ("title:\"The Long Way Home\"", "Search titles only."),
                ("by:astolat", "Works by an author."),
                ("tag:\"Slow Burn\" -tag:\"Major Character Death\"", "Include or exclude an exact tag."),
            ]),
            UI.UI.Secondary("Keyboard: Ctrl+F or F3 goes to the search box, Enter searches, ↓ moves to the suggestions and Esc dismisses them.", Theme.Style.Footnote));
        stack.Padding = new Thickness(0, 0, 0, 8);
        return stack;
    }

    private static StackPanel Section(string title, string symbol, Brush color, (string Query, string Description)[] examples)
    {
        var header = UI.UI.HStack(8,
            UI.UI.Icon(symbol, 15, color).Also(i => i.VerticalAlignment = VerticalAlignment.Center),
            UI.UI.Text(title, Theme.Style.Headline).A11yHeading());
        var list = UI.UI.VStack(8);
        foreach (var (query, description) in examples)
        {
            var code = new Border
            {
                Child = new TextBlock
                {
                    Text = query,
                    FontFamily = Mono,
                    FontSize = 13,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    IsTextSelectionEnabled = true,
                    TextWrapping = TextWrapping.Wrap,
                },
                Background = Theme.SubtleFill,
                BorderBrush = Theme.CardStroke,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(8, 4, 8, 4),
                HorizontalAlignment = HorizontalAlignment.Left,
            };
            list.Children.Add(UI.UI.VStack(4, code, UI.UI.Caption(description)).Also(s => s.Margin = new Thickness(8, 0, 0, 0)));
        }
        return UI.UI.VStack(12, header, list).Also(s => s.Padding = new Thickness(0, 8, 0, 8));
    }
}
