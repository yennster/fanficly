using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Windows.System;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// Find in this work (#183; Swift: <c>WorkFindView</c> and <c>showFindMatch</c>):
/// a dialog that searches the loaded chapters' text on the PC (<see cref="WorkFind"/>)
/// and lists the matching paragraphs by chapter. Choosing one makes it the reading
/// place and shows it in whichever mode is on, lit briefly with the Listen highlight.
/// Opened from the Aa menu, Ctrl+F and the reading area's context menu.
/// </summary>
internal sealed partial class ReaderView
{
    /// <summary>Kept while the reader is open, so Find opens again on the last search.</summary>
    private string _findQuery = "";
    private bool _findOpen;
    /// <summary>The paragraph Find landed on, lit like the Listen highlight for a moment.</summary>
    private ReadingAnchor? _findHighlight;
    private DispatcherQueueTimer? _findHighlightTimer;
    private int _findGeneration;
    /// <summary>Find set <c>_isRestoring</c> for a page-by-page chapter change; a
    /// failed re-pagination clears it.</summary>
    private bool _findPageJump;
    /// <summary>Page by page: a Find target in a chapter being paginated, shown
    /// once its pages are in (see <c>RunPagination</c>).</summary>
    private ReadingAnchor? _findPage;
    /// <summary>Where the words start in the target paragraph.</summary>
    private int _findOffset;

    private static readonly TimeSpan FindDebounce = TimeSpan.FromMilliseconds(250);
    /// <summary>Long enough to outlast a chapter's pagination or the dialog closing.</summary>
    private static readonly TimeSpan FindHighlightDuration = TimeSpan.FromSeconds(3.5);

    /// <summary>Opens Find (once the Aa menu has closed when it came from there).</summary>
    private async Task ShowFindAsync()
    {
        if (_removed || _findOpen || _chapters.Count == 0) return;
        _findOpen = true;
        try
        {
            var chosen = await RunFindDialogAsync();
            if (chosen is { } match && !_removed) ShowFindMatch(match.Anchor, match.Offset);
        }
        finally
        {
            _findOpen = false;
        }
    }

    private async Task<WorkFind.Match?> RunFindDialogAsync()
    {
        WorkFind.Match? chosen = null;
        var box = new TextBox
        {
            PlaceholderText = "Words in this work",
            Text = _findQuery,
            MinWidth = 320,
            IsSpellCheckEnabled = false,
        };
        AutomationProperties.SetName(box, "Find in this work");
        AutomationProperties.SetAutomationId(box, "reader.find.box");
        var status = UI.UI.Secondary("", Theme.Style.Footnote);
        AutomationProperties.SetAutomationId(status, "reader.find.status");
        AutomationProperties.SetLiveSetting(status, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        var list = UI.UI.VStack(2);
        AutomationProperties.SetName(list, "Matches");
        AutomationProperties.SetAutomationId(list, "reader.find.results");
        var scroll = new ScrollViewer
        {
            Content = list,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Disabled,
            Height = 420,
            Padding = new Thickness(0, 0, 12, 0),
        };
        var content = UI.UI.VStack(10, box, status, scroll);

        var dialog = new ContentDialog
        {
            Title = "Find in This Work",
            Content = content,
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.None,
        };
        dialog.Resources["ContentDialogMaxWidth"] = 640.0;
        dialog.Resources["ContentDialogMinWidth"] = 360.0;
        dialog.Resources["ContentDialogMaxHeight"] = 900.0;

        WorkFind.Result result = WorkFind.Result.Empty;
        var payloads = _chapters;
        var images = ShowImages;
        var generation = 0;

        void Choose(WorkFind.Match match)
        {
            chosen = match;
            dialog.Hide();
        }

        void ShowResult(string query)
        {
            list.Children.Clear();
            if (WorkFind.NormalizedQuery(query) is null)
            {
                status.Text = "Search every loaded chapter's text. Nothing leaves your PC.";
                return;
            }
            if (result.Matches.Count == 0)
            {
                status.Text = "No matches";
                return;
            }
            status.Text = Summary(result);
            var lastChapter = -1;
            foreach (var match in result.Matches)
            {
                if (match.Chapter != lastChapter)
                {
                    lastChapter = match.Chapter;
                    var title = ChapterAt(match.Chapter)?.Title ?? "";
                    list.Children.Add(UI.UI.SectionHeader(WorkFind.ChapterLabel(match.Chapter, title)));
                }
                list.Children.Add(MatchRow(match, Choose));
            }
        }

        async Task SearchAsync(string query, int run)
        {
            if (WorkFind.NormalizedQuery(query) is null)
            {
                result = WorkFind.Result.Empty;
                ShowResult(query);
                return;
            }
            status.Text = "Searching…";
            await Task.Delay(FindDebounce);
            if (run != generation) return;
            WorkFind.Result found;
            try
            {
                found = await Task.Run(() => WorkFind.Search(query, WorkFind.Chapters(payloads, images)));
            }
            catch (Exception e)
            {
                AppHost.Log($"Find failed: {e.Message}");
                if (run != generation || _removed) return;
                result = WorkFind.Result.Empty;
                list.Children.Clear();
                status.Text = "Couldn't search this work";
                return;
            }
            if (run != generation || _removed) return;
            result = found;
            ShowResult(query);
        }

        box.TextChanged += (_, _) =>
        {
            _findQuery = box.Text;
            // The last query's rows go at once, so Enter or a click can't pick
            // one of them while the new search runs.
            result = WorkFind.Result.Empty;
            list.Children.Clear();
            _ = SearchAsync(box.Text, ++generation);
        };
        // Enter shows the first match; Down moves into the list.
        box.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter && result.Matches.Count > 0 && WorkFind.NormalizedQuery(box.Text) is not null)
            {
                e.Handled = true;
                Choose(result.Matches[0]);
            }
            else if (e.Key == VirtualKey.Down && list.Children.OfType<Button>().FirstOrDefault() is { } first)
            {
                e.Handled = true;
                first.Focus(FocusState.Keyboard);
            }
        };
        dialog.Opened += (_, _) =>
        {
            box.Focus(FocusState.Programmatic);
            box.SelectAll();
        };

        ShowResult("");
        if (WorkFind.NormalizedQuery(_findQuery) is not null) _ = SearchAsync(_findQuery, ++generation);
        await Dialogs.ShowAsync(dialog);
        generation++;
        return chosen;
    }

    private static string Summary(WorkFind.Result result)
    {
        var paragraphs = result.Matches.Count;
        var total = result.Total == 1 ? "1 match" : $"{result.Total} matches";
        if (result.Truncated) return $"{total}, showing the first {paragraphs} paragraphs";
        return paragraphs == 1 || paragraphs == result.Total ? total : $"{total} in {paragraphs} paragraphs";
    }

    /// <summary>One result: the snippet with the words in bold, and how many times
    /// they appear when it's more than once.</summary>
    private static Button MatchRow(WorkFind.Match match, Action<WorkFind.Match> choose)
    {
        var text = UI.UI.Text("", Theme.Style.Body);
        var start = Math.Clamp(match.HighlightStart, 0, match.Snippet.Length);
        var end = Math.Clamp(match.HighlightStart + match.HighlightLength, start, match.Snippet.Length);
        if (start > 0) text.Inlines.Add(new Run { Text = match.Snippet[..start] });
        if (end > start) text.Inlines.Add(new Run { Text = match.Snippet[start..end], FontWeight = FontWeights.Bold });
        if (end < match.Snippet.Length) text.Inlines.Add(new Run { Text = match.Snippet[end..] });
        var stack = UI.UI.VStack(2, text,
            match.Count > 1 ? UI.UI.Caption($"{match.Count} times in this paragraph") : null);
        var name = match.Count > 1 ? $"{match.Snippet}, {match.Count} times in this paragraph" : match.Snippet;
        var row = UI.UI.NavRow(stack, () => choose(match), name, chevron: false);
        row.Padding = new Thickness(8, 8, 8, 8);
        AutomationProperties.SetAutomationId(row, $"reader.find.match.{match.Chapter}.{match.Paragraph}");
        AutomationProperties.SetHelpText(row, "Shows this place in the reader.");
        return row;
    }

    /// <summary>Shows a Find match in whichever mode is on screen (Swift:
    /// <c>showFindMatch</c>). The match becomes the reading place, saved at once.</summary>
    private void ShowFindMatch(ReadingAnchor anchor, int offset = 0)
    {
        _findOffset = offset;
        if (ChapterAt(anchor.Chapter) is not { } chapter || !_bodyBuilt) return;
        SetCurrentAnchor(anchor, force: true);
        FlashFindHighlight(anchor);
        switch (_builtMode)
        {
            case ReadingMode.Continuous:
                _selectedChapter = anchor.Chapter;
                _ = ScrollContinuousToFindMatchAsync(anchor);
                break;
            case ReadingMode.Paginated:
                // The chapter's page scrolls to it (RestorePaginatedParagraphAsync),
                // once it's built when the chapter changes.
                _pendingParagraphRestore = anchor;
                if (anchor.Chapter != _selectedChapter) SelectChapter(anchor.Chapter);
                else if (_chapViews.TryGetValue(anchor.Chapter, out var view)) _ = RestorePaginatedParagraphAsync(view);
                break;
            case ReadingMode.PageByPage:
                ShowFindMatchPage(anchor);
                break;
        }
        ReportCurrentChapter();
        RefreshChrome();
        MainWindow.Current.Announce($"Showing match in {WorkFind.ChapterLabel(chapter.Index, chapter.Title)}");
    }

    /// <summary>Continuous scroll: the chapter first when it's another one (its
    /// paragraphs' heights are estimates until realized), then the paragraph, again
    /// until the layout around it settles.</summary>
    private async Task ScrollContinuousToFindMatchAsync(ReadingAnchor anchor)
    {
        var generation = _contGeneration;
        var run = ++_findGeneration;
        _isRestoring = true;
        try
        {
            if (anchor.Chapter != _visibleChapter && _chapterFirstEntry.TryGetValue(anchor.Chapter, out var entry))
                ScrollToEntry(entry, 0, animated: false);
            for (var i = 0; i < 6; i++)
            {
                await Task.Delay(120);
                if (generation != _contGeneration || run != _findGeneration) return;
                ScrollToParagraph(anchor, 0, animated: false);
            }
        }
        finally
        {
            if (generation == _contGeneration && run == _findGeneration) _isRestoring = false;
        }
        _visibleChapter = anchor.Chapter;
        ReportCurrentChapter();
    }

    /// <summary>Page by page: the page holding the paragraph when its chapter is
    /// paginated already, else the chapter is paginated around the place
    /// (<see cref="RestoreOrValidatePageSelection"/> picks the page holding the anchor).</summary>
    private void ShowFindMatchPage(ReadingAnchor anchor)
    {
        _findPage = null;
        if (FindMatchPage(anchor) is { } page)
        {
            if (!IsShowing(page.Id)) UpdatePageSelection(page.Id);
            return;
        }
        if (anchor.Chapter == _selectedChapter) return;
        _findPage = anchor;
        // Not a jump to the chapter's top: keeps OnPageChapterChanged from
        // replacing the place with the chapter's first paragraph. The next
        // pagination's page selection clears it (or its failure, _findPageJump).
        _isRestoring = true;
        _findPageJump = true;
        SelectChapter(anchor.Chapter);
    }

    /// <summary>The page showing a Find match: a long paragraph runs over several
    /// pages, so the one whose atoms cover the words' offset (the speech text Find
    /// searched is the rendered text, give or take a trimmed space).</summary>
    private ChapterPage? FindMatchPage(ReadingAnchor anchor)
    {
        if (!_atoms.TryGetValue(anchor.Chapter, out var atoms)) return null;
        int? covering = null;
        var end = 0;
        for (var i = 0; i < atoms.Count; i++)
        {
            if (atoms[i].OriginalParagraphIndex != anchor.Paragraph) continue;
            covering = i;
            end += atoms[i].Text.Length;
            if (end > _findOffset) break;
        }
        if (covering is not { } atomIndex) return null;
        return _pages.FirstOrDefault(p => p.ChapterIndex == anchor.Chapter && p.ParagraphIndices.Contains(atomIndex));
    }

    private void FlashFindHighlight(ReadingAnchor anchor)
    {
        _findHighlight = anchor;
        ApplyHighlight();
        _findHighlightTimer ??= CreateFindHighlightTimer();
        _findHighlightTimer.Stop();
        _findHighlightTimer.Start();
    }

    private DispatcherQueueTimer CreateFindHighlightTimer()
    {
        var timer = _dispatcher.CreateTimer();
        timer.Interval = FindHighlightDuration;
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            _findHighlight = null;
            if (!_removed) ApplyHighlight();
        };
        return timer;
    }
}
