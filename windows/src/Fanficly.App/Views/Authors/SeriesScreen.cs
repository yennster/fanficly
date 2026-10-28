using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.App.Views.Account;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Authors;

/// <summary>
/// A series (SeriesView): its title, creator, work count and description above
/// its works in series order, paginated with infinite scroll like an author's
/// works. Opened from "Part 2 of …" in the reader's work header.
/// </summary>
public sealed class SeriesScreen : Screen
{
    private readonly int _seriesId;
    private readonly string _fallbackTitle;
    private readonly PagedWorksList _works;
    private string[] _creators = [];

    public SeriesScreen(int seriesId, string title)
    {
        _seriesId = seriesId;
        _fallbackTitle = title;
        Title = title;
        _works = new PagedWorksList(
            FetchPageAsync,
            new PagedWorksTexts(
                Loading: "Loading…",
                ErrorTitle: "Couldn't load series",
                EmptySymbol: "books.vertical",
                EmptyTitle: "No works to show",
                EmptyMessage: "This series has no works you can open.",
                FilteredMessage: "Every work in this series is filtered out by your content settings."),
            automationId: "series.works",
            listName: $"Works in {title}",
            // Opening a series is asking for its creators, like an author's
            // page, so blocking them doesn't empty it; blocked tags still apply.
            blocklist: () => Blocklist.From(AppHost.Library).Lifting([], _creators))
        {
            // A first page of unrevealed or filtered-out works must not end the list.
            LoadsPastHiddenPages = true,
        };
    }

    protected override FrameworkElement Build()
    {
        _ = _works.LoadFirstAsync();
        return _works.Element;
    }

    public override void OnAppearing()
    {
        // Content settings may have changed underneath (Settings, Hide this work).
        if (IsBuilt) _works.Render();
    }

    public override void OnRemoved() => _works.Cancel();

    private async Task<AO3SearchResults> FetchPageAsync(int page, CancellationToken ct)
    {
        var series = await AppHost.Client.FetchSeriesAsync(_seriesId, page, ct);
        if (page == 1 && !ct.IsCancellationRequested)
        {
            if (series.Title.Length > 0) Title = series.Title;
            _creators = [series.CreatorUsername, .. series.Creator.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)];
            _works.Header = Header(series);
        }
        return new AO3SearchResults(series.Works, series.TotalPages, series.CurrentPage);
    }

    private FrameworkElement Header(AO3Series series)
    {
        // The list already pads and caps its content; this only spaces the header.
        var stack = new StackPanel { Spacing = 6, Margin = new Thickness(0, 8, 0, 8) };
        stack.Children.Add(UI.UI.Text(series.Title.Length > 0 ? series.Title : _fallbackTitle, Theme.Style.Title2).A11yHeading());

        if (series.Creator.Length > 0)
        {
            if (series.CreatorUsername.Length > 0)
            {
                var author = new AuthorRef(series.CreatorUsername, series.Creator);
                var byline = new Button
                {
                    Content = UI.UI.Text($"by {series.Creator}", Theme.Style.Subheadline, Theme.Accent),
                    Padding = new Thickness(0, 2, 4, 2),
                    MinHeight = 0,
                    HorizontalAlignment = HorizontalAlignment.Left,
                };
                UI.UI.ApplyKind(byline, UI.UI.ButtonKind.Subtle);
                AutomationProperties.SetName(byline, $"by {series.Creator}");
                AutomationProperties.SetHelpText(byline, "Shows this author's other works.");
                byline.Click += (_, _) => Routes.OpenAuthor(author);
                stack.Children.Add(byline);
            }
            else
            {
                stack.Children.Add(UI.UI.Secondary($"by {series.Creator}"));
            }
        }

        var count = series.WorkCount ?? series.Works.Count;
        var works = count == 1 ? "1 work" : $"{count.ToString("N0", System.Globalization.CultureInfo.CurrentCulture)} works";
        stack.Children.Add(UI.UI.Secondary($"{works} · {(series.IsComplete ? "complete" : "in progress")}", Theme.Style.Footnote));

        if (series.DescriptionHtml.Length > 0)
            stack.Children.Add(RichText.Html(series.DescriptionHtml, selectable: true));

        stack.Children.Add(UI.UI.SectionHeader("Works in order"));
        return stack;
    }
}
