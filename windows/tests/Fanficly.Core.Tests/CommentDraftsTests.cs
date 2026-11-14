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
    public void ATimeoutSaysItMayHaveBeenPosted()
    {
        var message = CommentPostError.Message(new TimeoutException("The request timed out."));
        Assert.Equal("Couldn't post. The request timed out. " + CommentPostError.MayHavePosted, message);
        Assert.DoesNotContain("..", message);
    }

    [Theory]
    [MemberData(nameof(MaybeSent))]
    public void FailuresAfterSendingWarnAgainstADoublePost(Exception e)
    {
        var message = CommentPostError.Message(e);
        Assert.StartsWith("Couldn't post. ", message);
        Assert.EndsWith(CommentPostError.MayHavePosted, message);
        Assert.DoesNotContain("..", message);
        Assert.DoesNotContain("moderation", message);
    }

    public static TheoryData<Exception> MaybeSent() =>
    [
        AO3Exception.Network("connection reset"),
        AO3Exception.Http(503),
        AO3Exception.Http(500),
        new HttpRequestException("An error occurred while sending the request."),
        new IOException("The response ended prematurely"),
    ];

    [Theory]
    [MemberData(nameof(NotSent))]
    public void FailuresBeforeAO3TakesItDontWarn(Exception e)
    {
        var message = CommentPostError.Message(e);
        Assert.Equal($"Couldn't post. {e.Message}", message);
        Assert.DoesNotContain(CommentPostError.MayHavePosted, message);
    }

    public static TheoryData<Exception> NotSent() =>
    [
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
