namespace Fanficly.Core;

/// <summary>The only seam to the network. The app talks to AO3 through this;
/// <see cref="AO3Client"/> is the live implementation, <c>DemoAO3Client</c> serves
/// the offline demo catalogue, and tests use stubs.</summary>
public interface IAO3Client
{
    Task LoginAsync(string username, string password, CancellationToken ct = default);
    Task LogoutAsync();
    Task<string?> CurrentUsernameAsync();
    Task<AO3SearchResults> SearchAsync(AO3SearchFilters filters, int page, CancellationToken ct = default);
    Task<AO3SearchResults> FetchAuthorWorksAsync(string username, int page, CancellationToken ct = default);
    Task<AO3SearchResults> FetchBookmarksAsync(string username, int page, CancellationToken ct = default);
    Task<AO3WorkPayload> FetchWorkAsync(int id, CancellationToken ct = default);
    /// <summary>One chapter of a work, as AO3 pages it by default: chapter
    /// <paramref name="chapter"/> (one-based) when it exists, else the first.
    /// Clients with nothing lighter return the whole work.</summary>
    async Task<AO3WorkChapterPage> FetchWorkChapterAsync(int id, int chapter = 1, CancellationToken ct = default) =>
        new(await FetchWorkAsync(id, ct).ConfigureAwait(false), [], IsWholeWork: true);
    Task<AO3WorkMetadata> FetchWorkMetadataAsync(int id, CancellationToken ct = default);
    Task<IReadOnlyList<AO3Subscription>> FetchSubscriptionsAsync(string username, CancellationToken ct = default);
    /// <summary>Comments for a specific chapter (AO3 threads comments per chapter).
    /// <paramref name="chapterId"/> null fetches the work-level page (the first
    /// chapter's thread), the fallback when the id is unknown. <paramref name="page"/>
    /// is the 1-based comment page.</summary>
    Task<AO3CommentsPage> FetchCommentsAsync(int workId, int? chapterId, int page, CancellationToken ct = default);
    Task PostCommentAsync(int workId, int? chapterId, string text, CancellationToken ct = default);
    Task<IReadOnlyList<BrowseFandom>> FetchFandomsInCategoryAsync(string categoryName, CancellationToken ct = default);
    Task<PopularSnapshot> FetchPopularSnapshotAsync(CancellationToken ct = default);
    Task<IReadOnlyList<string>> AutocompleteAsync(AO3AutocompleteField field, string term, CancellationToken ct = default);
    /// <summary>Downloads the work's EPUB into the library folder; returns its path.</summary>
    Task<string> DownloadEpubAsync(int workId, CancellationToken ct = default);
    /// <summary>Downloads an export to a temp file; returns its path.</summary>
    Task<string> ExportWorkAsync(int workId, WorkExportFormat format, string filename, CancellationToken ct = default);
    Task SubscribeToWorkAsync(int workId, CancellationToken ct = default);
}
