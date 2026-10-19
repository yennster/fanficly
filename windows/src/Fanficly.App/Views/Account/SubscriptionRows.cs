using System.Globalization;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Account;

/// <summary>Row content for the Subscriptions tab: <see cref="Subscription"/>
/// (SubscriptionRow) for records without a cached work, and <see cref="CachedWork"/>
/// (the Library row's look) when the subscribed work is in the library.</summary>
internal static class SubscriptionRows
{
    /// <summary>"Work" is AO3's term for a fic — show something friendlier.</summary>
    public static string KindLabel(string kind) => kind switch
    {
        "work" => "Story",
        "series" => "Series",
        "user" => "Author",
        _ => kind.Length == 0 ? kind : CultureInfo.CurrentCulture.TextInfo.ToTitleCase(kind),
    };

    public static string KindSymbol(string kind) => kind switch
    {
        "work" => "doc.text",
        "series" => "books.vertical",
        "user" => "person",
        _ => "bell",
    };

    /// <summary>SubscriptionRow: title, author, kind · chapters · checked … ago.</summary>
    public static (FrameworkElement Content, string AccessibleName) Subscription(SubscriptionRecord sub)
    {
        var parts = new List<string> { sub.DisplayName };
        var stack = UI.UI.VStack(4, UI.UI.Text(sub.DisplayName, Theme.Style.Headline));
        if (sub.AuthorName.Length > 0)
        {
            stack.Children.Add(UI.UI.Secondary($"by {sub.AuthorName}", maxLines: UI.UI.LineLimit(1)));
            parts.Add($"by {sub.AuthorName}");
        }
        // Wraps onto a second line when it doesn't fit (large text, a narrow window).
        var meta = UI.UI.Flow(8, 2, AccountKit.KindLabel(KindSymbol(sub.Kind), KindLabel(sub.Kind)));
        parts.Add(KindLabel(sub.Kind));
        if (sub.Kind == "work" && sub.LastSeenChapterCount is { } count)
        {
            var text = $"{count} chapter{(count == 1 ? "" : "s")}";
            meta.Children.Add(UI.UI.Caption(text));
            parts.Add(text);
        }
        if (sub.LastCheckedAt is { } checkedAt)
        {
            var text = AccountKit.CheckedAgo(checkedAt);
            meta.Children.Add(UI.UI.Caption(text));
            parts.Add(text);
        }
        stack.Children.Add(meta);
        return (stack, string.Join(", ", parts));
    }

    /// <summary>The Library row for a work in the library: title with pinned /
    /// starred / downloaded badges, author, first fandom, rating · words ·
    /// chapters, and the reading-progress strip for a started work.</summary>
    public static (FrameworkElement Content, string AccessibleName) CachedWork(Work work, string? extraCaption = null)
    {
        var parts = new List<string> { work.Title, $"by {work.AuthorName}" };
        var titleRow = UI.UI.Grid("*,Auto", columnSpacing: 8);
        titleRow.Children.Add(UI.UI.Text(work.Title, Theme.Style.Headline, maxLines: UI.UI.LineLimit(2)).Col(0));
        var badges = UI.UI.HStack(5);
        void Badge(string symbol, Microsoft.UI.Xaml.Media.Brush brush, string label)
        {
            badges.Children.Add(UI.UI.Icon(symbol, 11, brush));
            parts.Add(label);
        }
        if (work.IsPinned) Badge("pin.fill", Theme.Accent, "Pinned");
        if (work.IsStarred) Badge("star.fill", Theme.Warning, "Starred");
        if (WorkPersistence.EpubPath(work.Ao3Id) is not null) Badge("arrow.down.circle.fill", Theme.Success, "Downloaded");
        badges.VerticalAlignment = VerticalAlignment.Top;
        badges.Margin = new Thickness(0, 3, 0, 0);
        titleRow.Children.Add(badges.Col(1));

        var stack = UI.UI.VStack(5, titleRow, UI.UI.Secondary($"by {work.AuthorName}", maxLines: UI.UI.LineLimit(1)));
        if (work.Fandoms.Count > 0)
        {
            var first = work.Fandoms[0];
            var shortName = first.Split(" - ")[0];
            var label = work.Fandoms.Count > 1 ? $"{shortName}  +{work.Fandoms.Count - 1}" : shortName;
            stack.Children.Add(AccountKit.KindLabel(FandomCatalog.Symbol(first), label));
            parts.Add(label);
        }

        var items = new List<string>();
        if (work.Rating.Length > 0) items.Add(work.Rating);
        if (work.WordCount > 0) items.Add($"{work.WordCount.ToString("N0", CultureInfo.CurrentCulture)} words");
        if (work.TotalChapters is { } total)
            items.Add(work.ChapterCount == total ? $"{total} ch complete" : $"{work.ChapterCount}/{total} WIP");
        else if (work.ChapterCount > 0)
            items.Add($"{work.ChapterCount}/? WIP");
        if (items.Count > 0)
        {
            var flow = UI.UI.Flow(6, 5);
            foreach (var item in items)
                flow.Children.Add(UI.UI.Chip(item, Theme.SubtleFill, Theme.TextSecondary, fontSize: 11));
            stack.Children.Add(flow);
            parts.AddRange(items);
        }

        if (work.LastReadProgress is { } raw && raw > 0)
        {
            var progress = Math.Clamp(raw, 0, 1);
            var finished = progress >= 0.99 || (work.IsComplete && progress >= 0.95);
            var bar = new ProgressBar { Value = progress * 100, Maximum = 100, MinHeight = 3 }.A11yHidden();
            if (finished) bar.Foreground = Theme.Success;
            // At large text sizes the last-read date goes under the percentage.
            var large = UI.UI.IsLargeText;
            var line = large ? UI.UI.Grid("*", "Auto,Auto", rowSpacing: 2) : UI.UI.Grid("*,Auto", columnSpacing: 6);
            var left = UI.UI.HStack(6);
            if (finished)
            {
                left.Children.Add(UI.UI.Icon("checkmark.circle.fill", 11, Theme.Success).Also(i => i.VerticalAlignment = VerticalAlignment.Center));
                left.Children.Add(UI.UI.Text("Finished", Theme.Style.Caption2, Theme.Success));
                parts.Add("Finished reading");
            }
            else
            {
                var pct = (int)(progress * 100);
                left.Children.Add(UI.UI.Text($"{pct}% read", Theme.Style.Caption2, Theme.TextSecondary));
                parts.Add($"{pct} percent read");
                if (work.LastReadChapter is { } chapter && (work.TotalChapters ?? 0) > 1)
                {
                    left.Children.Add(UI.UI.Text($"· Ch {chapter}", Theme.Style.Caption2, Theme.TextSecondary));
                    parts.Add($"chapter {chapter}");
                }
            }
            line.Children.Add(left.Col(0));
            if (work.LastReadAt is { } lastRead)
            {
                var when = AccountKit.RelativeNamed(lastRead);
                line.Children.Add(UI.UI.Text(when, Theme.Style.Caption2, Theme.TextSecondary, wrap: false).Col(large ? 0 : 1).Row(large ? 1 : 0));
                parts.Add($"last read {when}");
            }
            stack.Children.Add(UI.UI.VStack(3, bar, line).Also(s => s.Margin = new Thickness(0, 2, 0, 0)));
        }

        if (extraCaption is not null)
        {
            stack.Children.Add(UI.UI.Caption(extraCaption));
            parts.Add(extraCaption);
        }
        return (stack, string.Join(", ", parts));
    }
}
