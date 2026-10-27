using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>A scriptable <see cref="IAO3Client"/> for the poller, sync and
/// re-download tests. Anything not scripted throws.</summary>
internal sealed class PollerFakeClient : IAO3Client
{
    public IReadOnlyList<AO3Subscription> SubscriptionsResponse { get; set; } = [];
    public Exception? SubscriptionsError { get; set; }
    /// <summary>False scripts a list that ran past the client's page ceiling.</summary>
    public bool SubscriptionsComplete { get; set; } = true;
    public int SubscriptionsFetchCount { get; private set; }
    /// <summary>Chapter counts by work id; a missing id fails the fetch.</summary>
    public Dictionary<int, int> ChapterCounts { get; } = new();
    /// <summary>Works pages by author username; a missing author fails the fetch.</summary>
    public Dictionary<string, IReadOnlyList<AO3WorkSummary>> AuthorWorks { get; } = new();
    /// <summary>Full works by id for <see cref="FetchWorkAsync"/>; a missing id fails the fetch.</summary>
    public Dictionary<int, AO3WorkPayload> Works { get; } = new();
    /// <summary>Authors whose works page comes back rendered for a guest.</summary>
    public HashSet<string> GuestAuthorPages { get; } = [];
    /// <summary>Work ids whose EPUB download fails.</summary>
    public HashSet<int> FailingDownloads { get; } = [];
    /// <summary>Every metadata/author/fetch/download request, in order ("work:1", "author:x", "fetch:2", "epub:3").</summary>
    public List<string> Requests { get; } = [];
    /// <summary>Called after each request is logged (tests use it to cancel mid-run).</summary>
    public Action<string>? OnRequest { get; set; }

    private void Log(string request)
    {
        lock (Requests) Requests.Add(request);
        OnRequest?.Invoke(request);
    }

    public Task<AO3SubscriptionList> FetchSubscriptionsAsync(string username, CancellationToken ct = default)
    {
        SubscriptionsFetchCount++;
        return SubscriptionsError is { } e
            ? Task.FromException<AO3SubscriptionList>(e)
            : Task.FromResult(new AO3SubscriptionList(SubscriptionsResponse, SubscriptionsComplete));
    }

    public Task<AO3WorkMetadata> FetchWorkMetadataAsync(int id, CancellationToken ct = default)
    {
        Log($"work:{id}");
        return ChapterCounts.TryGetValue(id, out var count)
            ? Task.FromResult(new AO3WorkMetadata(id, count, null, null))
            : Task.FromException<AO3WorkMetadata>(AO3Exception.Http(404));
    }

    public Task<AO3SearchResults> FetchAuthorWorksAsync(string username, int page, CancellationToken ct = default)
    {
        Log($"author:{username}");
        return AuthorWorks.TryGetValue(username, out var works)
            ? Task.FromResult(new AO3SearchResults(works, 1, 1, ServedAsGuest: GuestAuthorPages.Contains(username)))
            : Task.FromException<AO3SearchResults>(AO3Exception.Http(404));
    }

    public async Task<string> DownloadEpubAsync(int workId, CancellationToken ct = default)
    {
        Log($"epub:{workId}");
        await Task.Yield();
        ct.ThrowIfCancellationRequested();
        if (FailingDownloads.Contains(workId)) throw AO3Exception.Http(404);
        return $"/library/{workId}.epub";
    }

    public Task<string> LoginAsync(string username, string password, CancellationToken ct = default) => throw new NotSupportedException();
    public Task LogoutAsync() => throw new NotSupportedException();
    public Task<string?> CurrentUsernameAsync(CancellationToken ct = default) => Task.FromResult<string?>(null);
    public Task<AO3SearchResults> SearchAsync(AO3SearchFilters filters, int page, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<AO3SearchResults> FetchBookmarksAsync(string username, int page, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<AO3WorkPayload> FetchWorkAsync(int id, CancellationToken ct = default)
    {
        Log($"fetch:{id}");
        return Works.TryGetValue(id, out var payload)
            ? Task.FromResult(payload)
            : Task.FromException<AO3WorkPayload>(AO3Exception.Http(404));
    }
    public Task<AO3CommentsPage> FetchCommentsAsync(int workId, int? chapterId, int page, CancellationToken ct = default) => throw new NotSupportedException();
    public Task PostCommentAsync(int workId, int? chapterId, string text, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<BrowseFandom>> FetchFandomsInCategoryAsync(string categoryName, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<PopularSnapshot> FetchPopularSnapshotAsync(CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<string>> AutocompleteAsync(AO3AutocompleteField field, string term, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<string> ExportWorkAsync(int workId, WorkExportFormat format, string filename, CancellationToken ct = default) => throw new NotSupportedException();
    public Task SubscribeToWorkAsync(int workId, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<KudosOutcome> LeaveKudosAsync(int workId, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<AO3BookmarkForm> FetchBookmarkFormAsync(int workId, CancellationToken ct = default) => throw new NotSupportedException();
    public Task SaveBookmarkAsync(AO3BookmarkForm form, CancellationToken ct = default) => throw new NotSupportedException();
}

/// <summary>Collects posted notifications.</summary>
internal sealed class RecordingNotifier : ILocalNotifier
{
    public List<LocalNotification> Posted { get; } = [];

    public Task PostAsync(LocalNotification notification)
    {
        lock (Posted) Posted.Add(notification);
        return Task.CompletedTask;
    }
}
