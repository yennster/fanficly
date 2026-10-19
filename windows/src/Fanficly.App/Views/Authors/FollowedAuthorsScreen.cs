using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.App.Views.Account;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace Fanficly.App.Views.Authors;

/// <summary>
/// The Authors tab (FollowedAuthorsView): the authors the user follows,
/// sorted by name. Selecting one opens their works; the background poller
/// notifies when a followed author posts a new work. Follows are added from an
/// author's works page; unfollow from the row's context menu or with Delete.
/// </summary>
public sealed class FollowedAuthorsScreen : Screen
{
    private readonly Grid _host = new();
    private VirtualList<FollowedAuthor>? _list;
    private List<string> _shown = [];
    private bool _isVisible;
    private bool _refreshQueued;

    public FollowedAuthorsScreen()
    {
        Title = "Followed Authors";
    }

    protected override FrameworkElement Build()
    {
        AppHost.Library.Changed += OnLibraryChanged;
        Render();
        return _host;
    }

    public override void OnAppearing()
    {
        _isVisible = true;
        if (IsBuilt) Render();
    }

    public override void OnDisappearing() => _isVisible = false;

    private void OnLibraryChanged(LibraryEntityKinds kinds)
    {
        if (!kinds.HasFlag(LibraryEntityKinds.FollowedAuthors) || _refreshQueued) return;
        _refreshQueued = true;
        AccountKit.OnUIThread(() =>
        {
            _refreshQueued = false;
            if (_isVisible) Render();
        });
    }

    private static IReadOnlyList<FollowedAuthor> Authors() =>
        AppHost.Library.All<FollowedAuthor>()
            .OrderBy(a => a.DisplayName, StringComparer.CurrentCultureIgnoreCase)
            .ToList();

    private void Render()
    {
        var authors = Authors();
        if (authors.Count == 0)
        {
            _shown = [];
            Show(UI.UI.EmptyState("person.2", "No followed authors",
                "Open an author's page — from a work's byline or “More by this author” — and select Follow. New works they post will notify you here."));
            return;
        }

        _list ??= CreateList();
        var keys = authors.Select(a => a.Username).ToList();
        if (!keys.SequenceEqual(_shown))
        {
            _list.Reset(authors);
            _shown = keys;
        }
        else
        {
            _list.Refresh(); // "checked … ago" moves on
        }
        Show(_list.Element);
    }

    private VirtualList<FollowedAuthor> CreateList()
    {
        var list = new VirtualList<FollowedAuthor>((author, _) => BuildRow(author), spacing: 0, maxWidth: 980);
        list.Element.Id("authors.list");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(list.Element, "Followed authors");
        return list;
    }

    private void Show(FrameworkElement content)
    {
        if (_host.Children.Count == 1 && _host.Children[0] == content) return;
        _host.Children.Clear();
        _host.Children.Add(content);
    }

    private UIElement BuildRow(FollowedAuthor author)
    {
        var meta = UI.UI.Flow(8, 2, AccountKit.KindLabel("person", "Author"));
        if (author.LastCheckedAt is { } checkedAt) meta.Children.Add(UI.UI.Caption(AccountKit.CheckedAgo(checkedAt)));
        var content = UI.UI.VStack(4, UI.UI.Text(author.DisplayName, Theme.Style.Headline), meta);

        void Open() => Routes.OpenAuthor(new AuthorRef(author.Username, author.DisplayName));
        var menu = UI.UI.Menu(
            UI.UI.MenuItem("Open", Open, "person"),
            new MenuFlyoutSeparator(),
            UI.UI.MenuItem("Unfollow", () => Unfollow(author), "person.slash", isDestructive: true));
        var name = author.LastCheckedAt is { } c
            ? $"{author.DisplayName}, Author, {AccountKit.CheckedAgo(c)}"
            : $"{author.DisplayName}, Author";
        var row = AccountKit.ListRow(content, Open, name, menu).Id($"author.{author.Username}");
        row.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Delete) { e.Handled = true; Unfollow(author); }
        };
        var stack = UI.UI.VStack(0, row, UI.UI.Divider(14));
        return stack;
    }

    /// <summary>The list's onDelete: removes the follow (no confirmation, like a
    /// swipe-to-delete).</summary>
    private void Unfollow(FollowedAuthor author)
    {
        var name = author.DisplayName;
        var index = _list?.Items.IndexOf(author) ?? -1;
        AppHost.Library.Delete(author);
        AppHost.Library.TrySave();
        LibrarySyncManager.QueueBackupShared(AppHost.Library);
        if (index >= 0 && _list is not null && _list.Items.Count > 1)
        {
            // Remove in place so the list keeps its scroll position.
            _list.RemoveAt(index);
            _shown.RemoveAt(index);
        }
        else
        {
            Render();
        }
        MainWindow.Current.Announce($"Unfollowed {name}");
    }
}
