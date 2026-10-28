namespace Fanficly.Core;

/// <summary>The thread library records are read and changed on: the UI
/// thread, whose screens enumerate them. Records aren't locked (see
/// <see cref="LibraryStore"/>), so code that runs elsewhere (a backup, a
/// restore, the subscription poller) hops here to touch them and does its
/// network and file work off it (#139).</summary>
public sealed class RecordsThread
{
    private readonly SynchronizationContext _context;
    private readonly int _threadId;

    /// <summary>Create it on the thread <paramref name="context"/> runs on.</summary>
    public RecordsThread(SynchronizationContext context)
    {
        _context = context;
        _threadId = Environment.CurrentManagedThreadId;
    }

    /// <summary>The app's UI thread, set at launch. Null in the background
    /// task's process and in tests, where records stay on the calling thread.</summary>
    public static RecordsThread? Main { get; set; }

    /// <summary>Whether this is that thread.</summary>
    public bool IsCurrent => SynchronizationContext.Current == _context || Environment.CurrentManagedThreadId == _threadId;

    /// <summary>Runs <paramref name="body"/> on <paramref name="thread"/>:
    /// inline when that's this thread (posting and waiting would deadlock)
    /// or there's none.</summary>
    public static Task<T> RunAsync<T>(RecordsThread? thread, Func<T> body)
    {
        if (thread is null || thread.IsCurrent)
        {
            try { return Task.FromResult(body()); }
            catch (Exception e) { return Task.FromException<T>(e); }
        }
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        thread._context.Post(_ =>
        {
            try { done.SetResult(body()); }
            catch (Exception e) { done.SetException(e); }
        }, null);
        return done.Task;
    }

    /// <inheritdoc cref="RunAsync{T}(RecordsThread?, Func{T})"/>
    public static Task RunAsync(RecordsThread? thread, Action body) => RunAsync(thread, () =>
    {
        body();
        return true;
    });
}
