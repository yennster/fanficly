using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Test double whose autocomplete responses are scripted, so resolution
/// logic (e.g. the relationship character-fallback) can be exercised.</summary>
public sealed class StubAO3Client : IAO3Client
{
    /// <summary>term (lowercased) → matches.</summary>
    public Dictionary<string, IReadOnlyList<string>> AutocompleteResponses { get; set; } = new();
    /// <summary>Terms (lowercased) whose lookup throws, to script network failures.</summary>
    public HashSet<string> AutocompleteFailingTerms { get; set; } = [];
    /// <summary>Answer every autocomplete with the term itself (the Swift
    /// <c>MockAO3Client</c>'s behaviour) instead of the scripted responses.</summary>
    public bool AutocompleteEchoesTerm { get; set; }
    private readonly List<string> _autocompleteCalls = [];
    public IReadOnlyList<string> AutocompleteCalls => _autocompleteCalls;
    /// <summary>Scripted subscriptions-list response (SubscriptionPoller tests).</summary>
    public IReadOnlyList<AO3Subscription> SubscriptionsResponse { get; set; } = [];
    /// <summary>Scripted export failure (WorkExporter tests).</summary>
    public Exception? ExportError { get; set; }
    /// <summary>Scripted kudos answer: an outcome, or an exception to throw (KudosGiver tests).</summary>
    public KudosOutcome KudosOutcome { get; set; } = KudosOutcome.Left;
    public Exception? KudosError { get; set; }
    private readonly List<int> _kudosCalls = [];
    public IReadOnlyList<int> KudosCalls => _kudosCalls;

    public Task<IReadOnlyList<string>> AutocompleteAsync(AO3AutocompleteField field, string term, CancellationToken ct = default)
    {
        _autocompleteCalls.Add(term);
        if (AutocompleteFailingTerms.Contains(term.ToLowerInvariant()))
            throw AO3Exception.Network("The Internet connection appears to be offline.");
        if (AutocompleteEchoesTerm) return Task.FromResult<IReadOnlyList<string>>([term]);
        return Task.FromResult(AutocompleteResponses.TryGetValue(term.ToLowerInvariant(), out var r) ? r : []);
    }

    // Unused protocol stubs.
    public Task LoginAsync(string username, string password, CancellationToken ct = default) => Task.CompletedTask;
    public Task LogoutAsync() => Task.CompletedTask;
    public Task<string?> CurrentUsernameAsync() => Task.FromResult<string?>(null);
    public Task<AO3SearchResults> SearchAsync(AO3SearchFilters filters, int page, CancellationToken ct = default) =>
        Task.FromResult(new AO3SearchResults([], 0, page));
    public Task<AO3SearchResults> FetchAuthorWorksAsync(string username, int page, CancellationToken ct = default) =>
        Task.FromResult(new AO3SearchResults([], 0, page));
    public Task<AO3SearchResults> FetchBookmarksAsync(string username, int page, CancellationToken ct = default) =>
        Task.FromResult(new AO3SearchResults([], 0, page));
    public Task<AO3WorkPayload> FetchWorkAsync(int id, CancellationToken ct = default) =>
        Task.FromResult(new AO3WorkPayload(new AO3WorkSummary { Id = id, Title = "x" }, []));
    public Task<AO3WorkMetadata> FetchWorkMetadataAsync(int id, CancellationToken ct = default) =>
        Task.FromResult(new AO3WorkMetadata(id, 1, 1, null));
    public Task<IReadOnlyList<AO3Subscription>> FetchSubscriptionsAsync(string username, CancellationToken ct = default) =>
        Task.FromResult(SubscriptionsResponse);
    public Task<AO3CommentsPage> FetchCommentsAsync(int workId, int? chapterId, int page, CancellationToken ct = default) =>
        Task.FromResult(new AO3CommentsPage([], page));
    public Task PostCommentAsync(int workId, int? chapterId, string text, CancellationToken ct = default) => Task.CompletedTask;
    public Task<IReadOnlyList<BrowseFandom>> FetchFandomsInCategoryAsync(string categoryName, CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<BrowseFandom>>([]);
    public Task<PopularSnapshot> FetchPopularSnapshotAsync(CancellationToken ct = default) =>
        Task.FromResult(new PopularSnapshot([], [], [], DateTimeOffset.Now));
    public Task<string> DownloadEpubAsync(int workId, CancellationToken ct = default) =>
        Task.FromResult(Path.Combine(Path.GetTempPath(), $"{workId}.epub"));
    public Task<string> ExportWorkAsync(int workId, WorkExportFormat format, string filename, CancellationToken ct = default)
    {
        if (ExportError is not null) throw ExportError;
        return Task.FromResult(Path.Combine(Path.GetTempPath(), $"{filename}.{format.Ext()}"));
    }
    public Task SubscribeToWorkAsync(int workId, CancellationToken ct = default) => Task.CompletedTask;
    public Task<KudosOutcome> LeaveKudosAsync(int workId, CancellationToken ct = default)
    {
        _kudosCalls.Add(workId);
        if (KudosError is not null) throw KudosError;
        return Task.FromResult(KudosOutcome);
    }
}
