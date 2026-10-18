using System.ComponentModel;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Account;

/// <summary>A list on AO3's readings page that <see cref="ReadingListScreen"/> shows
/// (Swift's <c>AO3ReadingList</c>).</summary>
internal enum AO3ReadingList { MarkedForLater }

/// <summary>
/// The Marked for Later tab (Swift's <c>ReadingListView</c>): a list from the
/// signed-in account's AO3 readings page, fetched live with infinite scroll.
/// Built like <see cref="BookmarksScreen"/>, and read-only: marks are added and
/// removed on AO3.
/// </summary>
public sealed class ReadingListScreen : Screen
{
    /// <summary>What differs between the lists: the tab, its sign-in prompt,
    /// its list texts and its fetch.</summary>
    private sealed record Spec(
        SidebarItem Tab,
        string LoginPrompt,
        PagedWorksTexts Texts,
        Func<IAO3Client, string, int, CancellationToken, Task<AO3SearchResults>> Fetch);

    private static Spec SpecFor(AO3ReadingList kind) => kind switch
    {
        AO3ReadingList.MarkedForLater => new(
            SidebarItem.MarkedForLater,
            "Works you mark for later on AO3 show here once you log in.",
            new PagedWorksTexts(
                Loading: "Loading Marked for Later…",
                ErrorTitle: "Couldn't load Marked for Later",
                EmptySymbol: SidebarItem.MarkedForLater.SystemImage(),
                EmptyTitle: "Nothing marked for later",
                EmptyMessage: "Use \"Mark for Later\" on a work on AO3 and it will appear here.",
                FilteredMessage: "Every work here is hidden or filtered out by your content settings."),
            (client, username, page, ct) => client.FetchMarkedForLaterAsync(username, page, ct)),
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    private readonly Spec _spec;
    private readonly Grid _host = new();
    private PagedWorksList? _works;
    private string? _shownUser;
    private AppBarButton? _refresh;

    internal ReadingListScreen(AO3ReadingList kind)
    {
        _spec = SpecFor(kind);
        Title = _spec.Tab.Title();
    }

    private string Raw => _spec.Tab.RawValue();

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
            // account's list on screen, even underneath.
            if (_shownUser != AppHost.Auth.Username) Render();
        });
    }

    public override IEnumerable<ICommandBarElement> PrimaryCommands()
    {
        _refresh = null;
        if (AppHost.Auth.Username is null || _works is null) yield break;
        _refresh = UI.UI.ToolbarButton("arrow.clockwise", $"Refresh {Title}", () => _ = _works.RefreshAsync()).Id($"{Raw}.refresh")
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
            Show(UI.UI.EmptyState(_spec.Tab.SystemImage(), "Log in to AO3", _spec.LoginPrompt, "Log In", Routes.OpenLogin)
                .Id($"{Raw}.login"));
            return;
        }
        Show(_works.Element);
        if (!_works.HasWorks) _ = _works.LoadFirstAsync();
        else _works.Render(); // content settings may have changed meanwhile
    }

    private PagedWorksList CreateList(string username)
    {
        var list = new PagedWorksList(
            (page, ct) => _spec.Fetch(AppHost.Client, username, page, ct),
            _spec.Texts,
            automationId: $"{Raw}.list",
            listName: Title);
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
