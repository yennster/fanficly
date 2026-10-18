using System.Runtime.InteropServices;

namespace Fanficly.App.Platform;

/// <summary>
/// Keeps narration on schedule with the window minimized. Windows 11 runs a
/// minimized or hidden window's process at reduced speed (EcoQoS), which can let
/// playback catch up with the paragraphs <c>SpeechController</c> synthesizes
/// ahead, leaving gaps or a stall between paragraphs. While a chapter is loaded
/// the process opts out of execution-speed throttling; afterwards Windows
/// manages it again. (The Swift app's counterpart is the
/// <c>ProcessInfo.beginActivity</c> that keeps App Nap off on the Mac.)
/// </summary>
internal static partial class PowerThrottling
{
    private const int ProcessPowerThrottling = 4; // PROCESS_INFORMATION_CLASS
    private const uint ExecutionSpeed = 0x1;      // PROCESS_POWER_THROTTLING_EXECUTION_SPEED

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_POWER_THROTTLING_STATE
    {
        public uint Version;
        public uint ControlMask;
        public uint StateMask;
    }

    /// <summary>True: never throttle this process's speed. False: let Windows decide (the default).</summary>
    public static void SetOptedOut(bool optedOut)
    {
        var state = new PROCESS_POWER_THROTTLING_STATE
        {
            Version = 1,
            // Control the flag with it cleared to opt out; control nothing to hand it back.
            ControlMask = optedOut ? ExecutionSpeed : 0,
            StateMask = 0,
        };
        try
        {
            if (!SetProcessInformation(GetCurrentProcess(), ProcessPowerThrottling, ref state,
                    (uint)Marshal.SizeOf<PROCESS_POWER_THROTTLING_STATE>()))
                AppHost.Log($"Power throttling opt-out failed: {Marshal.GetLastPInvokeError()}");
        }
        catch (EntryPointNotFoundException)
        {
            // Older Windows 10 builds have no power throttling to opt out of.
        }
    }

    [LibraryImport("kernel32.dll")]
    private static partial IntPtr GetCurrentProcess();

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetProcessInformation(IntPtr process, int informationClass,
        ref PROCESS_POWER_THROTTLING_STATE information, uint size);
}
