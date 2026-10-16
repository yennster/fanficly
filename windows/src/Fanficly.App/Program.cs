using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Fanficly.App;

/// <summary>
/// Entry point. Fanficly is single-instance: a second launch (a fanficly://
/// link, a notification tap, the widget, Share → Fanficly, a jump-list entry)
/// hands its activation to the running window instead of opening another.
/// </summary>
public static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();

        // Windows launched us to serve the Widgets board: no window, no redirect.
        if (args.Contains("-RegisterProcessAsComServer"))
        {
            Platform.Widgets.WidgetComServer.Run();
            return 0;
        }

        // Windows launched us for the 4-hour subscription refresh (a COM
        // server for the background task): poll, post toasts, exit. It must
        // never take over or redirect to the app's "main" instance.
        if (args.Contains("-BackgroundTask"))
        {
            Platform.BackgroundTaskServer.Run();
            return 0;
        }

        if (!AppHost.IsBackgroundTaskLaunch(args) && RedirectToRunningInstance())
            return 0;

        Application.Start(_p =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
        return 0;
    }

    /// <summary>True when another instance took this activation.</summary>
    private static bool RedirectToRunningInstance()
    {
        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        var main = AppInstance.FindOrRegisterForKey("main");
        if (main.IsCurrent)
        {
            main.Activated += (_, e) => App.OnRedirectedActivation(e);
            return false;
        }
        // Redirect synchronously: Main must not return before the running
        // instance has the activation, and the STA thread can't block on an
        // async call directly.
        var done = new ManualResetEvent(false);
        _ = Task.Run(async () =>
        {
            try { await main.RedirectActivationToAsync(activation); }
            finally { done.Set(); }
        });
        done.WaitOne(TimeSpan.FromSeconds(10));
        return true;
    }
}
