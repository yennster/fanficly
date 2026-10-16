using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Capturing;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;
using FlaUI.UIA3;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace Fanficly.UITests;

/// <summary>A window size the app is checked and photographed at: the desktop,
/// a tablet held upright, and a narrow phone-like window (where the sidebar
/// collapses to a menu button).</summary>
public sealed record FormFactor(string Name, int Width, int Height, double CaptureScale = 1)
{
    public static readonly FormFactor Desktop = new("desktop", 1600, 1000);
    public static readonly FormFactor Tablet = new("tablet", 834, 1112);
    public static readonly FormFactor Compact = new("compact", 420, 880);

    /// <summary>Store art: a 1440×900 window drawn at 2× ("-captureScale 2"),
    /// so the capture is 2880×1800 whatever the screen's size. It isn't shrunk
    /// to fit the screen; PrintWindow captures the off-screen part too.</summary>
    public static readonly FormFactor Store = new("store", 2880, 1800, 2);

    /// <summary>Store art for an upright tablet: 834×1112 at 2×.</summary>
    public static readonly FormFactor StoreTablet = new("store-tablet", 1668, 2224, 2);

    public static FormFactor Named(string name) =>
        new[] { Desktop, Tablet, Compact, Store, StoreTablet }.First(f => f.Name == name);

    /// <summary>Launch arguments this size needs.</summary>
    public string[] Args => CaptureScale > 1
        ? ["-captureScale", CaptureScale.ToString(System.Globalization.CultureInfo.InvariantCulture)]
        : [];
}

/// <summary>
/// One running copy of the app in demo mode (offline, seeded, deterministic),
/// driven through UI Automation. Disposing closes it. Tests never share a
/// session: the app is single-instance, so a second launch would only hand its
/// arguments to the first.
/// </summary>
public sealed class AppSession : IDisposable
{
    public Application App { get; }
    public UIA3Automation Automation { get; } = new();
    public Window Window { get; private set; }

    private AppSession(Application app, Window window)
    {
        App = app;
        Window = window;
    }

    /// <summary>The app under test: <c>FANFICLY_EXE</c>, or the unpackaged x64
    /// build CI makes (<c>windows/artifacts/app-x64/Fanficly.exe</c>).</summary>
    public static string ExePath =>
        Environment.GetEnvironmentVariable("FANFICLY_EXE") is { Length: > 0 } exe
            ? exe
            : Path.Combine(WindowsRoot, "artifacts", "app-x64", "Fanficly.exe");

    /// <summary>The repo's <c>windows/</c> folder (where the solution lives).</summary>
    public static string WindowsRoot
    {
        get
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Fanficly.Windows.slnx"))) dir = dir.Parent;
            return dir?.FullName ?? Directory.GetCurrentDirectory();
        }
    }

    public static AppSession Launch(FormFactor size, params string[] extraArgs)
    {
        KillStrays();
        var exe = ExePath;
        if (!File.Exists(exe)) throw new FileNotFoundException($"Build the app first, or set FANFICLY_EXE ({exe}).", exe);
        var args = new[] { "-demoMode" }.Concat(size.Args).Concat(extraArgs).Select(Quote);
        var app = Application.Launch(new ProcessStartInfo(exe, string.Join(' ', args)) { UseShellExecute = false });
        var automation = new UIA3Automation();
        var window = app.GetMainWindow(automation, TimeSpan.FromSeconds(45))
                     ?? throw new InvalidOperationException("The main window never appeared.");
        var session = new AppSession(app, window);
        session.Resize(size);
        session.Settle(1500);
        return session;
    }

    private static string Quote(string arg) => arg.Contains(' ') ? $"\"{arg}\"" : arg;

    /// <summary>Closes copies left over from an earlier, aborted run.</summary>
    public static void KillStrays()
    {
        foreach (var p in Process.GetProcessesByName("Fanficly"))
        {
            try { p.Kill(); p.WaitForExit(5000); } catch (Exception) { }
        }
    }

    /// <summary>Sizes the window (in physical pixels), shrunk proportionally
    /// when the screen's work area is smaller, and puts it at the top left.</summary>
    public void Resize(FormFactor size)
    {
        var area = Native.WorkArea();
        var scale = size.CaptureScale > 1 ? 1.0
            : Math.Min(1.0, Math.Min(area.Width / (double)size.Width, area.Height / (double)size.Height));
        var w = (int)(size.Width * scale);
        var h = (int)(size.Height * scale);
        if (Window.Patterns.Window.PatternOrDefault is { } wp && wp.WindowVisualState.ValueOrDefault != WindowVisualState.Normal)
            wp.SetWindowVisualState(WindowVisualState.Normal);
        Native.SetWindowPos(Hwnd, IntPtr.Zero, area.Left, area.Top, w, h, Native.SWP_NOZORDER | Native.SWP_SHOWWINDOW);
        Native.SetForegroundWindow(Hwnd);
    }

    public IntPtr Hwnd => Window.Properties.NativeWindowHandle.ValueOrDefault;

    public void Settle(int milliseconds = 700) => Thread.Sleep(milliseconds);

    // MARK: - Finding things

    public AutomationElement? ById(string id, double seconds = 5) =>
        Retry.WhileNull(() => Window.FindFirstDescendant(cf => cf.ByAutomationId(id)),
            TimeSpan.FromSeconds(seconds), TimeSpan.FromMilliseconds(200)).Result;

    public AutomationElement? ByName(string name, double seconds = 5) =>
        Retry.WhileNull(() => Window.FindFirstDescendant(cf => cf.ByName(name)),
            TimeSpan.FromSeconds(seconds), TimeSpan.FromMilliseconds(200)).Result;

    /// <summary>The first element whose automation id starts with <paramref name="prefix"/>
    /// (e.g. <c>work.</c> for the first work row).</summary>
    public AutomationElement? ByIdPrefix(string prefix, double seconds = 5) =>
        Retry.WhileNull(() => Window.FindAllDescendants()
                .FirstOrDefault(e => e.Properties.AutomationId.ValueOrDefault?.StartsWith(prefix, StringComparison.Ordinal) == true
                                     && !e.IsOffscreen),
            TimeSpan.FromSeconds(seconds), TimeSpan.FromMilliseconds(300)).Result;

    /// <summary>Any of the given ids or names, whichever turns up first.</summary>
    public AutomationElement? Find(double seconds, params string[] idsOrNames) =>
        Retry.WhileNull(() =>
        {
            foreach (var key in idsOrNames)
            {
                var hit = Window.FindFirstDescendant(cf => cf.ByAutomationId(key).Or(cf.ByName(key)));
                if (hit is not null) return hit;
            }
            return null;
        }, TimeSpan.FromSeconds(seconds), TimeSpan.FromMilliseconds(250)).Result;

    /// <summary>The text of the screen header (the current screen's title).</summary>
    public string HeaderTitle => ById("header.title", 2)?.Name ?? "";

    public bool WaitForHeader(string title, double seconds = 8) =>
        Retry.WhileFalse(() => HeaderTitle == title, TimeSpan.FromSeconds(seconds), TimeSpan.FromMilliseconds(250)).Result;

    // MARK: - Acting

    /// <summary>Presses, toggles, expands or selects the element through its
    /// automation pattern, falling back to a mouse click.</summary>
    public void Activate(AutomationElement element)
    {
        element.Patterns.ScrollItem.PatternOrDefault?.ScrollIntoView();
        if (element.Patterns.Invoke.PatternOrDefault is { } invoke) invoke.Invoke();
        else if (element.Patterns.SelectionItem.PatternOrDefault is { } select) select.Select();
        else if (element.Patterns.Toggle.PatternOrDefault is { } toggle) toggle.Toggle();
        else if (element.Patterns.ExpandCollapse.PatternOrDefault is { } expand) expand.Expand();
        else element.Click();
        Settle(400);
    }

    public bool Tap(double seconds, params string[] idsOrNames)
    {
        if (Find(seconds, idsOrNames) is not { } element) return false;
        Activate(element);
        return true;
    }

    public void Keys(params VirtualKeyShort[] keys)
    {
        Native.SetForegroundWindow(Hwnd);
        Keyboard.TypeSimultaneously(keys);
        Settle(300);
    }

    public void Type(string text)
    {
        Keyboard.Type(text);
        Settle(200);
    }

    /// <summary>Opens a sidebar tab with its keyboard shortcut (Ctrl+1…9, Ctrl+,),
    /// which works in every window size, including when the sidebar is folded
    /// away; falls back to the sidebar item.</summary>
    public bool OpenTab(string raw)
    {
        var index = Array.IndexOf(TabOrder, raw);
        if (index < 0) throw new ArgumentException($"Unknown tab {raw}");
        Keys(VirtualKeyShort.CONTROL, raw == "settings" ? VirtualKeyShort.OEM_COMMA : VirtualKeyShort.KEY_1 + (ushort)index);
        if (Retry.WhileFalse(() => IsTabSelected(raw), TimeSpan.FromSeconds(4), TimeSpan.FromMilliseconds(200)).Result)
        {
            Settle();
            return true;
        }
        if (ById($"sidebar.{raw}", 2) is { } item && !item.IsOffscreen) Activate(item);
        Settle();
        return IsTabSelected(raw);
    }

    /// <summary>Sidebar order (Swift's <c>SidebarItem</c>): Ctrl+1 is Search.</summary>
    public static readonly string[] TabOrder =
        ["search", "browse", "popular", "library", "recentlyViewed", "authors", "bookmarks", "subscriptions", "stats", "settings"];

    /// <summary>Whether <paramref name="raw"/> is the open tab (the header
    /// title's item status, which the shell keeps as <c>tab:&lt;raw&gt;</c> in every
    /// window size, unlike the sidebar items, which are hidden when it folds).</summary>
    public bool IsTabSelected(string raw) =>
        Window.FindFirstDescendant(cf => cf.ByAutomationId("header.title")) is { } title
        && title.Properties.ItemStatus.ValueOrDefault == $"tab:{raw}";

    public void GoBack() => Keys(VirtualKeyShort.ALT, VirtualKeyShort.LEFT);

    public bool IsRunning => !App.HasExited;

    // MARK: - Pictures

    /// <summary>Saves the window as a PNG. Renders the window itself
    /// (PrintWindow), so a window larger than the screen or under the taskbar
    /// still comes out whole; falls back to a screen grab.</summary>
    public string Snap(string folder, string name)
    {
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, name + ".png");
        Native.SetForegroundWindow(Hwnd);
        Settle(250);
        using var bitmap = Native.PrintWindow(Hwnd) ?? Capture.Element(Window).Bitmap;
        bitmap.Save(path, ImageFormat.Png);
        return path;
    }

    public void Dispose()
    {
        try
        {
            if (!App.HasExited)
            {
                App.Close();
                if (!App.WaitWhileMainHandleIsMissing(TimeSpan.FromSeconds(1)) || !App.HasExited)
                {
                    using var p = Process.GetProcessById(App.ProcessId);
                    if (!p.WaitForExit(8000)) p.Kill();
                }
            }
        }
        catch (Exception) { }
        App.Dispose();
        Automation.Dispose();
        KillStrays();
    }
}

internal static partial class Native
{
    public const uint SWP_NOZORDER = 0x0004, SWP_SHOWWINDOW = 0x0040;
    private const uint PW_RENDERFULLCONTENT = 0x2;
    private const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
    private const uint SPI_GETWORKAREA = 0x0030;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; public readonly int Width => Right - Left; public readonly int Height => Bottom - Top; }

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetForegroundWindow(IntPtr hWnd);

    [LibraryImport("user32.dll", EntryPoint = "PrintWindow")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PrintWindowNative(IntPtr hWnd, IntPtr hdc, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [LibraryImport("user32.dll", EntryPoint = "SystemParametersInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SystemParametersInfo(uint action, uint param, out RECT rect, uint winIni);

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT rect, int size);

    public static RECT WorkArea() =>
        SystemParametersInfo(SPI_GETWORKAREA, 0, out var r, 0) ? r : new RECT { Right = 1024, Bottom = 768 };

    /// <summary>The window drawn into a bitmap, cropped to its visible frame
    /// (without the invisible resize borders); null when nothing came back.</summary>
    public static Bitmap? PrintWindow(IntPtr hwnd)
    {
        if (!GetWindowRect(hwnd, out var outer) || outer.Width <= 0 || outer.Height <= 0) return null;
        var frame = DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out var f, Marshal.SizeOf<RECT>()) == 0 ? f : outer;
        using var full = new Bitmap(outer.Width, outer.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(full))
        {
            var hdc = g.GetHdc();
            var ok = PrintWindowNative(hwnd, hdc, PW_RENDERFULLCONTENT);
            g.ReleaseHdc(hdc);
            if (!ok) return null;
        }
        var crop = new Rectangle(frame.Left - outer.Left, frame.Top - outer.Top, frame.Width, frame.Height);
        crop.Intersect(new Rectangle(0, 0, full.Width, full.Height));
        if (crop.Width <= 0 || crop.Height <= 0) return null;
        var result = full.Clone(crop, PixelFormat.Format24bppRgb);
        if (IsBlank(result)) { result.Dispose(); return null; }
        return result;
    }

    /// <summary>PrintWindow returns all-black for some composition surfaces.</summary>
    private static bool IsBlank(Bitmap bitmap)
    {
        var first = bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2);
        for (var y = 8; y < bitmap.Height; y += Math.Max(1, bitmap.Height / 24))
            for (var x = 8; x < bitmap.Width; x += Math.Max(1, bitmap.Width / 24))
                if (bitmap.GetPixel(x, y) != first) return false;
        return true;
    }
}
