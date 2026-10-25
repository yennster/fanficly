using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// The "Leave Kudos" item of a work's options menu (KudosMenuButton +
/// kudosPresentation), over Core's <see cref="KudosGiver"/>. Owned by the screen,
/// never by menu content: the item only starts the kudo, and the thank-you or
/// AO3's refusal comes from the window once the menu has closed.
/// </summary>
internal sealed class WorkKudos
{
    private readonly KudosGiver _giver = new(KeyValueStores.Default);
    private readonly int _workId;

    public WorkKudos(int workId)
    {
        _workId = workId;
        _giver.Changed += () => Changed?.Invoke();
    }

    public bool IsSending => _giver.IsSending;

    /// <summary>Raised when sending starts or ends (the screen swaps its menu icon for a spinner).</summary>
    public event Action? Changed;

    /// <summary>The menu item, built fresh each time the menu opens so it shows
    /// the remembered state for whoever is signed in now.</summary>
    public MenuFlyoutItem MenuItem()
    {
        var username = AppHost.Auth.Username;
        if (!_giver.IsSending) _giver.Refresh(_workId, username);
        MenuFlyoutItem item;
        if (_giver.IsSending)
        {
            item = UI.UI.MenuItem("Leaving Kudos…", () => { }, "heart");
            item.IsEnabled = false;
        }
        else if (_giver.HasLeft)
        {
            item = UI.UI.MenuItem("Kudos Left", () => { }, "heart.fill");
            item.IsEnabled = false;
        }
        else if (username is null)
        {
            item = UI.UI.MenuItem("Leave Kudos (sign in)…", Routes.OpenLogin, "heart");
        }
        else
        {
            item = UI.UI.MenuItem("Leave Kudos", Start, "heart");
        }
        AutomationProperties.SetAutomationId(item, "work.options.kudos");
        return item;
    }

    private void Start() =>
        // Let the menu finish closing before anything is presented.
        MainWindow.Current.DispatcherQueue.TryEnqueue(() => _ = LeaveAsync());

    private async Task LeaveAsync()
    {
        MainWindow.Current.Announce("Leaving kudos");
        KudosResult? result;
        try
        {
            result = await _giver.LeaveAsync(_workId, AppHost.Auth.Username, AppHost.Client);
        }
        catch (Exception e)
        {
            AppHost.Log($"Kudos failed: {e}");
            result = new("Couldn't leave kudos", e.Message);
        }
        if (result is null) return;
        if (result.NeedsSignIn)
        {
            // Signed in here, so AO3 dropped the session (#131).
            if (AppHost.Auth.IsLoggedIn) AppHost.Auth.MarkSessionExpired();
            if (await Dialogs.ConfirmAsync("Sign in to AO3", result.Message, AppHost.Auth.IsLoggedIn ? Account.SessionExpiry.ActionTitle : "Sign In")) Routes.OpenLogin();
        }
        else if (_giver.HasLeft)
        {
            MainWindow.Current.ShowMessage(result.Title, result.Message);
        }
        else
        {
            await Dialogs.AlertAsync(result.Title, result.Message);
        }
    }
}
