using System.Security.Cryptography;
using System.Text;
using Fanficly.App.Services;

namespace Fanficly.App.Platform;

/// <summary>
/// Keeps the app and the background task from having <c>library.sqlite</c>
/// open at once. Each loads the library into memory once, so a row one writes
/// after the other loaded stays invisible to it. The app holds a named mutex
/// from before it opens the library until it exits; the background task polls
/// only while it holds the same mutex and skips its run when it can't get it.
/// A launch that finds the task polling asks it to stop and waits for it to
/// save, so the app loads what the task wrote.
/// </summary>
internal static class LibraryLock
{
    /// <summary>A task asked to stop cancels at its next await and saves, well
    /// within this. It runs before the window exists, so it stays short: past
    /// it the app opens the library anyway (the store copes with rows another
    /// process wrote, and the task also skips while the app's window is open).</summary>
    public static readonly TimeSpan LaunchWait = TimeSpan.FromSeconds(10);

    private static Mutex? _appMutex;

    // One lock per database file, so demo or test data folders don't contend.
    private static string Name(string kind)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(AppPaths.Database.ToUpperInvariant()));
        return $@"Local\Fanficly.Library.{kind}.{Convert.ToHexString(hash, 0, 8)}";
    }

    /// <summary>At launch, before the library opens: asks a running task to
    /// stop, then takes the lock for the rest of the process's life (released
    /// when it exits). Returns whether it got it in time.</summary>
    public static bool AcquireForApp()
    {
        if (_appMutex is not null) return true;
        try
        {
            var mutex = new Mutex(false, Name("Lock"));
            if (!TryWait(mutex, TimeSpan.Zero))
            {
                AppHost.Log("Library in use by the background refresh; asking it to stop");
                using (var stop = new EventWaitHandle(false, EventResetMode.ManualReset, Name("Stop")))
                {
                    stop.Set();
                    var got = TryWait(mutex, LaunchWait);
                    stop.Reset();
                    if (!got)
                    {
                        AppHost.Log("Background refresh didn't release the library in time; opening it anyway");
                        mutex.Dispose();
                        return false;
                    }
                }
            }
            _appMutex = mutex;
            return true;
        }
        catch (Exception e)
        {
            AppHost.Log($"Library lock unavailable: {e.Message}");
            return false;
        }
    }

    /// <summary>The background task's run: <paramref name="poll"/> runs only if
    /// the lock is free, on this thread (a mutex belongs to the thread that took
    /// it), and is cancelled through its token if the app launches meanwhile.
    /// Returns false when the app holds the lock and the run was skipped.</summary>
    public static bool RunExclusive(Func<CancellationToken, Task> poll, CancellationTokenSource cts)
    {
        using var mutex = new Mutex(false, Name("Lock"));
        if (!TryWait(mutex, TimeSpan.Zero)) return false;
        try
        {
            using var stop = new EventWaitHandle(false, EventResetMode.ManualReset, Name("Stop"));
            var registration = ThreadPool.RegisterWaitForSingleObject(stop, (_, _) =>
            {
                AppHost.Log("Background refresh stopping: the app is launching");
                try { cts.Cancel(); } catch (ObjectDisposedException) { }
            }, null, Timeout.Infinite, executeOnlyOnce: true);
            try
            {
                poll(cts.Token).GetAwaiter().GetResult();
            }
            finally
            {
                registration.Unregister(null);
            }
        }
        finally
        {
            mutex.ReleaseMutex();
        }
        return true;
    }

    private static bool TryWait(Mutex mutex, TimeSpan timeout)
    {
        try
        {
            return mutex.WaitOne(timeout);
        }
        catch (AbandonedMutexException)
        {
            // The holder exited without releasing it (the app holds it until
            // it exits); the mutex is ours now.
            return true;
        }
    }
}
