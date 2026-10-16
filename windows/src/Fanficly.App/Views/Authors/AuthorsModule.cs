using System.Runtime.CompilerServices;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;

namespace Fanficly.App.Views.Authors;

/// <summary>Registers the Authors tab, the author-works route and the
/// notification-permission step of the follow flow.</summary>
internal static class AuthorsModule
{
    /// <summary>Set once the "notifications are off" prompt has been shown — iOS
    /// asks for permission once, so this asks once too.</summary>
    internal const string NotificationPromptShownKey = "notifications.permissionPromptShown";

    [ModuleInitializer]
    internal static void Register()
    {
        Tabs.Register(SidebarItem.Authors, () => new FollowedAuthorsScreen());
        Routes.AuthorWorks = author => new AuthorWorksScreen(author);
        NotificationsAuthorization.Request ??= RequestNotificationsAsync;
    }

    /// <summary>
    /// NotificationsAuthorization.request() on Windows: toasts need no
    /// permission prompt, but they can be turned off in Settings → System →
    /// Notifications. The first time a follow (or the Subscriptions tab) asks
    /// while they're off, say so and offer to open that page. Returns whether
    /// notifications are on.
    /// </summary>
    internal static Task<bool> RequestNotificationsAsync()
    {
        var done = new TaskCompletionSource<bool>();
        var queue = MainWindow.Current?.DispatcherQueue;
        if (queue is null) { done.SetResult(false); return done.Task; }
        // RequestAfterFollow calls this from a worker thread.
        queue.TryEnqueue(async () =>
        {
            try { done.TrySetResult(await PromptIfOffAsync()); }
            catch (Exception e)
            {
                AppHost.Log($"Notification prompt failed: {e.Message}");
                done.TrySetResult(false);
            }
        });
        return done.Task;
    }

    private static async Task<bool> PromptIfOffAsync()
    {
        if (Platform.Notifications.IsEnabled) return true;
        if (NotificationsAuthorization.IsSuppressed || KeyValueStores.Default.GetBool(NotificationPromptShownKey)) return false;
        KeyValueStores.Default.SetBool(NotificationPromptShownKey, true);
        var open = await Dialogs.ConfirmAsync(
            "Turn on notifications?",
            "Fanficly lets you know when stories and authors you follow post something new. Notifications for Fanficly are off in Windows Settings.",
            "Open Settings",
            cancel: "Not Now");
        if (open) await Platform.Notifications.OpenSystemSettingsAsync();
        return false;
    }
}
