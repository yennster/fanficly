using System.ComponentModel;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Account;

/// <summary>
/// The Bookmarks tab (BookmarksView): the signed-in account's AO3 bookmarks,
/// private ones included, fetched live with infinite scroll. Login-gated,
/// since private bookmarks need the session cookie. Rows are the search
/// result row, with its inline save-to-Library button.
/// </summary>
public sealed class BookmarksScreen : Screen
{
    private readonly Grid _host = new();
    private PagedWorksList? _works;
    private string? _shownUser;
    private AppBarButton? _refresh;

    public BookmarksScreen()
    {
        Title = "Bookmarks";
    }

    protected override FrameworkElement Build()
    {
        AppHost.Auth.PropertyChanged += OnAuthChanged;
        Render();
        return _host;
    }

    public override void OnAppearing()
    {
        if (IsBuilt) Render();
    }

    private void OnAuthChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(AuthState.Username)) return;
        AccountKit.OnUIThread(() =>
        {
            // Signing out (or into another account) must not leave the old
            // account's private bookmarks on screen, even underneath.
            if (_shownUser != AppHost.Auth.Username) Render();
        });
    }

    public override IEnumerable<ICommandBarElement> PrimaryCommands()
    {
        _refresh = null;
        if (AppHost.Auth.Username is null || _works is null) yield break;
        _refresh = UI.UI.ToolbarButton("arrow.clockwise", "Refresh bookmarks", () => _ = _works.RefreshAsync()).Id("bookmarks.refresh")
            .Shortcut(Windows.System.VirtualKey.F5, Windows.System.VirtualKeyModifiers.None);
        _refresh.IsEnabled = !_works.IsLoading;
        yield return _refresh;
    }

    private void Render()
    {
        var username = AppHost.Auth.Username;
        if (username != _shownUser)
        {
            _works?.Clear();
            _works = username is null ? null : CreateList(username);
            _shownUser = username;
            InvalidateChrome();
        }

        if (_works is null)
        {
            Show(UI.UI.EmptyState("bookmark.circle", "Log in to AO3",
                    "Your AO3 bookmarks show here once you log in, including private ones.",
                    "Log In", Routes.OpenLogin)
                .Id("bookmarks.login"));
            return;
        }
        Show(_works.Element);
        if (!_works.HasWorks) _ = _works.LoadFirstAsync();
        else _works.Render(); // content settings may have changed meanwhile
    }

    private PagedWorksList CreateList(string username)
    {
        var list = new PagedWorksList(
            (page, ct) => AppHost.Client.FetchBookmarksAsync(username, page, ct),
            new PagedWorksTexts(
                Loading: "Loading bookmarks…",
                ErrorTitle: "Couldn't load bookmarks",
                EmptySymbol: "bookmark",
                EmptyTitle: "No bookmarks yet",
                EmptyMessage: "Works you bookmark on AO3 will appear here.",
                FilteredMessage: "Every bookmark is hidden or filtered out by your content settings."),
            automationId: "bookmarks.list",
            listName: "Bookmarks");
        list.LoadingChanged += () =>
        {
            if (_refresh is not null && _works == list) _refresh.IsEnabled = !list.IsLoading;
        };
        return list;
    }

    private void Show(FrameworkElement content)
    {
        if (_host.Children.Count == 1 && _host.Children[0] == content) return;
        _host.Children.Clear();
        _host.Children.Add(content);
    }
}
