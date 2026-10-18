using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Fanficly.App.Platform;

/// <summary>
/// "-captureScale 2" (demo mode only): draws the whole window, title bar
/// included, at that scale, so Store art can be captured at 4K from a runner
/// whose screen is far smaller. The window may then be larger than the screen
/// (the UI tests capture it with PrintWindow, which draws off-screen parts too).
/// The system caption buttons can't scale, so they're hidden and drawn as
/// plain glyphs instead. The Windows counterpart of the iOS "marketing mode".
/// </summary>
internal static unsafe partial class CaptureMode
{
    public static double Scale { get; } = ParseScale();

    public static bool IsOn => Scale > 1.001;

    private static double ParseScale()
    {
        if (!AppHost.IsDemoMode) return 1;
        var args = Environment.GetCommandLineArgs();
        var i = Array.IndexOf(args, "-captureScale");
        return i >= 0 && i + 1 < args.Length
               && double.TryParse(args[i + 1], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var s)
            ? Math.Clamp(s, 1, 4) : 1;
    }

    /// <summary>Wraps the window's root in a scaled host; returns the new content.</summary>
    public static UIElement Wrap(MainWindow window, FrameworkElement root)
    {
        if (!IsOn) return root;
        var host = new Grid();
        root.HorizontalAlignment = HorizontalAlignment.Left;
        root.VerticalAlignment = VerticalAlignment.Top;
        root.RenderTransform = new ScaleTransform { ScaleX = Scale, ScaleY = Scale };
        host.Children.Add(root);
        host.SizeChanged += (_, e) =>
        {
            root.Width = e.NewSize.Width / Scale;
            root.Height = e.NewSize.Height / Scale;
        };
        if (window.AppWindow.Presenter is OverlappedPresenter presenter) presenter.SetBorderAndTitleBar(true, false);
        AllowLargerThanScreen(Microsoft.UI.Win32Interop.GetWindowFromWindowId(window.AppWindow.Id));
        return host;
    }

    /// <summary>Minimize, maximize and close, drawn like Windows 11's (they're decoration here).</summary>
    public static FrameworkElement CaptionGlyphs()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Stretch };
        foreach (var glyph in new[] { "", "", "" })
        {
            row.Children.Add(new Border
            {
                Width = 46,
                Child = new FontIcon
                {
                    Glyph = glyph,
                    FontFamily = Symbols.Font,
                    FontSize = 10,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            });
        }
        return row;
    }

    // MARK: - Larger than the screen

    private const uint WM_GETMINMAXINFO = 0x0024;

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MINMAXINFO { public POINT Reserved, MaxSize, MaxPosition, MinTrackSize, MaxTrackSize; }

    private static void AllowLargerThanScreen(IntPtr hwnd) =>
        SetWindowSubclass(hwnd, &SubclassProc, 0x46414E46 /* "FANF" */, 0);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static IntPtr SubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, nuint id, nuint data)
    {
        var result = DefSubclassProc(hwnd, msg, wParam, lParam);
        if (msg == WM_GETMINMAXINFO)
        {
            var info = (MINMAXINFO*)lParam;
            info->MaxTrackSize = new POINT { X = 16384, Y = 16384 };
            return 0;
        }
        return result;
    }

    [LibraryImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowSubclass(IntPtr hwnd,
        delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, IntPtr, nuint, nuint, IntPtr> proc, nuint id, nuint data);

    [LibraryImport("comctl32.dll")]
    private static partial IntPtr DefSubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
}
