using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>"Volume buttons turn pages": which key turns which way, and which
/// WM_APPCOMMANDs the reader keeps from the shell.</summary>
public class VolumeKeyTurnTests
{
    [Fact]
    public void UpTurnsForwardDownTurnsBack()
    {
        Assert.True(VolumeKeyTurn.Direction(175));
        Assert.False(VolumeKeyTurn.Direction(174));
        Assert.Null(VolumeKeyTurn.Direction(173)); // VK_VOLUME_MUTE
        Assert.Null(VolumeKeyTurn.Direction(34));  // VK_NEXT (Page Down) has its own case
    }

    [Fact]
    public void SharesTheSwiftKey() =>
        Assert.Equal("reader.volumeButtonsTurnPages", VolumeKeyTurn.SettingKey);

    [Fact]
    public void VolumeAppCommands()
    {
        // lParam's high word is the command plus a device in its top four bits
        // (FAPPCOMMAND_KEY = 0, FAPPCOMMAND_OEM = 0x1000).
        Assert.True(VolumeKeyTurn.IsVolumeAppCommand(10L << 16));
        Assert.True(VolumeKeyTurn.IsVolumeAppCommand((0x1000L | 9) << 16));
        Assert.False(VolumeKeyTurn.IsVolumeAppCommand(8L << 16)); // mute
        Assert.False(VolumeKeyTurn.IsVolumeAppCommand(11L << 16)); // next track
        Assert.False(VolumeKeyTurn.IsVolumeAppCommand(10));        // low word only
    }
}
