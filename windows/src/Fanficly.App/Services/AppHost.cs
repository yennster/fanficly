using Fanficly.App.Services;
using Fanficly.App.Shell;
using Fanficly.Core;
using Microsoft.Windows.AppLifecycle;
using Windows.ApplicationModel.Activation;

namespace Fanficly.App;

/// <summary>
/// App-wide composition: launch flags, storage, the AO3 client, and routing
/// of every way the app can be activated (fanficly:// links, notification
/// taps, Share → Fanficly, the widget, jump-list entries).
/// </summary>
public static partial class AppHost
{
    /// <summary>"-demoMode": offline curated content and in-memory storage, for
    /// screenshots and UI tests (FanficlyApp.isDemoMode).</summary>
    public static bool IsDemoMode { get; } = Environment.GetCommandLineArgs().Contains("-demoMode");

    /// <summary>"-demoLongChapters": demo chapters long enough for a full page mid-chapter.</summary>
    public static bool IsDemoLongChapters { get; } = Environment.GetCommandLineArgs().Contains("-demoLongChapters");

    /// <summary>"-iconGallery" opens a page of every icon (UI tests check the icon font).</summary>
    public static bool IsIconGallery { get; } = Environment.GetCommandLineArgs().Contains("-iconGallery");

    /// <summary>"-tab library" picks the starting tab (screenshot tests, jump list).</summary>
    public static SidebarItem? InitialTab { get; private set; }

    public static bool IsBackgroundTaskLaunch(string[] args) =>
        args.Contains("-RegisterProcessAsComServer") || args.Contains("-BackgroundTask");

    private static readonly object LogLock = new();

    public static void Log(string message)
    {
        if (IsDemoMode) { System.Diagnostics.Debug.WriteLine(message); return; }
        try
        {
            lock (LogLock)
            {
                var file = Path.Combine(AppPaths.Logs, "fanficly.log");
                if (File.Exists(file) && new FileInfo(file).Length > 512 * 1024) File.Delete(file);
                File.AppendAllText(file, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
            }
        }
        catch { }
    }

    public static void Initialize()
    {
        var args = Environment.GetCommandLineArgs();
        var tabIndex = Array.IndexOf(args, "-tab");
        if (tabIndex >= 0 && tabIndex + 1 < args.Length) InitialTab = SidebarItems.FromRaw(args[tabIndex + 1]);

        if (IsDemoMode)
        {
            KeyValueStores.Default = new InMemoryKeyValueStore();
            KeyValueStores.Synced = new InMemoryKeyValueStore();
        }
        else
        {
            KeyValueStores.Default = new JsonFileKeyValueStore(AppPaths.Settings);
            KeyValueStores.Synced = new SyncFolderKeyValueStore(Path.Combine(AppPaths.Shared, "synced.json"));
        }
        InitializeServices();
    }

    /// <summary>Builds the client, the store and the background services.</summary>
    static partial void InitializeServices();

    public static void OnWindowCreated(MainWindow window)
    {
        window.AppWindow.Closing += (_, _) =>
        {
            OnClosing();
            if (KeyValueStores.Default is JsonFileKeyValueStore s) s.Flush();
            if (KeyValueStores.Synced is SyncFolderKeyValueStore k) k.Flush();
        };
        window.DispatcherQueue.TryEnqueue(() => _ = RunLaunchTasksAsync());
        OnWindowCreatedServices(window);
    }

    static partial void OnWindowCreatedServices(MainWindow window);

    public static void HandleActivation(AppActivationArguments args, bool isLaunch)
    {
        try
        {
            switch (args.Kind)
            {
                case ExtendedActivationKind.Protocol when args.Data is IProtocolActivatedEventArgs p:
                    OpenUri(p.Uri);
                    break;
                case ExtendedActivationKind.ShareTarget when args.Data is IShareTargetActivatedEventArgs s:
                    HandleShare(s.ShareOperation);
                    break;
                case ExtendedActivationKind.Launch when args.Data is ILaunchActivatedEventArgs l && !string.IsNullOrWhiteSpace(l.Arguments):
                    HandleLaunchArguments(l.Arguments, isLaunch);
                    break;
                default:
                    HandleOtherActivation(args, isLaunch);
                    break;
            }
        }
        catch (Exception e)
        {
            Log($"Activation failed: {e}");
        }
    }

    /// <summary>fanficly://resume/…, fanficly://import?url=…, fanficly://search?query=…,
    /// and plain AO3 work links.</summary>
    public static void OpenUri(Uri uri) => OpenUriCore(uri);

    static partial void OpenUriCore(Uri uri);
    static partial void HandleShare(Windows.ApplicationModel.DataTransfer.ShareTarget.ShareOperation operation);
    static partial void HandleOtherActivation(AppActivationArguments args, bool isLaunch);

    /// <summary>Jump-list and taskbar launches pass "-tab &lt;raw&gt;" or a fanficly:// URI.</summary>
    private static void HandleLaunchArguments(string arguments, bool isLaunch)
    {
        var parts = arguments.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var tab = Array.IndexOf(parts, "-tab");
        if (tab >= 0 && tab + 1 < parts.Length && SidebarItems.FromRaw(parts[tab + 1]) is { } item)
        {
            if (!isLaunch || InitialTab is null) MainWindow.Current?.Select(item);
            return;
        }
        var uriText = parts.FirstOrDefault(p => p.StartsWith("fanficly:", StringComparison.OrdinalIgnoreCase)
                                               || p.StartsWith("https://", StringComparison.OrdinalIgnoreCase));
        if (uriText is not null && Uri.TryCreate(uriText, UriKind.Absolute, out var uri)) OpenUri(uri);
    }

    /// <summary>Restores a minimised window and brings it to the foreground.</summary>
    public static void BringToFront(MainWindow window)
    {
        if (window.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter { State: Microsoft.UI.Windowing.OverlappedPresenterState.Minimized } p)
            p.Restore();
        window.AppWindow.Show(true);
        window.AppWindow.MoveInZOrderAtTop();
    }
}
