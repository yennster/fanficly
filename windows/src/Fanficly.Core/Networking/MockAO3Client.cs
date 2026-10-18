namespace Fanficly.Core;

/// <summary>A do-nothing client for previews: empty listings, a placeholder work,
/// and the curated popular lists. Never touches the network.</summary>
public sealed class MockAO3Client : IAO3Client
{
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
        Task.FromResult(new AO3WorkPayload(
            new AO3WorkSummary
            {
                Id = id,
                Title = "Sample Work",
                Author = "Anon",
                Summary = "",
                Rating = "Not Rated",
                WordCount = 0,
                ChapterCount = 1,
                TotalChapters = 1,
                Language = "en",
                Kudos = 0,
                Hits = 0,
                IsComplete = true,
                UpdatedAt = null,
            },
            []));

    public Task<AO3WorkMetadata> FetchWorkMetadataAsync(int id, CancellationToken ct = default) =>
        Task.FromResult(new AO3WorkMetadata(id, 1, 1, null));

    public Task<IReadOnlyList<AO3Subscription>> FetchSubscriptionsAsync(string username, CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<AO3Subscription>>([]);

    public Task<IReadOnlyList<AO3Comment>> FetchCommentsAsync(int workId, int? chapterId, CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<AO3Comment>>([]);

    public Task PostCommentAsync(int workId, int? chapterId, string text, CancellationToken ct = default) => Task.CompletedTask;

    public Task<IReadOnlyList<BrowseFandom>> FetchFandomsInCategoryAsync(string categoryName, CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<BrowseFandom>>([]);

    public Task<PopularSnapshot> FetchPopularSnapshotAsync(CancellationToken ct = default) =>
        Task.FromResult(new PopularSnapshot(PopularTags.Fandoms, PopularTags.Ships, PopularTags.Characters, DateTimeOffset.Now));

    public Task<IReadOnlyList<string>> AutocompleteAsync(AO3AutocompleteField field, string term, CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<string>>([term]);

    public Task<string> DownloadEpubAsync(int workId, CancellationToken ct = default) =>
        Task.FromResult(Path.Combine(Path.GetTempPath(), $"{workId}.epub"));

    public Task<string> ExportWorkAsync(int workId, WorkExportFormat format, string filename, CancellationToken ct = default) =>
        Task.FromResult(Path.Combine(Path.GetTempPath(), $"{filename}.{format.Ext()}"));

    public Task SubscribeToWorkAsync(int workId, CancellationToken ct = default) => Task.CompletedTask;
}
