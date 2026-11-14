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

    /// <summary>Forgets the draft once <paramref name="posted"/> went up, unless the
    /// stored text has changed since (a newer comment typed meanwhile).</summary>
    public void ClearIfPosted(int workId, int? chapterId, string posted)
    {
        lock (_lock)
        {
            if (_drafts.TryGetValue((workId, chapterId), out var text) && text.Trim() == posted.Trim())
                _drafts.Remove((workId, chapterId));
        }
    }

    private readonly Dictionary<(int WorkId, int? ChapterId), string> _notices = [];

    /// <summary>Keeps a post's failure for the next time the thread opens, when the
    /// screen that posted it has already gone (Windows only: the Apple sheet can't
    /// close mid-post).</summary>
    public void SetNotice(int workId, int? chapterId, string? notice)
    {
        lock (_lock)
        {
            if (notice is null) _notices.Remove((workId, chapterId));
            else _notices[(workId, chapterId)] = notice;
        }
    }

    /// <summary>The kept failure, once: reading it forgets it.</summary>
    public string? TakeNotice(int workId, int? chapterId)
    {
        lock (_lock) return _notices.Remove((workId, chapterId), out var notice) ? notice : null;
    }
}

/// <summary>A comment POST that failed after it went out, so AO3 may have saved
/// the comment anyway (Swift's <c>CommentPostUncertain</c>). Thrown only by
/// <c>PostCommentAsync</c>'s POST step: the same failure on the comment page's GET
/// before it is an ordinary error, since nothing was sent (#204).</summary>
public sealed class CommentPostUncertainException(Exception inner) : Exception(inner.Message, inner)
{
    /// <summary>A timeout, a dropped connection or a server error. Not a failure to
    /// reach AO3 at all (offline, DNS, refused), which happens before anything is sent.</summary>
    public static bool MayHaveReachedAO3(Exception e) => e switch
    {
        AO3Exception { Kind: AO3ErrorKind.Network } => !NeverConnected(e.InnerException),
        AO3Exception { Kind: AO3ErrorKind.Http, Status: >= 500 } => true,
        AO3Exception => false,
        TimeoutException or HttpRequestException or IOException => !NeverConnected(e),
        _ => false,
    };

    private static bool NeverConnected(Exception? e)
    {
        for (var x = e; x is not null; x = x.InnerException)
        {
            if (x is HttpRequestException { HttpRequestError: HttpRequestError.NameResolutionError }) return true;
            if (x is System.Net.Sockets.SocketException { SocketErrorCode: System.Net.Sockets.SocketError.HostNotFound
                    or System.Net.Sockets.SocketError.TryAgain or System.Net.Sockets.SocketError.NetworkDown
                    or System.Net.Sockets.SocketError.NetworkUnreachable or System.Net.Sockets.SocketError.HostUnreachable
                    or System.Net.Sockets.SocketError.ConnectionRefused }) return true;
        }
        return false;
    }
}

/// <summary>The sentence the comment composer shows when posting fails, worded by
/// what went wrong (Swift's <c>CommentPostError</c>). An expired sign-in is the
/// screen's own message, since each app says where to sign in.</summary>
public static class CommentPostError
{
    /// <summary>After a failure that can come once AO3 already has the comment, so
    /// posting again straight away could post it twice.</summary>
    public const string MayHavePosted = "It may have been posted anyway, so refresh the comments before trying again.";

    public static string Message(Exception e)
    {
        // AO3's own reason ("Couldn't save comment! …") or "AO3 didn't confirm…",
        // already a full sentence that says what to do.
        if (e is AO3Exception { Kind: AO3ErrorKind.Rejected } rejected)
            return Sentence(rejected.Reason is { Length: > 0 } reason ? reason : rejected.Message);
        return e is CommentPostUncertainException
            ? $"Couldn't post. {Sentence(e.Message)} {MayHavePosted}"
            : $"Couldn't post. {Sentence(e.Message)}";
    }

    /// <summary>Ends the text with one full stop, so "error." never reads "error..".</summary>
    internal static string Sentence(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return "Something went wrong.";
        return trimmed[^1] is '.' or '!' or '?' ? trimmed : trimmed + ".";
    }
}
