using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;
using System.Text.Json;
using Fanficly.Core;
using Microsoft.Windows.Widgets;
using Microsoft.Windows.Widgets.Providers;

namespace Fanficly.App.Platform.Widgets;

/// <summary>
/// The Windows Widgets board provider for all six widgets (the Swift widget
/// bundle): Continue reading, Reading Streak, Subscriptions, Folder Shortcuts,
/// Saved Searches and Recommendation, each small and medium. Windows starts
/// Fanficly.exe with "-RegisterProcessAsComServer" when a widget needs
/// content; this process registers the provider's class factory and serves
/// updates without opening a window. The running app also pushes updates
/// whenever the widgets' data changes (<see cref="WidgetCenter"/>).
/// </summary>
[Guid(ClassId)]
public sealed partial class FanficlyWidgetProvider : IWidgetProvider
{
    public const string ClassId = "B46F852C-289F-47B1-AB03-CC6793490B34";

    private static readonly Lock Gate = new();
    private static readonly Lock RenderGate = new();
    private static readonly Dictionary<string, (string Definition, string Size)> ActiveWidgets = []; // id → kind, size

    internal static event Action? AllWidgetsGone;

    public FanficlyWidgetProvider()
    {
        // Recover widgets Windows already knows about (provider restarts).
        try
        {
            foreach (var info in WidgetManager.GetDefault().GetWidgetInfos())
                Track(info.WidgetContext);
        }
        catch { }
    }

    public void CreateWidget(WidgetContext widgetContext)
    {
        Track(widgetContext);
        Update(widgetContext.Id, widgetContext.DefinitionId, SizeName(widgetContext.Size));
    }

    public void DeleteWidget(string widgetId, string customState)
    {
        bool empty;
        lock (Gate) { ActiveWidgets.Remove(widgetId); empty = ActiveWidgets.Count == 0; }
        if (empty) AllWidgetsGone?.Invoke();
    }

    public void OnActionInvoked(WidgetActionInvokedArgs actionInvokedArgs)
    {
        // Cards use Action.OpenUrl; nothing to do for verbs.
    }

    public void OnWidgetContextChanged(WidgetContextChangedArgs contextChangedArgs)
    {
        var ctx = contextChangedArgs.WidgetContext;
        Track(ctx);
        Update(ctx.Id, ctx.DefinitionId, SizeName(ctx.Size));
    }

    /// <summary>The board became visible: refresh, so the streak's "today" and
    /// the recommendation's rotation are current (what the Swift timelines'
    /// 15/30-minute reloads do).</summary>
    public void Activate(WidgetContext widgetContext)
    {
        Track(widgetContext);
        Update(widgetContext.Id, widgetContext.DefinitionId, SizeName(widgetContext.Size));
    }

    public void Deactivate(string widgetId) { }

    private static void Track(WidgetContext ctx)
    {
        lock (Gate) ActiveWidgets[ctx.Id] = (ctx.DefinitionId, SizeName(ctx.Size));
    }

    private static string SizeName(WidgetSize size) => size switch
    {
        WidgetSize.Small => "small",
        WidgetSize.Large => "large",
        _ => "medium",
    };

    /// <summary>Pushes fresh content to one widget of the given kind.</summary>
    public static void Update(string widgetId, string definitionId, string size)
    {
        try
        {
            // Widget callbacks arrive on COM threads and the app pushes from its
            // own; one render at a time keeps the per-update store swap safe.
            lock (RenderGate)
            {
                var manager = WidgetManager.GetDefault();
                string? customState = null;
                if (definitionId == RecommendationWidget.DefinitionId)
                {
                    try { customState = manager.GetWidgetInfo(widgetId)?.CustomState; } catch { }
                }
                var content = WidgetCatalog.Render(definitionId, size, customState);
                var options = new WidgetUpdateRequestOptions(widgetId)
                {
                    Template = content.Template,
                    Data = content.Data,
                };
                if (content.CustomState is not null) options.CustomState = content.CustomState;
                manager.UpdateWidget(options);
            }
        }
        catch (Exception e)
        {
            AppHost.Log($"Widget update failed ({definitionId}): {e.Message}");
        }
    }

    /// <summary>Refreshes every pinned Fanficly widget, of every kind (the app
    /// calls it through <see cref="WidgetCenter.ReloadAllTimelines"/>, and so
    /// does the background refresh task).</summary>
    public static void UpdateAll()
    {
        // Demo mode's curated library lives in memory; it must not reach the
        // user's real pinned widgets.
        if (AppHost.IsDemoMode) return;
        try
        {
            // GetWidgetInfos returns null, not an empty array, while no
            // Fanficly widget is pinned.
            foreach (var info in WidgetManager.GetDefault().GetWidgetInfos() ?? [])
            {
                var ctx = info.WidgetContext;
                Update(ctx.Id, ctx.DefinitionId, SizeName(ctx.Size));
            }
        }
        catch (Exception e)
        {
            AppHost.Log($"Widget refresh failed: {e.Message}");
        }
    }
}

/// <summary>Which card each widget definition draws, with its data.</summary>
internal static class WidgetCatalog
{
    /// <summary>Renders the definition (a Package.appxmanifest Definition Id).</summary>
    public static WidgetContent Render(string definitionId, string size, string? customState)
    {
        WidgetStorage.Refresh();
        return definitionId switch
        {
            StreakWidget.DefinitionId => StreakWidget.Content(size, WidgetStorage.LoadStreakDates()),
            SubscriptionsWidget.DefinitionId => SubscriptionsWidget.Content(size, WidgetDataStore.LoadLocalSubscriptions()),
            FolderShortcutsWidget.DefinitionId => FolderShortcutsWidget.Content(size, WidgetDataStore.LoadLocalFolders()),
            SavedSearchesWidget.DefinitionId => SavedSearchesWidget.Content(size, WidgetDataStore.LoadLocalSavedSearches()),
            RecommendationWidget.DefinitionId => RecommendationWidget.Content(size, WidgetDataStore.LoadLocalRecommendations(), customState),
            // "LastRead", and anything an older manifest declared.
            _ => new WidgetContent(LastReadWidget.Template(size), LastReadWidget.Data(WidgetStorage.LoadLastRead())),
        };
    }
}

/// <summary>
/// The widgets read the same shared store the app writes (the app-group
/// defaults on iOS): <c>Shared/group.json</c>. Inside the app that's the live
/// <see cref="AppGroupStore.Shared"/> (its newest writes may not be on disk
/// yet); in the widget COM server it's re-read from disk before every update,
/// since the app may have written since.
/// </summary>
public static class WidgetStorage
{
    public static string SharedStorePath => Path.Combine(Services.AppPaths.Shared, "group.json");

    /// <summary>Set in the widget COM server, which doesn't own the store: it
    /// re-reads the file before each render and never writes it.</summary>
    internal static bool ReadsFreshCopies { get; set; }

    /// <summary>In the widget server, swaps a fresh copy of the shared file in
    /// as <see cref="AppGroupStore.Shared"/> (what <see cref="WidgetDataStore"/>'s
    /// loaders read). Inside the app it leaves the live store alone.</summary>
    public static void Refresh()
    {
        if (!ReadsFreshCopies && AppGroupStore.Shared is not null) return;
        var previous = AppGroupStore.Shared as IDisposable;
        AppGroupStore.Shared = new JsonFileKeyValueStore(SharedStorePath);
        previous?.Dispose();
    }

    public static WidgetStoryProgress? LoadLastRead()
    {
        Refresh();
        return WidgetStoryProgress.Decode(AppGroupStore.Shared?.GetString(WidgetProgressStore.LastReadProgressKey));
    }

    /// <summary>The days read (<c>streak.activityDates</c>, a JSON array of
    /// yyyy-MM-dd strings), which <see cref="StreakStore"/> writes to the shared
    /// store. Read directly rather than through <c>StreakStore.LoadStreakInfo</c>,
    /// which can write back; a widget must never write the app's store.</summary>
    public static IReadOnlyList<string> LoadStreakDates()
    {
        Refresh();
        return DecodeDates(AppGroupStore.Shared?.GetString(StreakStore.ActivityDatesKey));
    }

    internal static IReadOnlyList<string> DecodeDates(string? json)
    {
        if (string.IsNullOrEmpty(json)) return [];
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return [];
            return doc.RootElement.EnumerateArray()
                .Where(e => e.ValueKind == JsonValueKind.String)
                .Select(e => e.GetString()!)
                .ToList();
        }
        catch (JsonException)
        {
            return [];
        }
    }

    /// <summary>Copies the streak into the shared store when only the app's own
    /// settings have it (history from before the shared store existed), so the
    /// Reading Streak widget sees it. <see cref="StreakStore"/> writes both
    /// stores from then on.</summary>
    public static void MirrorStreak(IKeyValueStore from, IKeyValueStore to)
    {
        if (to.GetString(StreakStore.ActivityDatesKey) is not null) return;
        if (from.GetString(StreakStore.ActivityDatesKey) is not { } dates) return;
        to.SetString(StreakStore.ActivityDatesKey, dates);
        if (from.GetString(StreakStore.CurrentStreakKey) is { } streak) to.SetString(StreakStore.CurrentStreakKey, streak);
    }
}

/// <summary>Registers the provider's COM class factory and keeps the process alive while widgets exist.</summary>
public static partial class WidgetComServer
{
    private const uint ClsctxLocalServer = 0x4;
    private const uint RegclsMultipleUse = 1;

    [LibraryImport("ole32.dll")]
    private static partial int CoRegisterClassObject(in Guid clsid, IntPtr unknown, uint context, uint flags, out uint cookie);

    [LibraryImport("ole32.dll")]
    private static partial int CoRevokeClassObject(uint cookie);

    public static void Run()
    {
        WidgetStorage.ReadsFreshCopies = true;
        var done = new ManualResetEvent(false);
        FanficlyWidgetProvider.AllWidgetsGone += () => done.Set();
        var wrappers = new StrategyBasedComWrappers();
        var factory = new WidgetProviderFactory();
        var unknown = wrappers.GetOrCreateComInterfaceForObject(factory, CreateComInterfaceFlags.None);
        var clsid = Guid.Parse(FanficlyWidgetProvider.ClassId);
        var hr = CoRegisterClassObject(clsid, unknown, ClsctxLocalServer, RegclsMultipleUse, out var cookie);
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        // Windows ends the process when it no longer needs it; stop sooner once
        // the last widget is unpinned.
        done.WaitOne();
        CoRevokeClassObject(cookie);
        Marshal.Release(unknown);
    }
}

[GeneratedComInterface]
[Guid("00000001-0000-0000-C000-000000000046")]
internal partial interface IClassFactory
{
    [PreserveSig]
    int CreateInstance(IntPtr outer, in Guid riid, out IntPtr instance);

    [PreserveSig]
    int LockServer([MarshalAs(UnmanagedType.Bool)] bool doLock);
}

[GeneratedComClass]
internal sealed partial class WidgetProviderFactory : IClassFactory
{
    private const int ClassENoAggregation = unchecked((int)0x80040110);

    public int CreateInstance(IntPtr outer, in Guid riid, out IntPtr instance)
    {
        instance = IntPtr.Zero;
        if (outer != IntPtr.Zero) return ClassENoAggregation;
        var inspectable = WinRT.MarshalInspectable<IWidgetProvider>.FromManaged(new FanficlyWidgetProvider());
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
