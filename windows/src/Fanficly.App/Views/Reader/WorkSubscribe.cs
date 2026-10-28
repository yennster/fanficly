using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Reader;

/// <summary>What a subscription is recorded under: the work's title and author,
/// and its live chapter count, or null when only a saved copy is on screen.</summary>
internal sealed record SubscribeDetails(string Title, string Author, int? ChapterCount);

/// <summary>
/// The "Subscribe on AO3" item of a work's options menu (SubscribeMenuButton +
/// subscribePresentation), owned by the screen like <see cref="WorkKudos"/>.
/// A subscription AO3 confirms is mirrored into a local <see cref="SubscriptionRecord"/>
/// whose baseline is today's chapter count, so the poller only alerts for
/// chapters posted after this. With no live count (a saved copy can be behind
/// AO3) the baseline stays null, as a synced record's does, and the poller's
/// first check sets it without alerting.
/// </summary>
internal sealed class WorkSubscribe(int workId)
{
    public bool IsSending { get; private set; }

    /// <summary>Raised when sending starts or ends (the screen swaps its menu icon for a spinner).</summary>
    public event Action? Changed;

    private string Key => $"work:{workId}";

    /// <summary>The menu item, built fresh each time the menu opens. The local
    /// record counts as subscribed only while signed in. A null
    /// <paramref name="details"/> (the work hasn't loaded) does nothing.</summary>
    public MenuFlyoutItem MenuItem(Func<SubscribeDetails?> details)
    {
        MenuFlyoutItem item;
        if (IsSending)
        {
            item = UI.UI.MenuItem("Subscribing…", () => { }, "bell");
            item.IsEnabled = false;
        }
        else if (AppHost.Auth.IsLoggedIn && AppHost.Library.GetSubscription(Key) is not null)
        {
            item = UI.UI.MenuItem("Subscribed on AO3", () => { }, "bell.fill");
            item.IsEnabled = false;
        }
        else if (!AppHost.Auth.IsLoggedIn)
        {
            item = UI.UI.MenuItem("Subscribe on AO3 (sign in)…", Routes.OpenLogin, "bell");
        }
        else
        {
            // Let the menu finish closing before anything is presented.
            item = UI.UI.MenuItem("Subscribe on AO3",
                () => MainWindow.Current.DispatcherQueue.TryEnqueue(() => _ = SubscribeAsync(details())), "bell");
        }
        AutomationProperties.SetAutomationId(item, "work.options.subscribe");
        return item;
    }

    private async Task SubscribeAsync(SubscribeDetails? details)
    {
        if (details is null || IsSending) return;
        IsSending = true;
        Changed?.Invoke();
        MainWindow.Current.Announce("Subscribing");
        try
        {
            await AppHost.Client.SubscribeToWorkAsync(workId);
            if (AppHost.Library.GetSubscription(Key) is null)
            {
                AppHost.Library.Insert(new SubscriptionRecord(Key, "work", details.Title, details.Author)
                {
                    LastSeenChapterCount = details.ChapterCount,
                });
                AppHost.Library.TrySave();
            }
            MainWindow.Current.ShowMessage("Subscribed on AO3", "AO3 will email you when this work updates.");
        }
        catch (AO3Exception e) when (e.Kind == AO3ErrorKind.Unauthorized)
        {
            Account.SessionExpiry.Explains(e);
            if (await Dialogs.ConfirmAsync("Sign in to AO3", "Your AO3 session has expired. Sign in again to subscribe.", Account.SessionExpiry.ActionTitle))
                Routes.OpenLogin();
        }
        catch (AO3Exception e) when (e.Kind == AO3ErrorKind.Network)
        {
            AppHost.Log($"Subscribe failed: {e}");
            await Dialogs.AlertAsync("Couldn't subscribe",
                $"{e.Message} If the request reached AO3, you may already be subscribed; check your Subscriptions page before trying again.");
        }
        catch (Exception e)
        {
            AppHost.Log($"Subscribe failed: {e}");
            await Dialogs.AlertAsync("Couldn't subscribe", e.Message);
        }
        finally
        {
            IsSending = false;
            Changed?.Invoke();
        }
    }
}
