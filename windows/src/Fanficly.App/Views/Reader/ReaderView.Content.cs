using System.Collections.Concurrent;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Reader;

/// <summary>The pieces every reading mode draws: the work's title header, the
/// chapter header, and each chapter's rendered paragraphs.</summary>
internal sealed partial class ReaderView
{
    private readonly ConcurrentDictionary<(int Chapter, bool Images), IReadOnlyList<ReaderRichText>> _paragraphs = new();

    /// <summary>A chapter's paragraphs as rendered (ChapterContentView's
    /// <c>convertParagraphs</c>) with the current images setting. Index-aligned
    /// with anchors, narration and page atoms. Kept per reader, so a long work
    /// never thrashes Core's shared conversion cache. Thread-safe.</summary>
    private IReadOnlyList<ReaderRichText> Paragraphs(int chapterIndex) => Paragraphs(chapterIndex, ShowImages);

    private IReadOnlyList<ReaderRichText> Paragraphs(int chapterIndex, bool includeImages)
    {
        if (_paragraphs.TryGetValue((chapterIndex, includeImages), out var cached)) return cached;
        var chapter = ChapterAt(chapterIndex);
        IReadOnlyList<ReaderRichText> list = chapter is null ? [] : HTMLToAttributed.ConvertParagraphs(chapter.BodyHtml, includeImages);
        _paragraphs[(chapterIndex, includeImages)] = list;
        return list;
    }

    /// <summary>The work's header above the first chapter (titleHeader): title,
    /// byline (a link to the author's works), metadata, summary and a rule.</summary>
    private FrameworkElement TitleHeader()
    {
        var t = CurrentTypography();
        var font = ReaderText.Font(t.Family);
        var stack = new StackPanel { Spacing = 14 };
        stack.Children.Add(new TextBlock
        {
            Text = _title,
            FontFamily = font,
            FontSize = t.FontSize + 14,
            FontWeight = FontWeights.Bold,
            TextWrapping = TextWrapping.Wrap,
            Foreground = _brushes.Foreground,
        }.A11yHeading());

        if (_author.Length > 0)
        {
            if (_authorUsername.Length == 0)
            {
                stack.Children.Add(new TextBlock { Text = $"by {_author}", FontSize = t.FontSize, Foreground = _brushes.Fg65, TextWrapping = TextWrapping.Wrap });
            }
            else
            {
                var text = new TextBlock { Text = $"by {_author}", FontSize = t.FontSize, Foreground = _brushes.Accent, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
                var chevron = Symbols.Icon("chevron.right", Math.Max(9, Math.Round(t.FontSize * 0.55))).A11yHidden();
                chevron.Foreground = _brushes.Accent;
                chevron.VerticalAlignment = VerticalAlignment.Center;
                var byline = new Button
                {
                    Content = UI.UI.HStack(4, text, chevron),
                    Padding = new Thickness(0, 2, 6, 2),
                    MinHeight = 0,
                    HorizontalAlignment = HorizontalAlignment.Left,
                };
                _brushes.StyleFlat(byline);
                AutomationProperties.SetName(byline, $"by {_author}");
                AutomationProperties.SetHelpText(byline, "Shows this author's other works.");
                ToolTipService.SetToolTip(byline, $"More by {_author}");
                var author = new AuthorRef(_authorUsername, _author);
                byline.Click += (_, _) => Routes.OpenAuthor(author);
                stack.Children.Add(byline);
            }
        }

        if (_summary is { } summary)
        {
            stack.Children.Add(WorkHeaderMetadataView.Build(summary, _brushes));
            if (summary.Summary.Length > 0)
            {
                var body = RichText.Html(summary.Summary, Theme.Style.Body, foreground: _brushes.Fg85);
                body.FontFamily = font;
                body.FontSize = Math.Max(10, t.FontSize - 1);
                body.TextWrapping = TextWrapping.Wrap;
                body.IsTextSelectionEnabled = false;
                stack.Children.Add(new StackPanel
                {
                    Spacing = 4,
                    Children =
                    {
                        new TextBlock { Text = "SUMMARY", FontSize = 10.5, CharacterSpacing = 60, Foreground = _brushes.Fg55 }.A11yHeading(),
                        body,
                    },
                });
            }
        }
        stack.Children.Add(new Border { Height = 1, Background = _brushes.Fg20 });
        return stack;
    }

    /// <summary>"— CHAPTER 3 —" and the chapter's title (chapterHeader). With
    /// <paramref name="fixedHeight"/> (page-by-page) it takes exactly the height
    /// the paginator budgeted for it, so measured pages are the drawn pages.</summary>
    private FrameworkElement ChapterHeaderView(AO3ChapterPayload chapter, double? fixedHeight = null)
    {
        var t = CurrentTypography();
        var label = new TextBlock
        {
            Text = $"CHAPTER {chapter.Index}",
            FontSize = 13,
            FontWeight = FontWeights.ExtraBold,
            CharacterSpacing = 30,
            Foreground = _brushes.Accent,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(label, $"Chapter {chapter.Index}");
        if (chapter.Title.Length == 0) label.A11yHeading();
        var row = UI.UI.Grid("*,Auto,*", columnSpacing: 12);
        row.Children.Add(new Border { Height = 1, Background = _brushes.AccentRule, VerticalAlignment = VerticalAlignment.Center }.Col(0));
        row.Children.Add(label.Col(1));
        row.Children.Add(new Border { Height = 1, Background = _brushes.AccentRule, VerticalAlignment = VerticalAlignment.Center }.Col(2));

        var stack = new StackPanel { Spacing = 10, Padding = new Thickness(0, 24, 0, 8), VerticalAlignment = VerticalAlignment.Top };
        stack.Children.Add(row);
        if (chapter.Title.Length > 0)
        {
            stack.Children.Add(new TextBlock
            {
                Text = chapter.Title,
                FontFamily = ReaderText.Font(t.Family),
                FontSize = t.FontSize + 5,
                FontWeight = FontWeights.Bold,
                TextAlignment = TextAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                TextWrapping = TextWrapping.Wrap,
                Foreground = _brushes.Foreground,
            }.A11yHeading());
        }
        if (fixedHeight is not { } height) return stack;
        return new Grid { Height = Math.Max(0, height), VerticalAlignment = VerticalAlignment.Top, Children = { stack } };
    }
}
