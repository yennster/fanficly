using System.ComponentModel;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;

namespace Fanficly.App.Views.Account;

/// <summary>
/// A work's comment thread (CommentsView), live-fetched for one chapter (AO3
/// threads comments per chapter; no chapter id → the work-level page). Replies
/// are indented with a thread guide line; guest comments get the "unknown
/// person" symbol. Logged in, a composer at the bottom posts through the
/// client and then re-fetches, since AO3 may hold the new comment for
/// moderation. A thread longer than one AO3 page ends in "Load more comments",
/// which appends the next page (a button, as on the Mac, not infinite scroll).
/// </summary>
public sealed class CommentsScreen : Screen
{
    private readonly int _workId;
    private readonly int? _chapterId;
    private readonly int? _chapterNumber;
    private readonly int? _totalChapters;
    private readonly Grid _content = new();
    private readonly Border _composerHost = new();
    private readonly VirtualList<AO3Comment> _list;
    private IReadOnlyList<AO3Comment> _comments = [];
    /// <summary>The last comment page loaded and how many AO3 has.</summary>
    private int _currentPage = 1;
    private int _totalPages = 1;
    private bool _isLoadingMore;
    private string? _loadMoreError;
    private StackPanel? _loadMoreFooter;
    private Button? _loadMoreButton;
    private TextBlock? _loadMoreErrorText;
    private CancellationTokenSource? _loadCts;
    private CancellationTokenSource? _postCts;
    private bool _isLoading;
    private string? _errorMessage;
    private bool _isPosting;
    private string? _postError;
    private string? _composerUser = "\0";
    private TextBox? _draft;
    private Button? _post;
    private TextBlock? _postErrorText;
    private AppBarButton? _refresh;
    private bool _isVisible;

    /// <param name="workTitle">The work's title (the screen's subtitle).</param>
    /// <param name="chapterNumber">1-based chapter shown in the title on multi-chapter works.</param>
    public CommentsScreen(int workId, int? chapterId, string workTitle, int? chapterNumber = null, int? totalChapters = null)
    {
        _workId = workId;
        _chapterId = chapterId;
        _chapterNumber = chapterNumber;
        _totalChapters = totalChapters;
        Title = NavTitle;
        Subtitle = string.IsNullOrWhiteSpace(workTitle) ? null : workTitle;
        _list = new VirtualList<AO3Comment>((c, _) => BuildRow(c), spacing: 0, maxWidth: 900);
        _list.Element.Id("comments.list");
        AutomationProperties.SetName(_list.Element, "Comments");
    }

    /// <summary>Shows the chapter only for multi-chapter works; single-chapter
    /// works read plainly as "Comments".</summary>
    private string NavTitle =>
        _chapterNumber is { } n && (_totalChapters ?? 1) > 1 ? $"Comments · Ch {n}" : "Comments";

    /// <summary>A per-chapter empty state names the chapter, so an empty later
    /// chapter reads as "this chapter has none", not "failed to load".</summary>
    private string EmptyTitle =>
        _chapterNumber is { } n && (_totalChapters ?? 1) > 1 ? $"No comments on Chapter {n} yet" : "No comments yet";

    protected override FrameworkElement Build()
    {
        var root = UI.UI.Grid("*", "*,Auto");
        root.Children.Add(_content.Row(0));
        root.Children.Add(_composerHost.Row(1));
        AppHost.Auth.PropertyChanged += OnAuthChanged;
        RenderComposer();
        _ = LoadAsync();
        return root;
    }

    public override void OnAppearing()
    {
        _isVisible = true;
        // Returning from Log In: the composer replaces the sign-in prompt.
        if (IsBuilt) { RenderComposer(); RenderContent(); }
    }

    public override void OnDisappearing() => _isVisible = false;

    public override void OnRemoved()
    {
        AppHost.Auth.PropertyChanged -= OnAuthChanged;
        _loadCts?.Cancel();
        _postCts?.Cancel();
    }

    private void OnAuthChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(AuthState.Username)) return;
        AccountKit.OnUIThread(() =>
        {
            if (!_isVisible) return;
            RenderComposer();
            RenderContent();
        });
    }

    public override IEnumerable<ICommandBarElement> PrimaryCommands()
    {
        _refresh = UI.UI.ToolbarButton("arrow.clockwise", "Refresh comments", () => _ = LoadAsync()).Id("comments.refresh")
            .Shortcut(VirtualKey.F5, VirtualKeyModifiers.None);
        _refresh.IsEnabled = !_isLoading;
        yield return _refresh;
    }

    // MARK: - Thread

    private async Task LoadAsync()
    {
        _loadCts?.Cancel();
        var cts = _loadCts = new CancellationTokenSource();
        _isLoading = true;
        _errorMessage = null;
        _loadMoreError = null;
        if (_refresh is not null) _refresh.IsEnabled = false;
        RenderContent();
        try
        {
            var page = await AppHost.Client.FetchCommentsAsync(_workId, _chapterId, 1, cts.Token);
            if (cts.IsCancellationRequested) return;
            _comments = page.Comments;
            _currentPage = page.CurrentPage;
            _totalPages = page.TotalPages;
            _list.Reset(_comments);
        }
        catch (Exception) when (cts.IsCancellationRequested)
        {
            return;
        }
        catch (Exception e)
        {
            _errorMessage = e.Message;
        }
        finally
        {
            if (_loadCts == cts)
            {
                _isLoading = false;
                if (_refresh is not null) _refresh.IsEnabled = true;
            }
        }
        RenderContent();
        // Also after a failed reload: a Load more it cancelled must not leave its spinner.
        RenderLoadMore();
        if (_errorMessage is not null && _comments.Count == 0)
            MainWindow.Current.Announce($"Couldn't load comments. {_errorMessage}");
    }

    /// <summary>Appends the next comment page. Ids already shown are skipped, since
    /// a comment posted meanwhile can shift a thread onto the next page. Shares
    /// <see cref="_loadCts"/> with <see cref="LoadAsync"/>, so a refresh cancels it.</summary>
    private async Task LoadMoreAsync()
    {
        if (_isLoadingMore || _isLoading || _currentPage >= _totalPages) return;
        var cts = _loadCts ??= new CancellationTokenSource();
        _isLoadingMore = true;
        _loadMoreError = null;
        RenderLoadMore();
        try
        {
            var page = await AppHost.Client.FetchCommentsAsync(_workId, _chapterId, _currentPage + 1, cts.Token);
            if (cts.IsCancellationRequested) return;
            var seen = _comments.Select(c => c.Id).ToHashSet();
            var added = page.Comments.Where(c => !seen.Contains(c.Id)).ToList();
            _comments = [.. _comments, .. added];
            _list.Append(added);
            _currentPage = Math.Max(_currentPage + 1, page.CurrentPage);
            _totalPages = page.TotalPages;
            MainWindow.Current.Announce(added.Count == 1 ? "Loaded 1 more comment" : $"Loaded {added.Count} more comments");
        }
        catch (Exception) when (cts.IsCancellationRequested)
        {
            return;
        }
        catch (Exception e)
        {
            _loadMoreError = $"Couldn't load more comments: {e.Message}";
            MainWindow.Current.Announce(_loadMoreError);
        }
        finally
        {
            _isLoadingMore = false;
        }
        RenderLoadMore();
    }

    /// <summary>The list's footer: "Load more comments" while AO3 has more pages. The
    /// button is built once and only its content changes, so keyboard and Narrator
    /// focus stay on it while a page loads (like <see cref="UpdatePostButton"/>).</summary>
    private void RenderLoadMore()
    {
        if (_currentPage >= _totalPages)
        {
            _list.Footer = null;
            _loadMoreFooter = null;
            return;
        }
        if (_loadMoreFooter is null || _loadMoreButton is null || _loadMoreErrorText is null)
        {
            _loadMoreErrorText = UI.UI.Text("", Theme.Style.Caption, Theme.Danger, selectable: true);
            AutomationProperties.SetLiveSetting(_loadMoreErrorText, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Assertive);
            _loadMoreButton = UI.UI.Button("Load more comments", () => _ = LoadMoreAsync()).Id("comments.loadMore");
            _loadMoreButton.HorizontalAlignment = HorizontalAlignment.Center;
            _loadMoreFooter = UI.UI.VStack(6, _loadMoreErrorText, _loadMoreButton);
            _loadMoreFooter.HorizontalAlignment = HorizontalAlignment.Center;
            _loadMoreFooter.Padding = new Thickness(14, 10, 14, 14);
            _list.Footer = _loadMoreFooter;
        }
        _loadMoreErrorText.Text = _loadMoreError ?? "";
        _loadMoreErrorText.Visibility = _loadMoreError is null ? Visibility.Collapsed : Visibility.Visible;
        _loadMoreButton.Content = _isLoadingMore
            ? new ProgressRing { IsActive = true, Width = 20, Height = 20 }
            : "Load more comments";
        // Never disabled: that would drop focus. LoadMoreAsync ignores a press while busy.
        AutomationProperties.SetHelpText(_loadMoreButton,
            _isLoadingMore ? "Loading more comments" : $"Page {_currentPage} of {_totalPages}");
    }

    private void RenderContent()
    {
        FrameworkElement content;
        if (_isLoading && _comments.Count == 0)
            content = UI.UI.Loading("Loading comments…");
        else if (_errorMessage is not null && _comments.Count == 0)
            content = UI.UI.EmptyState("exclamationmark.triangle", "Couldn't load comments", _errorMessage, "Retry", () => _ = LoadAsync());
        else if (_comments.Count == 0)
            content = UI.UI.EmptyState("bubble.left", EmptyTitle, AppHost.Auth.Username is null
                ? "Be the first to comment — log in to AO3 to post."
                : "Be the first to comment.");
        else
            content = _list.Element;
        if (_content.Children.Count == 1 && _content.Children[0] == content) return;
        _content.Children.Clear();
        _content.Children.Add(content);
    }

    private static UIElement BuildRow(AO3Comment comment)
    {
        var isGuest = comment.CommenterUsername.Length == 0;
        var header = UI.UI.Grid("Auto,*,Auto", columnSpacing: 6);
        header.Children.Add(UI.UI.Icon(isGuest ? "person.crop.circle.badge.questionmark" : "person.crop.circle", 15, Theme.TextSecondary)
            .Also(i => i.VerticalAlignment = VerticalAlignment.Center).Col(0));
        var name = UI.UI.Text(comment.CommenterName, Theme.Style.Subheadline, wrap: false);
        name.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        name.VerticalAlignment = VerticalAlignment.Center;
        header.Children.Add(name.Col(1));
        if (comment.DateText.Length > 0)
            header.Children.Add(UI.UI.Text(comment.DateText, Theme.Style.Caption2, Theme.TextSecondary, wrap: false)
                .Also(t => t.VerticalAlignment = VerticalAlignment.Center).Col(2));
        // Name the header as one element (name + date); the body stays separate
        // because it may carry links that combining would hide.
        var headerName = comment.DateText.Length > 0 ? $"{comment.CommenterName}, {comment.DateText}" : comment.CommenterName;
        if (isGuest) headerName += ", guest";
        AutomationProperties.SetName(header, headerName);

        var body = RichText.Html(comment.BodyHtml, Theme.Style.Callout, selectable: true);
        var column = UI.UI.VStack(4, header, body);

        var row = UI.UI.Grid("Auto,*", columnSpacing: 8);
        row.Padding = new Thickness(14 + Math.Min(comment.Depth, 6) * 16, 10, 14, 10);
        if (comment.Depth > 0)
        {
            // Thread guide line: the indentation reads as a reply, not a stray offset.
            row.Children.Add(new Rectangle
            {
                Width = 2,
                RadiusX = 1,
                RadiusY = 1,
                Fill = Theme.TextTertiary,
                Opacity = 0.45,
                VerticalAlignment = VerticalAlignment.Stretch,
            }.A11yHidden().Col(0));
        }
        row.Children.Add(column.Col(1));
        AutomationProperties.SetLevel(row, comment.Depth + 1);
        return UI.UI.VStack(0, row, UI.UI.Divider(14 + Math.Min(comment.Depth, 6) * 16));
    }

    // MARK: - Composer

    private void RenderComposer()
    {
        var username = AppHost.Auth.Username;
        if (username == _composerUser && _composerHost.Child is not null) return;
        _composerUser = username;
        var bar = new Border
        {
            Background = Theme.CardBackground,
            BorderBrush = Theme.Divider,
            BorderThickness = new Thickness(0, 1, 0, 0),
        };
        if (username is null)
        {
            _draft = null;
            _post = null;
            _postErrorText = null;
            var row = UI.UI.Grid("Auto,*,Auto", columnSpacing: 8);
            row.Padding = new Thickness(14, 10, 14, 10);
            row.Children.Add(UI.UI.Icon("person.crop.circle.badge.questionmark", 16, Theme.TextSecondary)
                .Also(i => i.VerticalAlignment = VerticalAlignment.Center).Col(0));
            row.Children.Add(UI.UI.Secondary("Log in to AO3 to post a comment.", Theme.Style.Footnote)
                .Also(t => t.VerticalAlignment = VerticalAlignment.Center).Col(1));
            row.Children.Add(UI.UI.Button("Log In", Routes.OpenLogin).Id("comments.login").Col(2));
            bar.Child = row;
        }
        else
        {
            var previous = _draft?.Text ?? "";
            _draft = new TextBox
            {
                PlaceholderText = $"Add a comment as {username}…",
                AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap,
                MaxHeight = 120, // about five lines
                IsSpellCheckEnabled = true,
                Text = previous,
                IsEnabled = !_isPosting,
            }.Id("comments.composer");
            AutomationProperties.SetName(_draft, "Comment");
            AutomationProperties.SetHelpText(_draft, "Ctrl+Enter posts the comment.");
            ScrollViewer.SetVerticalScrollBarVisibility(_draft, ScrollBarVisibility.Auto);
            _draft.TextChanged += (_, _) => UpdatePostButton();
            _draft.PreviewKeyDown += (_, e) =>
            {
                if (e.Key == VirtualKey.Enter && MainWindow.CurrentModifiers().HasFlag(VirtualKeyModifiers.Control))
                {
                    e.Handled = true;
                    Post();
                }
            };

            _post = new Button
            {
                Background = Theme.Transparent,
                BorderBrush = Theme.Transparent,
                Padding = new Thickness(6),
                MinWidth = 40,
                MinHeight = 36,
                VerticalAlignment = VerticalAlignment.Bottom,
            }.Id("comments.post");
            AutomationProperties.SetName(_post, "Post comment");
            ToolTipService.SetToolTip(_post, "Post comment (Ctrl+Enter)");
            _post.Click += (_, _) => Post();

            _postErrorText = UI.UI.Text("", Theme.Style.Caption, Theme.Danger, selectable: true);
            AutomationProperties.SetLiveSetting(_postErrorText, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Assertive);

            var input = UI.UI.Grid("*,Auto", columnSpacing: 8);
            input.Children.Add(_draft.Col(0));
            input.Children.Add(_post.Col(1));
            var stack = UI.UI.VStack(6, _postErrorText, input);
            stack.Padding = new Thickness(12, 8, 12, 8);
            stack.MaxWidth = 900;
            bar.Child = stack;
            UpdatePostButton();
        }
        _composerHost.Child = bar;
    }

    private void UpdatePostButton()
    {
        if (_post is null || _draft is null) return;
        _post.Content = _isPosting
            ? new ProgressRing { IsActive = true, Width = 20, Height = 20 }
            : UI.UI.Icon("arrow.up.circle.fill", 24, Theme.Accent);
        _post.IsEnabled = !_isPosting && _draft.Text.Trim().Length > 0;
        _draft.IsEnabled = !_isPosting;
        if (_postErrorText is not null)
        {
            _postErrorText.Text = _postError ?? "";
            _postErrorText.Visibility = _postError is null ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    private void Post()
    {
        if (_isPosting || _draft is null) return;
        var text = _draft.Text.Trim();
        if (text.Length == 0) return;
        _ = PostAsync(text);
    }

    private async Task PostAsync(string text)
    {
        _postCts?.Cancel();
        var cts = _postCts = new CancellationTokenSource();
        _isPosting = true;
        _postError = null;
        UpdatePostButton();
        MainWindow.Current.Announce("Posting comment");
        try
        {
            await AppHost.Client.PostCommentAsync(_workId, _chapterId, text, cts.Token);
            if (_draft is not null) _draft.Text = "";
            _isPosting = false;
            UpdatePostButton();
            MainWindow.Current.Announce("Comment posted");
            // Re-fetch so the new comment shows (AO3 may hold it for moderation).
            await LoadAsync();
        }
        catch (Exception) when (cts.IsCancellationRequested)
        {
        }
        catch (AO3Exception e) when (e.Kind == AO3ErrorKind.Unauthorized)
        {
            _postError = "Couldn't post: your AO3 login has expired. Log in again in Settings, then post again. Your comment is still here.";
            MainWindow.Current.Announce(_postError);
        }
        catch (AO3Exception e) when (e is { Kind: AO3ErrorKind.Rejected, Reason: { Length: > 0 } })
        {
            _postError = $"AO3 didn't post your comment: {e.Reason}";
            MainWindow.Current.Announce(_postError);
        }
        catch (Exception e)
        {
            _postError = $"Couldn't post: {e.Message}. Your comment may be awaiting moderation, or try again.";
            MainWindow.Current.Announce(_postError);
        }
        finally
        {
            _isPosting = false;
            UpdatePostButton();
        }
    }
}
