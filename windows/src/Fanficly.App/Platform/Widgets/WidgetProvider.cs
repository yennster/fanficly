using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;
using Fanficly.Core;
using Microsoft.Windows.Widgets;
using Microsoft.Windows.Widgets.Providers;

namespace Fanficly.App.Platform.Widgets;

/// <summary>
/// The Windows Widgets board provider. Windows starts Fanficly.exe with
/// "-RegisterProcessAsComServer" when a widget needs content; this process
/// registers the provider's class factory and serves updates without opening
/// a window. The running app also pushes updates whenever reading progress
/// changes (<see cref="WidgetCenter"/>).
/// </summary>
[Guid(ClassId)]
public sealed partial class FanficlyWidgetProvider : IWidgetProvider
{
    public const string ClassId = "B46F852C-289F-47B1-AB03-CC6793490B34";

    private static readonly Lock Gate = new();
    private static readonly Dictionary<string, string> ActiveWidgets = []; // id → size

    internal static event Action? AllWidgetsGone;

    public FanficlyWidgetProvider()
    {
        // Recover widgets Windows already knows about (provider restarts).
        try
        {
            foreach (var info in WidgetManager.GetDefault().GetWidgetInfos())
            {
                var ctx = info.WidgetContext;
                lock (Gate) ActiveWidgets[ctx.Id] = SizeName(ctx.Size);
            }
        }
        catch { }
    }

    public void CreateWidget(WidgetContext widgetContext)
    {
        lock (Gate) ActiveWidgets[widgetContext.Id] = SizeName(widgetContext.Size);
        Update(widgetContext.Id, SizeName(widgetContext.Size));
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
        lock (Gate) ActiveWidgets[ctx.Id] = SizeName(ctx.Size);
        Update(ctx.Id, SizeName(ctx.Size));
    }

    public void Activate(WidgetContext widgetContext)
    {
        lock (Gate) ActiveWidgets[widgetContext.Id] = SizeName(widgetContext.Size);
        Update(widgetContext.Id, SizeName(widgetContext.Size));
    }

    public void Deactivate(string widgetId) { }

    private static string SizeOf(string id)
    {
        lock (Gate) return ActiveWidgets.TryGetValue(id, out var s) ? s : "medium";
    }

    private static string SizeName(WidgetSize size) => size switch
    {
        WidgetSize.Small => "small",
        WidgetSize.Large => "large",
        _ => "medium",
    };

    /// <summary>Pushes fresh content to one widget.</summary>
    public static void Update(string widgetId, string size)
    {
        try
        {
            var options = new WidgetUpdateRequestOptions(widgetId)
            {
                Template = LastReadWidget.Template(size),
                Data = LastReadWidget.Data(WidgetStorage.LoadLastRead()),
            };
            WidgetManager.GetDefault().UpdateWidget(options);
        }
        catch (Exception e)
        {
            AppHost.Log($"Widget update failed: {e.Message}");
        }
    }

    /// <summary>Refreshes every pinned Fanficly widget (called from the app).</summary>
    public static void UpdateAll()
    {
        try
        {
            foreach (var info in WidgetManager.GetDefault().GetWidgetInfos())
                Update(info.WidgetContext.Id, SizeName(info.WidgetContext.Size));
        }
        catch (Exception e)
        {
            AppHost.Log($"Widget refresh failed: {e.Message}");
        }
    }
}

/// <summary>The widget reads the same shared store the app writes (the app-group defaults on iOS).</summary>
public static class WidgetStorage
{
    public static string SharedStorePath => Path.Combine(Services.AppPaths.Shared, "group.json");

    public static WidgetStoryProgress? LoadLastRead()
    {
        // A fresh read every time: the app may have written since.
        var store = new JsonFileKeyValueStore(SharedStorePath);
        return WidgetStoryProgress.Decode(store.GetString(WidgetProgressStore.LastReadProgressKey));
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
