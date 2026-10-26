using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;

namespace Fanficly.App.Platform;

/// <summary>
/// The default speakers' master volume, through Core Audio. "Volume buttons turn
/// pages" holds it where it was while a volume key turns the page: Windows' shell
/// changes the volume itself before or after the app sees the key, so the reader
/// remembers the level and puts it back. (The Swift app's counterpart is
/// <c>VolumeButtonPageTurner</c>, which does the same through a hidden
/// <c>MPVolumeView</c>.) Every call is best effort: no audio device, or a
/// failing COM call, just leaves the volume alone.
/// </summary>
internal static partial class SystemVolume
{
    private static readonly StrategyBasedComWrappers Wrappers = new();
    private static readonly Guid MMDeviceEnumeratorClsid = new("BCDE0395-E52F-467C-8E3D-C4579291692E");
    private static readonly Guid MMDeviceEnumeratorIid = new("A95664D2-9614-4F35-A746-DE8DB63617E6");
    private static readonly Guid AudioEndpointVolumeIid = new("5CDF2C82-841E-4546-9722-0CF74078229A");
    private const uint ClsctxAll = 0x17;
    private const int ERender = 0;
    private const int EMultimedia = 1;

    /// <summary>The level (0–1) of the default output, or null when there's none.</summary>
    public static float? Get()
    {
        try
        {
            if (Endpoint() is not { } volume) return null;
            return volume.GetMasterVolumeLevelScalar(out var level) >= 0 ? level : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static void Set(float level)
    {
        try
        {
            if (Endpoint() is not { } volume) return;
            var context = Guid.Empty;
            volume.SetMasterVolumeLevelScalar(Math.Clamp(level, 0f, 1f), in context);
        }
        catch (Exception)
        {
            // Best effort (see the summary).
        }
    }

    private static IAudioEndpointVolume? Endpoint()
    {
        if (CoCreateInstance(MMDeviceEnumeratorClsid, IntPtr.Zero, ClsctxAll, MMDeviceEnumeratorIid, out var enumeratorPtr) < 0) return null;
        try
        {
            var enumerator = (IMMDeviceEnumerator)Wrappers.GetOrCreateObjectForComInstance(enumeratorPtr, CreateObjectFlags.None);
            if (enumerator.GetDefaultAudioEndpoint(ERender, EMultimedia, out var devicePtr) < 0) return null;
            try
            {
                var device = (IMMDevice)Wrappers.GetOrCreateObjectForComInstance(devicePtr, CreateObjectFlags.None);
                if (device.Activate(AudioEndpointVolumeIid, ClsctxAll, IntPtr.Zero, out var volumePtr) < 0) return null;
                try
                {
                    return (IAudioEndpointVolume)Wrappers.GetOrCreateObjectForComInstance(volumePtr, CreateObjectFlags.None);
                }
                finally { Marshal.Release(volumePtr); }
            }
            finally { Marshal.Release(devicePtr); }
        }
        finally { Marshal.Release(enumeratorPtr); }
    }

    [LibraryImport("ole32.dll")]
    private static partial int CoCreateInstance(in Guid clsid, IntPtr outer, uint context, in Guid iid, out IntPtr instance);
}

// Only the leading methods each call needs are declared; COM vtables are ordered,
// so the rest can be left off the end.

[GeneratedComInterface]
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
internal partial interface IMMDeviceEnumerator
{
    [PreserveSig]
    int EnumAudioEndpoints(int dataFlow, uint stateMask, out IntPtr devices);

    [PreserveSig]
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IntPtr endpoint);
}

[GeneratedComInterface]
[Guid("D666063F-1587-4E43-81F1-B948E807363F")]
internal partial interface IMMDevice
{
    [PreserveSig]
    int Activate(in Guid iid, uint context, IntPtr activationParams, out IntPtr instance);
}

[GeneratedComInterface]
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
internal partial interface IAudioEndpointVolume
{
    [PreserveSig]
    int RegisterControlChangeNotify(IntPtr notify);

    [PreserveSig]
    int UnregisterControlChangeNotify(IntPtr notify);

    [PreserveSig]
    int GetChannelCount(out uint count);

    [PreserveSig]
    int SetMasterVolumeLevel(float levelDb, in Guid eventContext);

    [PreserveSig]
    int SetMasterVolumeLevelScalar(float level, in Guid eventContext);

    [PreserveSig]
    int GetMasterVolumeLevel(out float levelDb);

    [PreserveSig]
    int GetMasterVolumeLevelScalar(out float level);
}
