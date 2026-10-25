using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.App.Views.Account;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Authors;

/// <summary>
/// One author's works (AuthorWorksView): paginated with infinite scroll,
/// reusing the search result row; a Follow button in the toolbar follows the
/// author locally (no login), seeding the works already listed so the poller
/// only alerts for new ones.
/// </summary>
public sealed class AuthorWorksScreen : Screen
{
    private readonly AuthorRef _author;
    private readonly PagedWorksList _works;
    private bool _isFollowingAuthor;
    private AppBarButton? _followButton;

    public AuthorWorksScreen(AuthorRef author)
    {
        _author = author;
        Title = author.DisplayName;
        _works = new PagedWorksList(
            (page, ct) => AppHost.Client.FetchAuthorWorksAsync(author.Username, page, ct),
            new PagedWorksTexts(
                Loading: "Loading…",
                ErrorTitle: "Couldn't load works",
                EmptySymbol: "person.slash",
                EmptyTitle: "No works to show",
                EmptyMessage: "This author has no works published.",
                FilteredMessage: "Every work by this author so far is filtered out by your content settings."),
            automationId: "author.works",
            listName: $"Works by {author.DisplayName}",
            // Opening a blocked author's page is asking for them, so only
            // blocked tags apply here.
            blocklist: () => Blocklist.From(AppHost.Library).Lifting([], [author.Username, author.DisplayName]));
    }

    protected override FrameworkElement Build()
    {
        _ = _works.LoadFirstAsync();
        return _works.Element;
    }

    public override IEnumerable<ICommandBarElement> PrimaryCommands()
    {
        // An anonymous byline has no works page to follow.
        if (_author.Username.Length == 0) yield break;
        _followButton = UI.UI.ToolbarButton("person.badge.plus", "Follow", ToggleFollow, showLabel: true).Id("author.follow");
        UpdateFollowButton();
        yield return _followButton;
    }

    /// <summary>Updates the button in place, so keyboard focus stays on it.</summary>
    private void UpdateFollowButton()
    {
        if (_followButton is null) return;
        var name = _isFollowingAuthor ? $"Unfollow {_author.DisplayName}" : $"Follow {_author.DisplayName}";
        _followButton.Label = _isFollowingAuthor ? "Following" : "Follow";
        _followButton.Icon = new FontIcon
        {
            Glyph = Symbols.Glyph(_isFollowingAuthor ? "person.fill.checkmark" : "person.badge.plus"),
            FontFamily = Symbols.Font,
        };
        if (_isFollowingAuthor) _followButton.Foreground = Theme.Accent;
        else _followButton.ClearValue(Control.ForegroundProperty);
        AutomationProperties.SetName(_followButton, name);
        ToolTipService.SetToolTip(_followButton, name);
    }

    public override void OnAppearing()
    {
        var following = WorkPersistence.IsAuthorFollowed(_author.Username, AppHost.Library);
        if (following != _isFollowingAuthor)
        {
            _isFollowingAuthor = following;
            UpdateFollowButton();
        }
        // Content settings may have changed underneath (Settings, Hide this work).
        if (IsBuilt) _works.Render();
    }

    public override void OnRemoved() => _works.Cancel();

    private void ToggleFollow()
    {
        // Follow is local-only; ToggleFollowAuthor asks for notification
        // permission (NotificationsAuthorization.RequestAfterFollow) on follow.
        _isFollowingAuthor = WorkPersistence.ToggleFollowAuthor(
            _author.Username, _author.DisplayName, AppHost.Library, _works.WorkIds);
        UpdateFollowButton();
        MainWindow.Current.Announce(_isFollowingAuthor
            ? $"Following {_author.DisplayName}"
            : $"Unfollowed {_author.DisplayName}");
    }
}
