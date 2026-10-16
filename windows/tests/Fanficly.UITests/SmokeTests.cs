using System.Diagnostics;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace Fanficly.UITests;

/// <summary>Launch, navigation and window-level behaviour, at a laptop-sized
/// window (the sidebar expanded) and a narrow one (the sidebar folded away).</summary>
public sealed class SmokeTests
{
    private static readonly FormFactor Laptop = new("laptop", 1280, 800);

    [Fact]
    public void LaunchesInDemoModeWithAHeader()
    {
        using var s = AppSession.Launch(Laptop);
        Assert.True(s.IsRunning);
        Assert.False(string.IsNullOrEmpty(s.HeaderTitle), "The screen header has no title.");
        Assert.NotNull(s.ById("sidebar.library"));
    }

    [Theory]
    [InlineData("laptop")]
    [InlineData("compact")]
    public void EveryTabOpensFromItsShortcut(string size)
    {
        using var s = AppSession.Launch(size == "laptop" ? Laptop : FormFactor.Compact);
        var titles = new HashSet<string>();
        foreach (var raw in AppSession.TabOrder)
        {
            Assert.True(s.OpenTab(raw), $"Ctrl shortcut didn't open {raw}.");
            var title = s.HeaderTitle;
            Assert.False(string.IsNullOrEmpty(title), $"{raw} has no header title.");
            titles.Add(title);
            Assert.True(s.IsRunning, $"The app quit opening {raw}.");
        }
        Assert.Equal(AppSession.TabOrder.Length, titles.Count);
    }

    [Fact]
    public void SidebarItemOpensItsTab()
    {
        using var s = AppSession.Launch(Laptop);
        var item = s.ById("sidebar.library");
        Assert.NotNull(item);
        s.Activate(item!);
        Assert.True(Retry.WhileFalse(() => s.IsTabSelected("library"), TimeSpan.FromSeconds(4)).Result);
        Assert.True(s.WaitForHeader("Library"));
    }

    [Fact]
    public void LaunchArgumentOpensATab()
    {
        using var s = AppSession.Launch(Laptop, "-tab", "popular");
        Assert.True(Retry.WhileFalse(() => s.IsTabSelected("popular"), TimeSpan.FromSeconds(6)).Result);
    }

    [Fact]
    public void BackReturnsToTheTabRoot()
    {
        using var s = AppSession.Launch(Laptop);
        Assert.True(s.OpenTab("browse"));
        var root = s.HeaderTitle;
        Assert.True(s.Tap(6, "TV Shows"), "No TV Shows category on Browse.");
        Assert.True(Retry.WhileFalse(() => s.HeaderTitle != root, TimeSpan.FromSeconds(6)).Result, "TV Shows didn't open.");
        s.GoBack();
        Assert.True(s.WaitForHeader(root), "Alt+Left didn't go back.");
    }

    [Fact]
    public void ZoomAndFullScreenKeysKeepTheAppRunning()
    {
        using var s = AppSession.Launch(Laptop);
        s.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.OEM_PLUS);
        s.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.OEM_PLUS);
        s.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.OEM_MINUS);
        s.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_0);
        s.Keys(VirtualKeyShort.F11);
        s.Keys(VirtualKeyShort.F11);
        Assert.True(s.IsRunning);
        Assert.True(s.OpenTab("library"));
    }

    /// <summary>A second launch (a link, a jump-list task, a toast) hands its
    /// arguments to the running window and exits.</summary>
    [Fact]
    public void SecondLaunchIsRedirectedToTheRunningWindow()
    {
        using var s = AppSession.Launch(Laptop);
        Assert.True(s.OpenTab("search"));
        using var second = Process.Start(new ProcessStartInfo(AppSession.ExePath, "-demoMode -tab library") { UseShellExecute = false })!;
        Assert.True(second.WaitForExit(20_000), "The second copy kept running.");
        Assert.True(s.IsRunning);
        Assert.True(Retry.WhileFalse(() => s.IsTabSelected("library"), TimeSpan.FromSeconds(8)).Result,
            "The running window didn't switch to Library.");
    }

    [Fact]
    public void SearchDeepLinkOpensSearch()
    {
        using var s = AppSession.Launch(Laptop, "fanficly://search?query=slow%20burn");
        Assert.True(Retry.WhileFalse(() => s.IsTabSelected("search"), TimeSpan.FromSeconds(8)).Result);
    }
}
