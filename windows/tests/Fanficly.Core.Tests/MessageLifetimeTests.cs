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
        Assert.Equal("Downloaded 1 of 2 stories", new RestoreDownloadCenter.DownloadProgress(1, 1, 2, true).FinishedTitle);
    }
}

/// <summary>Download failures name the step that failed (#205).</summary>
public class DownloadFailureWordingTests
{
    [Fact]
    public void TextStepFailingSavesNothing() =>
        Assert.Equal("Couldn't get the story's text from AO3, so nothing was saved: offline",
            DownloadFailureWording.For(textSaved: false, fetchingEpub: false, "offline"));

    [Fact]
    public void EpubStepAfterTextSaved() =>
        Assert.Equal("The text is saved for offline reading, but the EPUB download failed: offline",
            DownloadFailureWording.For(textSaved: true, fetchingEpub: true, "offline"));

    [Fact]
    public void EpubStepWithNoTextSavedNeverClaimsText() =>
        Assert.Equal("The EPUB download failed: offline",
            DownloadFailureWording.For(textSaved: false, fetchingEpub: true, "offline"));
}

public class MessageSentenceTests
{
    [Theory]
    [InlineData("No connection", "No connection.")]
    [InlineData("AO3 isn't responding right now.", "AO3 isn't responding right now.")]
    [InlineData("Slow down! ", "Slow down!")]
    [InlineData("", "")]
    public void EndsWithAFullStop(string reason, string expected) =>
        Assert.Equal(expected, MessageLifetime.Sentence(reason));
}
