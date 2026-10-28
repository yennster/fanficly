namespace Fanficly.Core;

/// <summary>
/// "Volume buttons turn pages" (Settings → Reader, off by default): remotes in
/// their volume mode send only volume keys, and with the setting on the reader
/// turns on them instead of the shell changing the volume. The Swift app's
/// <c>VolumeButtonTurn</c>; there it watches the output volume, here the keys
/// arrive as keys.
/// </summary>
public static class VolumeKeyTurn
{
    public const string SettingKey = "reader.volumeButtonsTurnPages";

    public const int VolumeDownKey = 174; // VK_VOLUME_DOWN
    public const int VolumeUpKey = 175;   // VK_VOLUME_UP

    private const int AppCommandVolumeDown = 9;  // APPCOMMAND_VOLUME_DOWN
    private const int AppCommandVolumeUp = 10;   // APPCOMMAND_VOLUME_UP

    /// <summary>Forward for volume up, back for volume down, null for any other key.</summary>
    public static bool? Direction(int virtualKey) => virtualKey switch
    {
        VolumeUpKey => true,
        VolumeDownKey => false,
        _ => null,
    };

    /// <summary>Whether a WM_APPCOMMAND's lParam is volume up or down (mute isn't):
    /// the command the shell would act on if the window let it through.</summary>
    public static bool IsVolumeAppCommand(long lParam)
    {
        // GET_APPCOMMAND_LPARAM: the high word without the FAPPCOMMAND_MASK device bits.
        var command = (int)((lParam >> 16) & 0x0FFF);
        return command is AppCommandVolumeDown or AppCommandVolumeUp;
    }
}
