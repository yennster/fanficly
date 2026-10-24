using Fanficly.App.Shell;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App;

/// <summary>
/// The last line for errors nothing else caught: an exception in a button's
/// handler (XAML's <c>UnhandledException</c>), a fire-and-forget task that
/// failed (<c>_ = SomethingAsync()</c>, seen by
/// <see cref="TaskScheduler.UnobservedTaskException"/> when it's collected),
/// and anything that escapes a thread-pool or timer callback, which ends the
/// process (<see cref="AppDomain.UnhandledException"/>, which can only log).
/// Every one is written to the log; the first two also say "Something went
/// wrong", at most once a minute, and the app carries on. Windows only: Swift
/// has no unobserved-error path, its errors are typed and thrown to a caller.
/// </summary>
internal static class UnexpectedErrors
{
    private static long _lastShown;

    /// <summary>Called first thing in <c>Main</c>, so the widget and
    /// background-task servers log what ends them too.</summary>
    public static void InstallProcessHandlers()
    {
        Core.JsonFileKeyValueStore.WriteFailed = AppHost.Log;
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            AppHost.Log($"Unhandled{(e.IsTerminating ? " (closing)" : "")}: {e.ExceptionObject}");
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            e.SetObserved();
            // A discarded task that was cancelled (the screen closed, a newer
            // search replaced it) is not an error.
            if (e.Exception.Flatten().InnerExceptions.All(x => x is OperationCanceledException)) return;
            AppHost.Log($"Unobserved task error: {e.Exception}");
            Report(e.Exception.InnerExceptions.Count == 1 ? e.Exception.InnerException! : e.Exception);
        };
    }

    /// <summary>XAML's <c>Application.UnhandledException</c>: log, keep running, say so.</summary>
    public static void OnXamlUnhandled(Microsoft.UI.Xaml.UnhandledExceptionEventArgs e)
    {
        e.Handled = true;
        // An async handler whose work was cancelled (navigating away) is not an error.
        if (e.Exception is OperationCanceledException) return;
        AppHost.Log($"Unhandled: {e.Exception}");
        Report(e.Exception);
    }

    /// <summary>Shows "Something went wrong" from any thread, at most once a
    /// minute (one fault often fails several times in a row).</summary>
    private static void Report(Exception error)
    {
        // No window yet (early at launch), or the widget and background-task
        // servers, which have none: logged only, and the next error can still show.
        var window = MainWindow.Current;
        if (window is null) return;
        var now = Environment.TickCount64;
        var last = Interlocked.Read(ref _lastShown);
        if (last != 0 && now - last < 60_000) return;
        if (Interlocked.CompareExchange(ref _lastShown, now, last) != last) return;
        var queued = window.DispatcherQueue.TryEnqueue(() =>
        {
            try
            {
                window.ShowMessage(
                    "Something went wrong",
                    $"{error.Message} Fanficly carried on, and the details are in its log.",
                    InfoBarSeverity.Error, seconds: 10);
            }
            catch (Exception e)
            {
                // Never let the report itself fail into the handler that called it.
                AppHost.Log($"Couldn't show an error: {e.Message}");
            }
        });
        // Closing: nothing was shown, so don't mute the next one.
        if (!queued) Interlocked.CompareExchange(ref _lastShown, last, now);
    }
}
