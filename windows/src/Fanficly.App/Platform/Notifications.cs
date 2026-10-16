using Fanficly.Core;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Fanficly.App.Platform;

/// <summary>
/// Windows notifications (toasts) for new chapters and new works. Each toast
/// carries its <see cref="NotificationRoute"/> as launch arguments, so tapping
/// it — even when that cold-launches the app — opens what it's about.
/// </summary>
public static class Notifications
{
    private static bool _registered;

    /// <summary>Must run before the window opens so a tap that launched the app is delivered.</summary>
    public static void Register()
    {
        if (_registered || AppHost.IsDemoMode) return;
        try
        {
            var manager = AppNotificationManager.Default;
            manager.NotificationInvoked += (_, e) => Handle(e.Argument);
            manager.Register();
            _registered = true;
        }
        catch (Exception e)
        {
            AppHost.Log($"Notification registration failed: {e.Message}");
        }
    }

    public static void Unregister()
    {
        if (!_registered) return;
        try { AppNotificationManager.Default.Unregister(); } catch { }
        _registered = false;
    }

    /// <summary>A tapped toast's launch arguments → the router; the window takes it from there.</summary>
    public static void Handle(string? argument)
    {
        if (string.IsNullOrEmpty(argument)) return;
        var route = NotificationRoute.FromLaunchArguments(argument);
        if (route is not null) NotificationRouter.Shared.PendingRoute = route;
    }

    /// <summary>Whether Windows will show our toasts (Settings → System → Notifications).</summary>
    public static bool IsEnabled
    {
        get
        {
            try { return AppNotificationManager.Default.Setting == AppNotificationSetting.Enabled; }
            catch { return false; }
        }
    }

    public static void Show(string title, string body, NotificationRoute? route, string? tag = null, string? group = null)
    {
        if (AppHost.IsDemoMode) return;
        try
        {
            var builder = new AppNotificationBuilder()
                .AddText(title)
                .AddText(body);
            if (route is not null)
                foreach (var (key, value) in route.ToArguments()) builder.AddArgument(key, value);
            if (tag is not null) builder.SetTag(tag);
            if (group is not null) builder.SetGroup(group);
            AppNotificationManager.Default.Show(builder.BuildNotification());
        }
        catch (Exception e)
        {
            AppHost.Log($"Notification failed: {e.Message}");
        }
    }

    /// <summary>Opens Windows' notification settings for the app.</summary>
    public static async Task OpenSystemSettingsAsync() =>
        await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:notifications"));
}
