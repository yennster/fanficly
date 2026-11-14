using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class MessageLifetimeTests
{
    [Fact]
    public void ConfirmationsCloseAfterTheDefault() =>
        Assert.Equal(MessageLifetime.DefaultSeconds, MessageLifetime.Seconds(isProblem: false));

    [Fact]
    public void ConfirmationsKeepTheCallersTime() =>
        Assert.Equal(8, MessageLifetime.Seconds(isProblem: false, requested: 8));

    [Fact]
    public void ConfirmationsStayUpAtLeastASecond() =>
        Assert.Equal(1, MessageLifetime.Seconds(isProblem: false, requested: 0));

    [Theory]
    [InlineData(null)]
    [InlineData(6)]
    [InlineData(20)]
    public void ErrorsAndWarningsStayUntilClosed(int? requested) =>
        Assert.Null(MessageLifetime.Seconds(isProblem: true, requested));
}

/// <summary>The download card's wording counts stories properly (#205).</summary>
public class DownloadProgressWordingTests
{
    [Fact]
    public void OneStoryIsSingular()
    {
        var one = new RestoreDownloadCenter.DownloadProgress(1, 0, 1, true);
        Assert.Equal("Downloaded 1 story", one.FinishedTitle);
        Assert.Equal("Downloaded 1 story for offline reading.", one.Announcement);
    }

    [Fact]
    public void SeveralStoriesArePlural()
    {
        Assert.Equal("Downloaded 3 stories", new RestoreDownloadCenter.DownloadProgress(3, 0, 3, true).FinishedTitle);
        Assert.Equal("Downloaded 0 of 1 story", new RestoreDownloadCenter.DownloadProgress(0, 1, 1, true).FinishedTitle);
    }
}
