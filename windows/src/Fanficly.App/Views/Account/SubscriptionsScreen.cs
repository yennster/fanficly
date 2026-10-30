using System.ComponentModel;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Account;

/// <summary>
/// The Subscriptions tab (SubscriptionsView): the account's AO3 subscriptions,
/// synced from AO3 when logged in, plus the works and authors followed
/// locally (no login) — everything the background poller checks. Refresh syncs
/// the AO3 list first (fast, so it shows at once), then runs the per-category
/// checks for new chapters and new works, posting notifications as it goes.
/// A subscribed work opens its page; a series or author opens on AO3.
/// </summary>
public sealed class SubscriptionsScreen : Screen
{
    private sealed record Item(string Key, Func<UIElement> Build);

    private const string AO3 = "https://archiveofourown.org";

    private readonly Grid _host = new();
    private readonly VirtualList<Item> _list;
    private List<string> _shownKeys = [];
    private bool _isRefreshing;
    private bool _isChecking;
    private string? _lastError;
    private int? _lastNotifyCount;
    private int? _lastNewWorksCount;
    private int _lastFailedChecks;
    private bool _hasRequestedNotifications;
    private string? _shownUser = "\0";
    private bool _isVisible;
    private bool _renderQueued;
    private CancellationTokenSource? _cts;
    private AppBarButton? _refreshButton;

    public SubscriptionsScreen()
    {
        Title = "Subscriptions";
        _list = new VirtualList<Item>((item, _) => item.Build(), spacing: 0, maxWidth: 980);
        _list.Element.Id("subscriptions.list");
        AutomationProperties.SetName(_list.Element, "Subscriptions");
    }

    protected override FrameworkElement Build()
    {
        AppHost.Library.Changed += OnLibraryChanged;
        AppHost.Auth.PropertyChanged += OnAuthChanged;
        CheckAccount();
        Render();
        SyncIfNew();
        return _host;
    }

    public override void OnAppearing()
    {
        _isVisible = true;
        if (!IsBuilt) { _ = RequestNotificationsOnceAsync(); return; }
        CheckAccount();
        Render();
        SyncIfNew();
        _ = RequestNotificationsOnceAsync();
    }

    public override void OnDisappearing() => _isVisible = false;

    private static string? Username => AppHost.Auth.Username;

    private static bool HasLocalFollows =>
        AppHost.Library.FollowedWorks().Count > 0 || AppHost.Library.Count<FollowedAuthor>() > 0;

    // MARK: - Account and library changes

    private void OnAuthChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is not (nameof(AuthState.Username) or nameof(AuthState.IsSessionExpired))) return;
        AccountKit.OnUIThread(() =>
        {
            // Signed in again: the expired-session error no longer stands.
            if (!AppHost.Auth.IsSessionExpired && _lastError?.StartsWith(SessionExpiry.Title, StringComparison.Ordinal) == true)
                _lastError = null;
            CheckAccount();
            if (!_isVisible) return;
            Render();
            SyncIfNew();
        });
    }

    /// <summary>A different account (or none) clears the last run's messages and
    /// any refresh still in flight.</summary>
    private void CheckAccount()
    {
        if (_shownUser == Username) return;
        var first = _shownUser == "\0";
        _shownUser = Username;
        if (first) return;
        _cts?.Cancel();
        _isRefreshing = false;
        _isChecking = false;
        _lastError = null;
        _lastNotifyCount = null;
        _lastNewWorksCount = null;
        _hasRequestedNotifications = false;
        InvalidateChrome();
    }

    /// <summary>A new account's list syncs on its own (#159): just signed in, or the
    /// first visit since. After that, Refresh and the background poll keep it.</summary>
    private void SyncIfNew()
    {
        if (!_isVisible || _isRefreshing || _isChecking || !AppHost.Auth.HasSession || AppHost.IsDemoMode) return;
        if (new SubscriptionPoller(AppHost.Client, AppHost.Library, Username).HasSyncedList) return;
        _ = RefreshAsync();
    }

    private void OnLibraryChanged(LibraryEntityKinds kinds)
    {
        const LibraryEntityKinds relevant = LibraryEntityKinds.Subscriptions | LibraryEntityKinds.Works | LibraryEntityKinds.FollowedAuthors;
        if ((kinds & relevant) == 0 || _renderQueued) return;
        _renderQueued = true;
        AccountKit.OnUIThread(() =>
        {
            _renderQueued = false;
            if (_isVisible) Render();
        });
    }

    /// <summary>SubscriptionsView's .task: ask for notification permission once
    /// a logged-in user opens the tab.</summary>
    private async Task RequestNotificationsOnceAsync()
    {
        if (_hasRequestedNotifications || Username is null) return;
        _hasRequestedNotifications = true;
        if (NotificationsAuthorization.IsSuppressed || NotificationsAuthorization.Request is not { } request) return;
        try { await request(); }
        catch (Exception e) { AppHost.Log($"Notification permission request failed: {e.Message}"); }
    }

    // MARK: - Toolbar

    public override IEnumerable<ICommandBarElement> PrimaryCommands()
    {
        _refreshButton = null;
        if (Username is null && !HasLocalFollows) yield break;
        _refreshButton = UI.UI.ToolbarButton("arrow.clockwise", "Refresh subscriptions", () => _ = RefreshAsync())
            .Id("subscriptions.refresh")
            .Shortcut(Windows.System.VirtualKey.F5, Windows.System.VirtualKeyModifiers.None);
        UpdateRefreshButton();
        yield return _refreshButton;
        if (Username is { } user)
        {
            var manage = UI.UI.ToolbarButton("globe", "Manage subscriptions on AO3",
                () => AccountKit.OpenInBrowser(new Uri($"{AO3}/users/{Uri.EscapeDataString(user)}/subscriptions")));
            yield return manage;
        }
    }

    private void UpdateRefreshButton()
    {
        if (_refreshButton is null) return;
        var busy = _isRefreshing || _isChecking;
        _refreshButton.IsEnabled = !busy;
        ToolTipService.SetToolTip(_refreshButton, busy ? "Refreshing…" : "Refresh subscriptions");
    }

    // MARK: - Refresh

    private async Task RefreshAsync()
    {
        if (_isRefreshing || _isChecking) return;
        _cts?.Cancel();
        var cts = _cts = new CancellationTokenSource();
        var ct = cts.Token;
        var poller = new SubscriptionPoller(AppHost.Client, AppHost.Library, Username, new AppHost.ToastNotifier());
        _isRefreshing = true;
        _lastError = null;
        UpdateRefreshButton();
        Render();
        MainWindow.Current.Announce("Refreshing subscriptions");

        if (Username is not null)
        {
            try
            {
                // The subscription list first — fast, and it updates the list at once.
                await poller.SyncSubscriptionListAsync(ct);
            }
            catch (Exception) when (ct.IsCancellationRequested) { return; }
            catch (AO3Exception e) when (e.Kind == AO3ErrorKind.ParseFailed)
            {
                _lastError = $"Couldn't parse AO3's response: {e.Reason}";
            }
            catch (AO3Exception e) when (e.Kind == AO3ErrorKind.Unauthorized)
            {
                // Signed in here, so AO3 dropped the session (#131).
                SessionExpiry.Explains(e);
                _lastError = $"{SessionExpiry.Title}. Sign in again to sync your subscriptions.";
            }
            catch (AO3Exception e) when (e.Kind == AO3ErrorKind.Network)
            {
                _lastError = $"Network: {e.Reason}";
            }
            catch (Exception e)
            {
                _lastError = e.Message;
            }
        }
        if (ct.IsCancellationRequested) return;
        _isRefreshing = false;
        _isChecking = true;
        UpdateRefreshButton();
        Render();
        if (_lastError is { } error) MainWindow.Current.Announce(error);

        // The per-work checks are throttled (1 req/sec) and only feed
        // notifications, so they run after the list is already showing.
        var chapters = 0;
        var newWorks = 0;
        try
        {
            chapters += await poller.CheckWorksForNewChaptersAsync(ct);
            newWorks += await poller.CheckFollowedAuthorsAsync(ct);
        }
        catch (Exception) when (ct.IsCancellationRequested) { return; }
        catch (Exception e)
        {
            _lastError ??= e.Message;
        }
        if (ct.IsCancellationRequested) return;
        _isChecking = false;
        _lastNotifyCount = chapters;
        _lastNewWorksCount = newWorks;
        _lastFailedChecks = poller.FailedChecks;
        if (poller.SessionExpired) AppHost.Auth.MarkSessionExpired();
        UpdateRefreshButton();
        Render();
        MainWindow.Current.Announce(NotifySummary());
    }

    private string NotifySummary()
    {
        var count = _lastNotifyCount ?? 0;
        var text = count == 0 ? "No new chapters." : $"{count} work{(count == 1 ? "" : "s")} have new chapters.";
        if (_lastNewWorksCount is > 0 and var works)
            text += $" {works} new work{(works == 1 ? "" : "s")} from authors you follow.";
        if (_lastFailedChecks is > 0 and var failed)
            text = count == 0 && _lastNewWorksCount is not > 0
                ? $"Couldn't check {failed} of them. AO3 may be down; try again later."
                : $"{text} Couldn't check {failed} more.";
        return text;
    }

    // MARK: - Content

    private void Render()
    {
        var username = Username;
        var subs = AppHost.Library.Subscriptions()
            .OrderBy(s => s.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList();
        var followedWorks = AppHost.Library.FollowedWorks()
            .OrderBy(w => w.Title, StringComparer.CurrentCultureIgnoreCase).ToList();
        var authors = AppHost.Library.All<FollowedAuthor>()
            .OrderBy(a => a.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList();
        var hasLocal = followedWorks.Count > 0 || authors.Count > 0;
        var hadRefresh = _refreshButton is not null;
        if (hadRefresh != (username is not null || hasLocal)) InvalidateChrome();

        if (username is null && !hasLocal)
        {
            Show(LoginPrompt());
            return;
        }
        if (username is not null && subs.Count == 0 && !_isRefreshing && !_isChecking && !hasLocal)
        {
            Show(NoSubscriptions());
            return;
        }

        var items = new List<Item>();
        if (_isRefreshing || _isChecking)
            items.Add(new Item("progress", () => ProgressLine(_isRefreshing ? "Fetching your subscriptions…" : "Checking for new chapters…")));
        if (_lastError is { } error)
            items.Add(new Item($"error:{error}", () => ErrorLine(error)));
        if (AppHost.Auth.IsSessionExpired)
            items.Add(new Item("expired", ExpiredLine));
        if (_lastNotifyCount is not null)
        {
            var summary = NotifySummary();
            items.Add(new Item($"notify:{summary}", () => UI.UI.Secondary(summary, Theme.Style.Callout).Also(t => t.Margin = new Thickness(14, 8, 14, 8))));
        }

        if (hasLocal) items.Add(new Item("h:ao3", () => AccountKit.ListSectionHeader("AO3 Subscriptions")));
        if (username is null)
        {
            items.Add(new Item("login", () => UI.UI.Card(LoginPrompt(), 4).Also(c => c.Margin = new Thickness(0, 4, 0, 8))));
        }
        else if (subs.Count == 0 && !_isRefreshing)
        {
            items.Add(new Item("nosubs", () => UI.UI.Card(NoSubscriptions(), 4).Also(c => c.Margin = new Thickness(0, 4, 0, 8))));
        }
        foreach (var sub in subs)
            items.Add(new Item($"sub:{sub.Key}", () => SubscriptionRow(sub)));

        if (followedWorks.Count > 0)
        {
            items.Add(new Item("h:works", () => AccountKit.ListSectionHeader("Followed Works")));
            foreach (var work in followedWorks)
                items.Add(new Item($"work:{work.Ao3Id}", () => FollowedWorkRow(work)));
        }
        if (authors.Count > 0)
        {
            items.Add(new Item("h:authors", () => AccountKit.ListSectionHeader("Followed Authors")));
            foreach (var author in authors)
                items.Add(new Item($"author:{author.Username}", () => FollowedAuthorRow(author)));
        }

        var keys = items.Select(i => i.Key).ToList();
        if (!keys.SequenceEqual(_shownKeys))
        {
            var keepScroll = _host.Children.Count == 1 && _host.Children[0] == _list.Element;
            var offset = _list.Element.VerticalOffset;
            _list.Reset(items);
            if (keepScroll) _list.Element.ChangeView(null, offset, null, disableAnimation: true);
            _shownKeys = keys;
        }
        else
        {
            _list.Items.Clear();
            _list.Items.AddRange(items);
            _list.Refresh(); // "checked … ago" and chapter counts move on
        }
        Show(_list.Element);
    }

    private void Show(FrameworkElement content)
    {
        if (content != _list.Element) _shownKeys = [];
        if (_host.Children.Count == 1 && _host.Children[0] == content) return;
        _host.Children.Clear();
        _host.Children.Add(content);
    }

    private static FrameworkElement LoginPrompt() =>
        UI.UI.EmptyState("person.crop.circle.badge.questionmark", "Log in to AO3",
            "Your AO3 subscriptions sync here once you log in. We'll notify you when subscribed works post new chapters.",
            "Log In", Routes.OpenLogin)
        .Id("subscriptions.login");

    private FrameworkElement NoSubscriptions() =>
        UI.UI.EmptyState("bell", "No subscriptions yet", "Select Refresh to fetch your subscriptions from AO3.",
            "Refresh", () => _ = RefreshAsync());

    private static FrameworkElement ProgressLine(string text)
    {
        var row = UI.UI.Grid("Auto,*", columnSpacing: 10);
        row.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 }.A11yHidden().Col(0));
        row.Children.Add(UI.UI.Secondary(text, Theme.Style.Callout).Col(1));
        row.Margin = new Thickness(14, 8, 14, 8);
        AutomationProperties.SetName(row, text);
        return row;
    }

    private static FrameworkElement ErrorLine(string error)
    {
        var row = UI.UI.Grid("Auto,*", columnSpacing: 8);
        row.Margin = new Thickness(14, 8, 14, 8);
        row.Children.Add(UI.UI.Icon("exclamationmark.triangle.fill", 15, Theme.Danger).Also(i => i.VerticalAlignment = VerticalAlignment.Top).Col(0));
        row.Children.Add(UI.UI.Text(error, Theme.Style.Body, Theme.Danger, selectable: true).Col(1));
        AutomationProperties.SetName(row, error);
        return row;
    }

    /// <summary>The way back from an expired session: Retry can't help.</summary>
    private static FrameworkElement ExpiredLine()
    {
        var row = UI.UI.Grid("*,Auto", columnSpacing: 12);
        row.Margin = new Thickness(14, 4, 14, 8);
        row.Children.Add(UI.UI.Secondary(SessionExpiry.Message, Theme.Style.Callout).Col(0));
        row.Children.Add(UI.UI.Button(SessionExpiry.ActionTitle, Routes.OpenLogin, kind: UI.UI.ButtonKind.Accent)
            .Also(b => b.VerticalAlignment = VerticalAlignment.Center).Id("subscriptions.signInAgain").Col(1));
        return row;
    }

    private static UIElement WithDivider(UIElement row) => UI.UI.VStack(0, row, UI.UI.Divider(14));

    // MARK: - Rows

    private static int? WorkId(SubscriptionRecord sub)
    {
        var parts = sub.Key.Split(':');
        return parts.Length == 2 && parts[0] == "work" && int.TryParse(parts[1], out var id) ? id : null;
    }

    /// <summary>A series or author subscription's page on AO3.</summary>
    private static Uri? AO3Page(SubscriptionRecord sub)
    {
        var parts = sub.Key.Split(':', 2);
        if (parts.Length != 2) return null;
        var id = Uri.EscapeDataString(parts[1]);
        return parts[0] switch
        {
            "series" => new Uri($"{AO3}/series/{id}"),
            "user" => new Uri($"{AO3}/users/{id}"),
            "work" => new Uri($"{AO3}/works/{id}"),
            _ => null,
        };
    }

    private UIElement SubscriptionRow(SubscriptionRecord sub)
    {
        var page = AO3Page(sub);
        if (sub.Kind == "work" && WorkId(sub) is { } workId)
        {
            // A subscribed work opens its page; the cached work (if saved) gives
            // the richer Library row — the record alone has only title + chapters.
            var cached = AppHost.Library.GetWork(workId);
            var (content, name) = cached is not null ? SubscriptionRows.CachedWork(cached) : SubscriptionRows.Subscription(sub);
            void Open() => Routes.OpenWork(workId, Stub(workId, sub.DisplayName));
            var menu = UI.UI.Menu(
                UI.UI.MenuItem("Open", Open, "book"),
                page is null ? null : UI.UI.MenuItem("Open on AO3", () => AccountKit.OpenInBrowser(page), "globe"),
                ManageItem());
            return WithDivider(AccountKit.ListRow(content, Open, name, menu).Id($"subscription.{sub.Key}"));
        }
        else
        {
            // Series / author → the AO3 page.
            var (content, name) = SubscriptionRows.Subscription(sub);
            void Open() { if (page is not null) AccountKit.OpenInBrowser(page); }
            var menu = UI.UI.Menu(
                page is null ? null : UI.UI.MenuItem("Open on AO3", Open, "globe"),
                ManageItem());
            var row = AccountKit.ListRow(content, Open, name, menu).Id($"subscription.{sub.Key}");
            AutomationProperties.SetHelpText(row, "Opens on AO3 in your browser");
            return WithDivider(row);
        }
    }

    /// <summary>Unsubscribing happens on AO3 (the app never changes the account
    /// beyond subscribe); this opens the account's subscriptions page.</summary>
    private static MenuFlyoutItemBase? ManageItem()
    {
        if (Username is not { } user) return null;
        return UI.UI.MenuItem("Unsubscribe on AO3…",
            () => AccountKit.OpenInBrowser(new Uri($"{AO3}/users/{Uri.EscapeDataString(user)}/subscriptions")), "bell");
    }

    private UIElement FollowedWorkRow(Work work)
    {
        var caption = work.LastCheckedAt is { } c ? AccountKit.CheckedAgo(c) : null;
        var (content, name) = SubscriptionRows.CachedWork(work, caption);
        var id = work.Ao3Id;
        void Open() => Routes.OpenSavedWork(id);
        var menu = UI.UI.Menu(
            UI.UI.MenuItem("Open", Open, "book"),
            UI.UI.MenuItem("Open on AO3", () => AccountKit.OpenInBrowser(new Uri($"{AO3}/works/{id}")), "globe"),
            new MenuFlyoutSeparator(),
            UI.UI.MenuItem("Unfollow", () =>
            {
                WorkPersistence.Unfollow(work, AppHost.Library);
                MainWindow.Current.Announce($"Unfollowed {work.Title}");
                Render();
            }, "bookmark.slash", isDestructive: true));
        return WithDivider(AccountKit.ListRow(content, Open, name, menu).Id($"followed.work.{id}"));
    }

    private UIElement FollowedAuthorRow(FollowedAuthor author)
    {
        var meta = UI.UI.Flow(8, 2, AccountKit.KindLabel("person", "Author"));
        var parts = new List<string> { author.DisplayName, "Author" };
        if (author.LastCheckedAt is { } c)
        {
            meta.Children.Add(UI.UI.Caption(AccountKit.CheckedAgo(c)));
            parts.Add(AccountKit.CheckedAgo(c));
        }
        var content = UI.UI.VStack(4, UI.UI.Text(author.DisplayName, Theme.Style.Headline), meta);
        void Open() => Routes.OpenAuthor(new AuthorRef(author.Username, author.DisplayName));
        var menu = UI.UI.Menu(
            UI.UI.MenuItem("Open", Open, "person"),
            new MenuFlyoutSeparator(),
            UI.UI.MenuItem("Unfollow", () =>
            {
                var name = author.DisplayName;
                AppHost.Library.Delete(author);
                AppHost.Library.TrySave();
                LibrarySyncManager.QueueBackupShared(AppHost.Library);
                MainWindow.Current.Announce($"Unfollowed {name}");
                Render();
            }, "person.slash", isDestructive: true));
        return WithDivider(AccountKit.ListRow(content, Open, string.Join(", ", parts), menu).Id($"followed.author.{author.Username}"));
    }

    /// <summary>AO3WorkSummary.stub: just an id and title; the work page fetches the rest.</summary>
    private static AO3WorkSummary Stub(int id, string title) => new()
    {
        Id = id,
        Title = title,
        Rating = "",
        ChapterCount = 0,
        Language = "",
    };
}
