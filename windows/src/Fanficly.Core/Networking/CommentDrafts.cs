namespace Fanficly.Core;

/// <summary>Unposted comment text, per work and chapter, for as long as the app runs
/// (Swift's <c>CommentDrafts</c>). Back, the mouse back button and controller B close
/// the comments screen without asking, so the text lives here rather than only in
/// the composer: reopening the same chapter's comments brings it back (#204). Kept
/// in memory only, never written to disk, and cleared once the comment posts.</summary>
public sealed class CommentDrafts
{
    public static CommentDrafts Shared { get; } = new();

    private readonly Dictionary<(int WorkId, int? ChapterId), string> _drafts = [];
    private readonly Lock _lock = new();

    /// <summary>The draft for a thread, or "" when there is none.</summary>
    public string Get(int workId, int? chapterId)
    {
        lock (_lock) return _drafts.TryGetValue((workId, chapterId), out var text) ? text : "";
    }

    /// <summary>Stores the composer's text; blank text forgets the draft.</summary>
    public void Set(int workId, int? chapterId, string text)
    {
        lock (_lock)
        {
            if (string.IsNullOrWhiteSpace(text)) _drafts.Remove((workId, chapterId));
            else _drafts[(workId, chapterId)] = text;
        }
    }

    public void Clear(int workId, int? chapterId) => Set(workId, chapterId, "");
}

/// <summary>The sentence the comment composer shows when posting fails, worded by
/// what went wrong (Swift's <c>CommentPostError</c>, same words). An expired
/// sign-in is the screen's own message, since each app says where to sign in.</summary>
public static class CommentPostError
{
    /// <summary>After a failure that can come once AO3 already has the comment, so
    /// posting again straight away could post it twice.</summary>
    public const string MayHavePosted = "It may have been posted anyway, so refresh the comments before trying again.";

    /// <summary>Failures where the POST may have reached AO3: a timeout, a dropped
    /// connection or an HTTP error. A rate limit, a block or a missing comment form
    /// all stop the comment before AO3 takes it.</summary>
    public static bool MayHaveBeenSent(Exception e) => e switch
    {
        AO3Exception { Kind: AO3ErrorKind.Network or AO3ErrorKind.Http } => true,
        AO3Exception => false,
        TimeoutException or HttpRequestException or IOException => true,
        _ => false,
    };

    public static string Message(Exception e)
    {
        // AO3's own reason ("Couldn't save comment! …") or "AO3 didn't confirm…",
        // already a full sentence that says what to do.
        if (e is AO3Exception { Kind: AO3ErrorKind.Rejected } rejected)
            return Sentence(rejected.Reason is { Length: > 0 } reason ? reason : rejected.Message);
        var message = $"Couldn't post. {Sentence(e.Message)}";
        return MayHaveBeenSent(e) ? $"{message} {MayHavePosted}" : message;
    }

    /// <summary>Ends the text with one full stop, so "error." never reads "error..".</summary>
    internal static string Sentence(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return "Something went wrong.";
        return trimmed[^1] is '.' or '!' or '?' ? trimmed : trimmed + ".";
    }
}
