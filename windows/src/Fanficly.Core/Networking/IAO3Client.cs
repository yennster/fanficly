namespace Fanficly.Core;

/// <summary>The only seam to the network. The app talks to AO3 through this;
/// <see cref="AO3Client"/> is the live implementation, <c>DemoAO3Client</c> serves
/// the offline demo catalogue, and tests use stubs.</summary>
public interface IAO3Client
{
    /// <summary>Signs in with an AO3 username or email address and returns the
    /// account's AO3 login name, which is what <c>/users/&lt;name&gt;</c> pages need (#144).</summary>
    Task<string> LoginAsync(string username, string password, CancellationToken ct = default);
    Task LogoutAsync();
    /// <summary>The signed-in AO3 login name, read from AO3's page header when this
    /// run hasn't signed in yet; null when signed out or unreachable.</summary>
    Task<string?> CurrentUsernameAsync(CancellationToken ct = default);
    Task<AO3SearchResults> SearchAsync(AO3SearchFilters filters, int page, CancellationToken ct = default);
    Task<AO3SearchResults> FetchAuthorWorksAsync(string username, int page, CancellationToken ct = default);
    Task<AO3SearchResults> FetchBookmarksAsync(string username, int page, CancellationToken ct = default);
    /// <summary>One page of the user's AO3 Marked for Later list. Needs login.
    /// The default throws, so a client that doesn't forward it can't show an
    /// empty list; test fakes that never open the tab need nothing.</summary>
    Task<AO3SearchResults> FetchMarkedForLaterAsync(string username, int page, CancellationToken ct = default) =>
        throw new NotSupportedException(nameof(FetchMarkedForLaterAsync));
    /// <summary>One page of the user's AO3 reading history, most recently visited
    /// first. Needs login and History turned on in AO3's preferences. The default
    /// throws, as <see cref="FetchMarkedForLaterAsync"/> does.</summary>
    Task<AO3SearchResults> FetchReadingHistoryAsync(string username, int page, CancellationToken ct = default) =>
        throw new NotSupportedException(nameof(FetchReadingHistoryAsync));
    Task<AO3WorkPayload> FetchWorkAsync(int id, CancellationToken ct = default);
    /// <summary>One chapter of a work, as AO3 pages it by default: chapter
    /// <paramref name="chapter"/> (one-based) when it exists, else the first.
    /// Clients with nothing lighter return the whole work.</summary>
    async Task<AO3WorkChapterPage> FetchWorkChapterAsync(int id, int chapter = 1, CancellationToken ct = default) =>
        new(await FetchWorkAsync(id, ct).ConfigureAwait(false), [], IsWholeWork: true);
    Task<AO3WorkMetadata> FetchWorkMetadataAsync(int id, CancellationToken ct = default);
    Task<AO3SubscriptionList> FetchSubscriptionsAsync(string username, CancellationToken ct = default);
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
    /// <summary>Leaves kudos on a work as the signed-in user: one POST, never
    /// retried. Throws Unauthorized when the session isn't signed in, so a stale
    /// cookie can't quietly leave a guest kudo instead. Clients with no AO3 to
    /// talk to (test fakes) don't support it.</summary>
    Task<KudosOutcome> LeaveKudosAsync(int workId, CancellationToken ct = default) =>
        throw new NotSupportedException("This client can't leave kudos.");
    /// <summary>The signed-in user's bookmark form for a work, prefilled when they
    /// already bookmarked it. Throws <c>Unauthorized</c> when signed out.</summary>
    Task<AO3BookmarkForm> FetchBookmarkFormAsync(int workId, CancellationToken ct = default);
    /// <summary>Creates or updates the bookmark by posting <paramref name="form"/> back to AO3.</summary>
    Task SaveBookmarkAsync(AO3BookmarkForm form, CancellationToken ct = default);
}
