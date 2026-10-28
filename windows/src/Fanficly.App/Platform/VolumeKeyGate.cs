using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Fanficly.App.Shell;
using Fanficly.Core;

namespace Fanficly.App.Platform;

/// <summary>
/// Keeps volume keys from changing the volume while "Volume buttons turn pages"
/// has the reader turning on them (the screen on top says so through
/// <see cref="Screen.WantsVolumeKeys"/>). A volume key the window doesn't consume
/// comes back from DefWindowProc as WM_APPCOMMAND, which the shell acts on;
/// answering it TRUE is the documented way to say the app handled it. The key
/// itself still turns the page through <c>ReaderView.HandleKey</c>.
/// </summary>
internal static unsafe partial class VolumeKeyGate
{
    private const uint WM_APPCOMMAND = 0x0319;

    public static void Install(IntPtr hwnd) =>
        SetWindowSubclass(hwnd, &SubclassProc, 0x564F4C4B /* "VOLK" */, 0);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static IntPtr SubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, nuint id, nuint data)
    {
        if (msg == WM_APPCOMMAND && VolumeKeyTurn.IsVolumeAppCommand(lParam)
            && MainWindow.Current?.Navigator.Current?.WantsVolumeKeys == true)
        {
            return 1;
        }
        return DefSubclassProc(hwnd, msg, wParam, lParam);
    }

    [LibraryImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowSubclass(IntPtr hwnd,
        delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, IntPtr, nuint, nuint, IntPtr> proc, nuint id, nuint data);

    [LibraryImport("comctl32.dll")]
    private static partial IntPtr DefSubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
}
