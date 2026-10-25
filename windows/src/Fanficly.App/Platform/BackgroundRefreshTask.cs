using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;
using Fanficly.App.Platform.Widgets;
using Fanficly.App.Services;
using Fanficly.Core;
using Microsoft.Windows.AppLifecycle;
using Windows.ApplicationModel.Background;

namespace Fanficly.App.Platform;

/// <summary>
/// The subscription poll (Swift's <c>BackgroundRefresh</c> + its
/// <c>BGAppRefreshTask</c>) on Windows, in two halves:
/// <list type="bullet">
/// <item>While the app runs, <see cref="InAppPolling"/> polls about a minute
/// after launch and then every <see cref="BackgroundRefresh.DefaultInterval"/>.</item>
/// <item>While it's closed, a Windows background task with a 4-hour
/// <see cref="TimeTrigger"/> runs <c>Fanficly.exe -BackgroundTask</c>, a COM
/// server for <see cref="FanficlyBackgroundTask"/>, registered through the
/// Windows App SDK's full-trust <c>BackgroundTaskBuilder</c>
/// (<see cref="BackgroundTaskRegistrar"/>).</item>
/// </list>
/// Both run the same <see cref="BackgroundRefresh.RunPollAsync"/>, whose
/// oldest-check-first queue picks up wherever a cut-short run stopped.
/// </summary>
public static class InAppPolling
{
    /// <summary>The first poll waits a minute so it doesn't compete with launch work.</summary>
    public static readonly TimeSpan FirstPollDelay = TimeSpan.FromMinutes(1);

    private static readonly SemaphoreSlim Running = new(1, 1);
    private static CancellationTokenSource? _loop;

    /// <summary>Starts the in-app schedule (never in demo mode).</summary>
    public static void Start()
    {
        if (AppHost.IsDemoMode || _loop is not null) return;
        _loop = new CancellationTokenSource();
        _ = LoopAsync(_loop.Token);
    }

    public static void Stop()
    {
        _loop?.Cancel();
        _loop = null;
    }

    private static async Task LoopAsync(CancellationToken ct)
    {
        try
        {
            await Task.Delay(FirstPollDelay, ct);
            while (!ct.IsCancellationRequested)
            {
                await PollOnceAsync(ct);
                await Task.Delay(BackgroundRefresh.DefaultInterval, ct);
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>One poll, skipped if one is already running.</summary>
    public static async Task PollOnceAsync(CancellationToken ct = default)
    {
        if (!await Running.WaitAsync(0, ct)) return;
        try
        {
            // Read on the UI thread; the poll runs off it, and hops back to
            // RecordsThread.Main to read and change records (#139).
            var client = AppHost.Client;
            var library = AppHost.Library;
            var username = AppHost.Auth.Username;
            var notified = await Task.Run(() => BackgroundRefresh.RunPollAsync(client, library, username, new AppHost.ToastNotifier(), ct), ct);
            AppHost.Log($"In-app poll posted {notified} notifications");
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            AppHost.Log($"In-app poll failed: {e.Message}");
        }
        finally
        {
            Running.Release();
        }
    }
}

/// <summary>Registers the background refresh task with Windows once per
/// install (re-registering on launch only when it's missing).</summary>
public static class BackgroundTaskRegistrar
{
    public const string TaskName = BackgroundRefresh.Identifier;

    /// <summary>The 4-hour cadence of <see cref="BackgroundRefresh.DefaultInterval"/>, in minutes.</summary>
    public const uint IntervalMinutes = 240;

    public static async Task EnsureRegisteredAsync()
    {
        // Background tasks need package identity (an MSIX install).
        if (AppHost.IsDemoMode || !AppPaths.IsPackaged) return;
        try
        {
            foreach (var task in BackgroundTaskRegistration.AllTasks.Values)
                if (task.Name == TaskName) return;

            var access = await BackgroundExecutionManager.RequestAccessAsync();
            if (access is BackgroundAccessStatus.DeniedByUser or BackgroundAccessStatus.DeniedBySystemPolicy)
            {
                AppHost.Log($"Background refresh not registered: {access}");
                return;
            }

            var builder = new Microsoft.Windows.ApplicationModel.Background.BackgroundTaskBuilder { Name = TaskName };
            builder.SetTrigger(new TimeTrigger(IntervalMinutes, oneShot: false));
            builder.AddCondition(new SystemCondition(SystemConditionType.InternetAvailable));
            builder.SetTaskEntryPointClsid(Guid.Parse(FanficlyBackgroundTask.ClassId));
            builder.Register();
            AppHost.Log("Background refresh registered");
        }
        catch (Exception e)
        {
            AppHost.Log($"Background refresh registration failed: {e.Message}");
        }
    }
}

/// <summary>
/// The background task Windows runs every 4 hours (with internet). It polls in
/// this process with its own library, client and cookie vault, posts toasts,
/// refreshes the widgets' data, and finishes within the ~30 s Windows allows.
/// </summary>
[Guid(ClassId)]
public sealed partial class FanficlyBackgroundTask : IBackgroundTask
{
    public const string ClassId = "8090198F-1775-484C-B6CA-2D344B824590";

    /// <summary>Windows gives a background task about 30 s; stop a little
    /// before so the last record's stamp is saved.</summary>
    public static readonly TimeSpan Budget = TimeSpan.FromSeconds(25);

    internal static readonly ManualResetEvent Finished = new(false);

    public void Run(IBackgroundTaskInstance taskInstance)
    {
        var deferral = taskInstance.GetDeferral();
        var cts = new CancellationTokenSource(Budget);
        try { taskInstance.Canceled += (_, reason) => { AppHost.Log($"Background refresh cancelled: {reason}"); cts.Cancel(); }; }
        catch { }
        _ = Task.Run(() =>
        {
            try
            {
                // Only while the app doesn't have the library open (it holds the
                // lock from launch); a launch during the poll stops it early.
                if (IsAppRunning() || !LibraryLock.RunExclusive(RunPollAsync, cts))
                    AppHost.Log("Background refresh skipped: the app is running and polls itself");
            }
            catch (OperationCanceledException)
            {
                AppHost.Log("Background refresh stopped early");
            }
            catch (Exception e)
            {
                AppHost.Log($"Background refresh failed: {e}");
            }
            finally
            {
                try { deferral.Complete(); } catch { }
                cts.Dispose();
                Finished.Set();
            }
        });
    }

    /// <summary>Whether Fanficly's window is open (it registers the "main"
    /// instance key). A second check beside <see cref="LibraryLock"/>, for an
    /// app that gave up waiting for the lock at launch and runs without it.</summary>
    private static bool IsAppRunning()
    {
        try
        {
            return AppInstance.GetInstances().Any(i => i.Key == "main" && !i.IsCurrent);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>The poll, run under <see cref="LibraryLock"/>: the app polls on
    /// its own schedule while it's open, and two processes writing one library
    /// would each keep a stale copy of the other's rows.</summary>
    internal static async Task RunPollAsync(CancellationToken ct)
    {
        // This process's own services (FanficlyApp's container, opened by the
        // BGTask handler). Settings stay in memory: the poll writes only the
        // library and the widgets' shared store, never the app's settings file.
        KeyValueStores.Default = new InMemoryKeyValueStore();
        using var shared = new JsonFileKeyValueStore(WidgetStorage.SharedStorePath);
        AppGroupStore.Shared = shared;
        var vault = new ProtectedCookieVault(Path.Combine(AppPaths.LocalData, "Credentials"));
        CredentialStore.Shared = vault;
        WorkPersistence.LibraryFolder = AppPaths.Downloads;
        SubscriptionPoller.RoutePayloads = new AppHost.RoutePayloads();
        LibraryHooks.UpdateWidgetData = store => WidgetDataStore.UpdateAll(AppHost.WidgetSources(store));
        WidgetCenter.ReloadRequested += _ => FanficlyWidgetProvider.UpdateAll();

        using var library = LibraryStore.Open(AppPaths.Database);
        using var client = new AO3Client(AppPaths.Downloads, vault, AppHost.AppVersion);
        var username = new AuthState(vault).Username;
        try
        {
            var notified = await BackgroundRefresh.RunPollAsync(client, library, username, new AppHost.ToastNotifier(), ct);
            AppHost.Log($"Background refresh posted {notified} notifications");
        }
        finally
        {
            library.TrySave();
            shared.Flush();
        }
    }
}

/// <summary>Serves <see cref="FanficlyBackgroundTask"/> when Windows starts
/// <c>Fanficly.exe -BackgroundTask</c>: registers the class factory, waits for
/// the task to finish (or a minute, if Windows never asks), then exits.</summary>
public static partial class BackgroundTaskServer
{
    private const uint ClsctxLocalServer = 0x4;
    private const uint RegclsSingleUse = 0;

    [LibraryImport("ole32.dll")]
    private static partial int CoRegisterClassObject(in Guid clsid, IntPtr unknown, uint context, uint flags, out uint cookie);

    [LibraryImport("ole32.dll")]
    private static partial int CoRevokeClassObject(uint cookie);

    public static void Run()
    {
        var wrappers = new StrategyBasedComWrappers();
        var unknown = wrappers.GetOrCreateComInterfaceForObject(new BackgroundTaskFactory(), CreateComInterfaceFlags.None);
        var hr = CoRegisterClassObject(Guid.Parse(FanficlyBackgroundTask.ClassId), unknown, ClsctxLocalServer, RegclsSingleUse, out var cookie);
        if (hr < 0)
        {
            AppHost.Log($"Background task server registration failed: 0x{hr:X8}");
            Marshal.Release(unknown);
            return;
        }
        // The task's own budget is 25 s; a minute covers Windows being slow to
        // call in, and a launch nobody asked for still ends.
        FanficlyBackgroundTask.Finished.WaitOne(TimeSpan.FromSeconds(60));
        CoRevokeClassObject(cookie);
        Marshal.Release(unknown);
    }
}

[GeneratedComClass]
internal sealed partial class BackgroundTaskFactory : IClassFactory
{
    private const int ClassENoAggregation = unchecked((int)0x80040110);

    public int CreateInstance(IntPtr outer, in Guid riid, out IntPtr instance)
    {
        instance = IntPtr.Zero;
        if (outer != IntPtr.Zero) return ClassENoAggregation;
        var inspectable = WinRT.MarshalInspectable<IBackgroundTask>.FromManaged(new FanficlyBackgroundTask());
        try
        {
            return Marshal.QueryInterface(inspectable, in riid, out instance);
        }
        finally
        {
            Marshal.Release(inspectable);
        }
    }

    public int LockServer(bool doLock) => 0;
}
