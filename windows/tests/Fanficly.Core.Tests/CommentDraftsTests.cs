using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>#204: a comment draft outlives the comments screen, and a failed post
/// says what went wrong without inviting a double post.</summary>
public class CommentDraftsTests
{
    [Fact]
    public void KeepsADraftPerWorkAndChapter()
    {
        var drafts = new CommentDrafts();
        drafts.Set(1, 10, "Chapter ten was lovely.");
        drafts.Set(1, null, "The whole work!");

        Assert.Equal("Chapter ten was lovely.", drafts.Get(1, 10));
        Assert.Equal("The whole work!", drafts.Get(1, null));
        Assert.Equal("", drafts.Get(1, 11));
        Assert.Equal("", drafts.Get(2, 10));
    }

    [Fact]
    public void BlankTextAndClearForgetTheDraft()
    {
        var drafts = new CommentDrafts();
        drafts.Set(1, 10, "Draft");
        drafts.Set(1, 10, "  \n ");
        Assert.Equal("", drafts.Get(1, 10));

        drafts.Set(1, 10, "Draft");
        drafts.Clear(1, 10);
        Assert.Equal("", drafts.Get(1, 10));
    }

    [Fact]
    public void KeepsTheTextExactlyAsTyped()
    {
        var drafts = new CommentDrafts();
        drafts.Set(1, 10, "  Line one\nLine two  ");
        Assert.Equal("  Line one\nLine two  ", drafts.Get(1, 10));
    }

    [Fact]
    public void ARefusalIsAO3sOwnSentence()
    {
        Assert.Equal("Couldn't save comment! Comment content can't be blank.",
            CommentPostError.Message(AO3Exception.Rejected("Couldn't save comment! Comment content can't be blank.")));
        Assert.Equal("AO3 didn't confirm the comment was posted. Check the comments before posting it again.",
            CommentPostError.Message(AO3Exception.Rejected(CommentPostOutcome.Unconfirmed)));
        Assert.DoesNotContain("moderation", CommentPostError.Message(AO3Exception.Rejected("Nope")));
    }

    [Fact]
    public void KeepsANewerDraftWhenAnOlderPostLands()
    {
        var drafts = new CommentDrafts();
        drafts.Set(1, 10, "First comment");
        drafts.Set(1, 10, "A newer comment");
        drafts.ClearIfPosted(1, 10, "First comment");
        Assert.Equal("A newer comment", drafts.Get(1, 10));

        drafts.ClearIfPosted(1, 10, "A newer comment");
        Assert.Equal("", drafts.Get(1, 10));
    }

    [Fact]
    public void ANoticeIsReadOnce()
    {
        var drafts = new CommentDrafts();
        Assert.Null(drafts.TakeNotice(1, 10));
        drafts.SetNotice(1, 10, "Couldn't post.");
        Assert.Null(drafts.TakeNotice(1, 11));
        Assert.Equal("Couldn't post.", drafts.TakeNotice(1, 10));
        Assert.Null(drafts.TakeNotice(1, 10));
    }

    [Fact]
    public void AnUncertainPostSaysItMayHaveBeenPosted()
    {
        var message = CommentPostError.Message(new CommentPostUncertainException(AO3Exception.Network("The request timed out.")));
        Assert.Equal("Couldn't post. Couldn't reach AO3: The request timed out. " + CommentPostError.MayHavePosted, message);
    }

    [Theory]
    [MemberData(nameof(MaybeSent))]
    public void FailuresAfterSendingWarnAgainstADoublePost(Exception e)
    {
        Assert.True(CommentPostUncertainException.MayHaveReachedAO3(e));
        var message = CommentPostError.Message(new CommentPostUncertainException(e));
        Assert.StartsWith("Couldn't post. ", message);
        Assert.EndsWith(CommentPostError.MayHavePosted, message);
        Assert.DoesNotContain("..", message);
        Assert.DoesNotContain("moderation", message);
    }

    public static TheoryData<Exception> MaybeSent() =>
    [
        AO3Exception.Network("connection reset", new IOException("reset")),
        AO3Exception.Network("The request timed out.", new TimeoutException("The request timed out.")),
        AO3Exception.Http(503),
        AO3Exception.Http(500),
        new HttpRequestException("An error occurred while sending the request."),
        new IOException("The response ended prematurely"),
    ];

    [Theory]
    [MemberData(nameof(NeverSent))]
    public void FailuresThatNeverReachedAO3AreNotUncertain(Exception e) =>
        Assert.False(CommentPostUncertainException.MayHaveReachedAO3(e));

    public static TheoryData<Exception> NeverSent() =>
    [
        AO3Exception.Network("No such host", new HttpRequestException(HttpRequestError.NameResolutionError, "No such host")),
        AO3Exception.Network("refused", new HttpRequestException("refused",
            new System.Net.Sockets.SocketException((int)System.Net.Sockets.SocketError.ConnectionRefused))),
        AO3Exception.Http(404),
        AO3Exception.Http(422),
        AO3Exception.RateLimited(),
        AO3Exception.Unauthorized(),
        AO3Exception.Forbidden(),
    ];

    [Theory]
    [MemberData(nameof(NotSent))]
    public void FailuresBeforeThePostDontWarn(Exception e)
    {
        // The comment page's GET failing, or AO3 turning the POST down.
        var message = CommentPostError.Message(e);
        Assert.Equal($"Couldn't post. {e.Message}", message);
        Assert.DoesNotContain(CommentPostError.MayHavePosted, message);
    }

    public static TheoryData<Exception> NotSent() =>
    [
        AO3Exception.Network("The request timed out."),
        AO3Exception.Http(503),
        AO3Exception.RateLimited(),
        AO3Exception.Forbidden(),
        AO3Exception.BlockedByProtection(),
    ];

    [Fact]
    public void AddsOneFullStopWhenTheMessageHasNone()
    {
        Assert.Equal("Couldn't post. Couldn't read AO3's page (comment form not found).",
            CommentPostError.Message(AO3Exception.ParseFailed("comment form not found")));
        Assert.Equal("Couldn't post. Something odd.", CommentPostError.Message(new InvalidOperationException("Something odd")));
    }
}
