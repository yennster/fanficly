using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class AuthStateTests
{
    /// <summary>A scriptable login: throws <see cref="LoginError"/> when set.</summary>
    private sealed class ClientTestDouble : IAO3Client
    {
        public Exception? LoginError { get; set; }
        public int Logouts { get; private set; }

        public Task LoginAsync(string username, string password, CancellationToken ct = default) =>
            LoginError is { } e ? Task.FromException(e) : Task.CompletedTask;
        public Task LogoutAsync() { Logouts++; return Task.CompletedTask; }

        private readonly MockAO3Client _rest = new();
        public Task<string?> CurrentUsernameAsync() => _rest.CurrentUsernameAsync();
        public Task<AO3SearchResults> SearchAsync(AO3SearchFilters filters, int page, CancellationToken ct = default) => _rest.SearchAsync(filters, page, ct);
        public Task<AO3SearchResults> FetchAuthorWorksAsync(string username, int page, CancellationToken ct = default) => _rest.FetchAuthorWorksAsync(username, page, ct);
        public Task<AO3SearchResults> FetchBookmarksAsync(string username, int page, CancellationToken ct = default) => _rest.FetchBookmarksAsync(username, page, ct);
        public Task<AO3WorkPayload> FetchWorkAsync(int id, CancellationToken ct = default) => _rest.FetchWorkAsync(id, ct);
        public Task<AO3WorkMetadata> FetchWorkMetadataAsync(int id, CancellationToken ct = default) => _rest.FetchWorkMetadataAsync(id, ct);
        public Task<IReadOnlyList<AO3Subscription>> FetchSubscriptionsAsync(string username, CancellationToken ct = default) => _rest.FetchSubscriptionsAsync(username, ct);
        public Task<AO3CommentsPage> FetchCommentsAsync(int workId, int? chapterId, int page, CancellationToken ct = default) => _rest.FetchCommentsAsync(workId, chapterId, page, ct);
        public Task PostCommentAsync(int workId, int? chapterId, string text, CancellationToken ct = default) => _rest.PostCommentAsync(workId, chapterId, text, ct);
        public Task<IReadOnlyList<BrowseFandom>> FetchFandomsInCategoryAsync(string categoryName, CancellationToken ct = default) => _rest.FetchFandomsInCategoryAsync(categoryName, ct);
        public Task<PopularSnapshot> FetchPopularSnapshotAsync(CancellationToken ct = default) => _rest.FetchPopularSnapshotAsync(ct);
        public Task<IReadOnlyList<string>> AutocompleteAsync(AO3AutocompleteField field, string term, CancellationToken ct = default) => _rest.AutocompleteAsync(field, term, ct);
        public Task<string> DownloadEpubAsync(int workId, CancellationToken ct = default) => _rest.DownloadEpubAsync(workId, ct);
        public Task<string> ExportWorkAsync(int workId, WorkExportFormat format, string filename, CancellationToken ct = default) => _rest.ExportWorkAsync(workId, format, filename, ct);
        public Task SubscribeToWorkAsync(int workId, CancellationToken ct = default) => _rest.SubscribeToWorkAsync(workId, ct);
        public Task<AO3BookmarkForm> FetchBookmarkFormAsync(int workId, CancellationToken ct = default) => _rest.FetchBookmarkFormAsync(workId, ct);
        public Task SaveBookmarkAsync(AO3BookmarkForm form, CancellationToken ct = default) => _rest.SaveBookmarkAsync(form, ct);
    }

    [Fact]
    public void StartsFromTheStoredUsername()
    {
        var vault = new InMemoryCookieVault();
        Assert.False(new AuthState(vault).IsLoggedIn);
        vault.SetUsername("reader");
        var auth = new AuthState(vault);
        Assert.Equal("reader", auth.Username);
        Assert.True(auth.IsLoggedIn);
    }

    [Fact]
    public async Task SuccessfulLoginStoresTheUsernameAndNotifies()
    {
        var vault = new InMemoryCookieVault();
        var auth = new AuthState(vault);
        var changed = new List<string?>();
        auth.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        await auth.LoginAsync(new ClientTestDouble(), "reader", "pw");

        Assert.Equal("reader", auth.Username);
        Assert.Equal("reader", vault.StoredUsername());
        Assert.False(auth.IsAuthenticating);
        Assert.Null(auth.LastError);
        Assert.Contains(nameof(AuthState.Username), changed);
        Assert.Contains(nameof(AuthState.IsLoggedIn), changed);
        Assert.Contains(nameof(AuthState.IsAuthenticating), changed);
    }

    [Theory]
    [InlineData(AO3ErrorKind.LoginFailed, "Incorrect username or password.", "Incorrect username or password.")]
    [InlineData(AO3ErrorKind.Network, "offline", "Network: offline")]
    public async Task FailedLoginReportsTheReason(AO3ErrorKind kind, string reason, string expected)
    {
        var auth = new AuthState(new InMemoryCookieVault());
        await auth.LoginAsync(new ClientTestDouble { LoginError = new AO3Exception(kind, reason) }, "reader", "pw");
        Assert.Equal(expected, auth.LastError);
        Assert.Null(auth.Username);
        Assert.False(auth.IsAuthenticating);
    }

    [Fact]
    public async Task OtherErrorsReportTheirMessage()
    {
        var auth = new AuthState(new InMemoryCookieVault());
        await auth.LoginAsync(new ClientTestDouble { LoginError = AO3Exception.RateLimited() }, "reader", "pw");
        Assert.Equal("AO3 is rate-limiting requests. Try again in a minute.", auth.LastError);
    }

    [Fact]
    public async Task LogoutClearsTheUsernameAndCookies()
    {
        var vault = new InMemoryCookieVault();
        vault.SetUsername("reader");
        vault.SaveCookies([new SerializableCookie("s", "v", "archiveofourown.org", "/", null, true, true)]);
        var auth = new AuthState(vault);
        var client = new ClientTestDouble();

        await auth.LogoutAsync(client);

        Assert.Equal(1, client.Logouts);
        Assert.Null(auth.Username);
        Assert.Null(vault.StoredUsername());
        Assert.Empty(vault.LoadCookies());
    }

    [Fact]
    public void CookiesRoundTripThroughJson()
    {
        var expires = new DateTimeOffset(2030, 1, 2, 3, 4, 5, TimeSpan.Zero);
        SerializableCookie[] cookies =
        [
            new("_otwarchive_session", "a=b", ".archiveofourown.org", "/", null, true, true),
            new("remember_user_token", "xyz", "archiveofourown.org", "/", expires, false, false),
        ];
        var back = SerializableCookie.ListFromJson(SerializableCookie.ToJson(cookies));
        Assert.Equal(cookies, back);
        Assert.Empty(SerializableCookie.ListFromJson("not json"));
        Assert.Empty(SerializableCookie.ListFromJson(null));
    }
}
