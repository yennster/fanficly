using Fanficly.App.Shell;
using Fanficly.App.Views;
using Fanficly.Core;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;
using Windows.ApplicationModel.Activation;
using Windows.ApplicationModel.DataTransfer;
using Windows.ApplicationModel.DataTransfer.ShareTarget;

namespace Fanficly.App;

/// <summary>Where links, notification taps, widget taps and shares land.</summary>
public static partial class AppHost
{
    static partial void OpenUriCore(Uri uri)
    {
        var window = MainWindow.Current;
        if (window is null) return;
        switch (DeepLink.Parse(uri))
        {
            case DeepLink.Resume r:
                // A tab is always on screen on Windows, so the route opens on top
                // of it (RootView's "tab already on screen" case).
                window.Navigator.ReplacePath(Routes.Resume?.Invoke(r.Route) ?? new PlaceholderScreen("Work"));
                break;
            case DeepLink.Import i:
                if (Routes.Import is { } import) import(i.WorkId);
                else Routes.OpenWork(i.WorkId);
                break;
            case DeepLink.LibraryFolder f:
                window.Select(SidebarItem.Library);
                Routes.LibraryFolder?.Invoke(f.FolderName);
                break;
            case DeepLink.Search s:
                KeyValueStores.Default.SetString(DeepLink.PendingSearchQueryKey, s.Query);
                window.Select(SidebarItem.Search);
                Routes.RequestSearch(s.Query);
                break;
            default:
                Log($"Unhandled link: {uri}");
                break;
        }
    }

    static partial void HandleShare(ShareOperation operation) => _ = HandleShareAsync(operation);

    /// <summary>Share → Fanficly from a browser: import the AO3 work it points at.</summary>
    private static async Task HandleShareAsync(ShareOperation operation)
    {
        try
        {
            operation.ReportStarted();
            string? text = null;
            var data = operation.Data;
            if (data.Contains(StandardDataFormats.WebLink)) text = (await data.GetWebLinkAsync()).ToString();
            else if (data.Contains(StandardDataFormats.Uri)) text = (await data.GetUriAsync()).ToString();
            else if (data.Contains(StandardDataFormats.Text)) text = await data.GetTextAsync();
            operation.ReportCompleted();
            if (text is not null && DeepLink.WorkIdFromText(text) is { } id)
                MainWindow.Current?.DispatcherQueue.TryEnqueue(() => OpenUri(DeepLink.ImportUri($"https://archiveofourown.org/works/{id}")));
            else
                MainWindow.Current?.DispatcherQueue.TryEnqueue(() =>
                    MainWindow.Current.ShowMessage("That isn't an AO3 work link", "Share a page from archiveofourown.org/works/…", Microsoft.UI.Xaml.Controls.InfoBarSeverity.Warning));
        }
        catch (Exception e)
        {
            Log($"Share failed: {e.Message}");
            try { operation.ReportError(e.Message); } catch { }
        }
    }

    static partial void HandleOtherActivation(AppActivationArguments args, bool isLaunch)
    {
        if (args.Kind == ExtendedActivationKind.AppNotification && args.Data is AppNotificationActivatedEventArgs n)
            Platform.Notifications.Handle(n.Argument);
    }

    /// <summary>Opens a tapped notification's route on top of the current tab.</summary>
    internal static void OpenNotificationRoute(NotificationRoute route)
    {
        var window = MainWindow.Current;
        if (window is null) return;
        Screen? screen = route switch
        {
            NotificationRoute.NewChapters c => Routes.WorkDetail?.Invoke(c.WorkId, null),
            NotificationRoute.NewWork w => Routes.WorkDetail?.Invoke(w.WorkId, null),
            NotificationRoute.NewWorks a => Routes.AuthorWorks?.Invoke(a.Author),
            _ => null,
        };
        // Work routes always open the live page: a downloaded copy doesn't
        // have the new chapter (reading position is keyed by work id, so it
        // still resumes).
        if (screen is not null) window.Navigator.ReplacePath(screen);
    }

    static partial void OnWindowCreatedServices(MainWindow window)
    {
        NotificationRouter.Shared.RouteArrived += _ =>
            window.DispatcherQueue.TryEnqueue(() =>
            {
                if (NotificationRouter.Shared.TakePendingRoute() is { } r) OpenNotificationRoute(r);
            });
        // A tap that cold-launched the app arrived before the window existed.
        window.DispatcherQueue.TryEnqueue(() =>
        {
            if (NotificationRouter.Shared.TakePendingRoute() is { } r) OpenNotificationRoute(r);
        });
        Platform.GamepadInput.Install(window);
        WidgetCenter.ReloadRequested += _ => Platform.Widgets.FanficlyWidgetProvider.UpdateAll();
        _ = Platform.JumpListService.RefreshAsync();
    }
}
