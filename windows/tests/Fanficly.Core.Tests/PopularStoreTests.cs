using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class PopularStoreTests
{
    private sealed class SnapshotClient(Func<PopularSnapshot> respond) : IAO3Client
    {
        public int Calls { get; private set; }

        public Task<PopularSnapshot> FetchPopularSnapshotAsync(CancellationToken ct = default)
        {
            Calls++;
            return Task.FromResult(respond());
        }

        private readonly StubAO3Client _stub = new();
        public Task LoginAsync(string username, string password, CancellationToken ct = default) => _stub.LoginAsync(username, password, ct);
        public Task LogoutAsync() => _stub.LogoutAsync();
        public Task<string?> CurrentUsernameAsync() => _stub.CurrentUsernameAsync();
        public Task<AO3SearchResults> SearchAsync(AO3SearchFilters filters, int page, CancellationToken ct = default) => _stub.SearchAsync(filters, page, ct);
        public Task<AO3SearchResults> FetchAuthorWorksAsync(string username, int page, CancellationToken ct = default) => _stub.FetchAuthorWorksAsync(username, page, ct);
        public Task<AO3SearchResults> FetchBookmarksAsync(string username, int page, CancellationToken ct = default) => _stub.FetchBookmarksAsync(username, page, ct);
        public Task<AO3WorkPayload> FetchWorkAsync(int id, CancellationToken ct = default) => _stub.FetchWorkAsync(id, ct);
        public Task<AO3WorkMetadata> FetchWorkMetadataAsync(int id, CancellationToken ct = default) => _stub.FetchWorkMetadataAsync(id, ct);
        public Task<IReadOnlyList<AO3Subscription>> FetchSubscriptionsAsync(string username, CancellationToken ct = default) => _stub.FetchSubscriptionsAsync(username, ct);
        public Task<AO3CommentsPage> FetchCommentsAsync(int workId, int? chapterId, int page, CancellationToken ct = default) => _stub.FetchCommentsAsync(workId, chapterId, page, ct);
        public Task PostCommentAsync(int workId, int? chapterId, string text, CancellationToken ct = default) => _stub.PostCommentAsync(workId, chapterId, text, ct);
        public Task<IReadOnlyList<BrowseFandom>> FetchFandomsInCategoryAsync(string categoryName, CancellationToken ct = default) => _stub.FetchFandomsInCategoryAsync(categoryName, ct);
        public Task<IReadOnlyList<string>> AutocompleteAsync(AO3AutocompleteField field, string term, CancellationToken ct = default) => _stub.AutocompleteAsync(field, term, ct);
        public Task<string> DownloadEpubAsync(int workId, CancellationToken ct = default) => _stub.DownloadEpubAsync(workId, ct);
        public Task<string> ExportWorkAsync(int workId, WorkExportFormat format, string filename, CancellationToken ct = default) => _stub.ExportWorkAsync(workId, format, filename, ct);
        public Task SubscribeToWorkAsync(int workId, CancellationToken ct = default) => _stub.SubscribeToWorkAsync(workId, ct);
        public Task<AO3BookmarkForm> FetchBookmarkFormAsync(int workId, CancellationToken ct = default) => _stub.FetchBookmarkFormAsync(workId, ct);
        public Task SaveBookmarkAsync(AO3BookmarkForm form, CancellationToken ct = default) => _stub.SaveBookmarkAsync(form, ct);
    }

    private static readonly DateTimeOffset Now = new(2026, 10, 16, 12, 0, 0, TimeSpan.Zero);

    private static PopularSnapshot Snapshot(DateTimeOffset at, string fandom = "Live Fandom") =>
        new([fandom], ["A/B"], ["C"], at);

    [Fact]
    public void EncodeDecodeRoundTrips()
    {
        var snapshot = new PopularSnapshot(["방탄소년단 | Bangtan Boys | BTS", "Naruto"], ["James \"Bucky\" Barnes/Steve Rogers"], [], Now);
        var decoded = PopularStore.Decode(PopularStore.Encode(snapshot));
        Assert.NotNull(decoded);
        Assert.Equal(snapshot.Fandoms, decoded!.Fandoms);
        Assert.Equal(snapshot.Ships, decoded.Ships);
        Assert.Empty(decoded.Characters);
        Assert.Equal(Now, decoded.FetchedAt);
    }

    [Fact]
    public void CorruptCacheReadsAsNone()
    {
        var store = new InMemoryKeyValueStore();
        Assert.Null(PopularStore.Cached(store));
        store.SetString(PopularStore.Key, "not json");
        Assert.Null(PopularStore.Cached(store));
        store.SetString(PopularStore.Key, "{\"fandoms\":[]}");
        Assert.Null(PopularStore.Cached(store));
    }

    [Fact]
    public void StalenessIsADay()
    {
        Assert.True(PopularStore.IsStale(null, Now));
        Assert.False(PopularStore.IsStale(Snapshot(Now.AddHours(-23)), Now));
        Assert.True(PopularStore.IsStale(Snapshot(Now.AddHours(-25)), Now));
    }

    [Fact]
    public async Task FreshCacheIsNotRefetched()
    {
        var store = new InMemoryKeyValueStore();
        store.SetString(PopularStore.Key, PopularStore.Encode(Snapshot(Now.AddHours(-1), "Cached")));
        var client = new SnapshotClient(() => Snapshot(Now, "Fetched"));
        var result = await PopularStore.RefreshIfStaleAsync(client, store, Now);
        Assert.Equal(0, client.Calls);
        Assert.Equal("Cached", result!.Fandoms[0]);
    }

    [Fact]
    public async Task StaleCacheIsRefetchedAndStored()
    {
        var store = new InMemoryKeyValueStore();
        store.SetString(PopularStore.Key, PopularStore.Encode(Snapshot(Now.AddDays(-2), "Old")));
        var client = new SnapshotClient(() => Snapshot(Now, "Fetched"));
        var result = await PopularStore.RefreshIfStaleAsync(client, store, Now);
        Assert.Equal(1, client.Calls);
        Assert.Equal("Fetched", result!.Fandoms[0]);
        Assert.Equal("Fetched", PopularStore.Cached(store)!.Fandoms[0]);
    }

    [Fact]
    public async Task FailedFetchKeepsWhatItHad()
    {
        var store = new InMemoryKeyValueStore();
        store.SetString(PopularStore.Key, PopularStore.Encode(Snapshot(Now.AddDays(-2), "Old")));
        var client = new SnapshotClient(() => throw AO3Exception.Network("offline"));
        var result = await PopularStore.RefreshIfStaleAsync(client, store, Now);
        Assert.Equal("Old", result!.Fandoms[0]);

        var empty = new InMemoryKeyValueStore();
        Assert.Null(await PopularStore.RefreshIfStaleAsync(client, empty, Now));
        Assert.Null(PopularStore.Cached(empty));
    }

    [Fact]
    public void EmptyLiveListsFallBackToCuratedSeed()
    {
        Assert.Equal(PopularTags.Fandoms, PopularStore.Names(null, PopularTagKind.Fandom));
        var partial = new PopularSnapshot(["Live"], [], ["Only Character"], Now);
        Assert.Equal(["Live"], PopularStore.Names(partial, PopularTagKind.Fandom));
        Assert.Equal(PopularTags.Ships, PopularStore.Names(partial, PopularTagKind.Ship));
        Assert.Equal(["Only Character"], PopularStore.Names(partial, PopularTagKind.Character));
    }

    [Fact]
    public void ListsAreCappedAtThirty()
    {
        var many = Enumerable.Range(0, 50).Select(i => $"Fandom {i}").ToList();
        var snapshot = new PopularSnapshot(many, [], [], Now);
        Assert.Equal(30, PopularStore.Names(snapshot, PopularTagKind.Fandom).Count);
    }

    [Fact]
    public void PopularTagFiltersSortByKudos()
    {
        var fandom = new PopularTag(PopularTagKind.Fandom, "Naruto").Filters();
        Assert.Equal(["Naruto"], fandom.FandomNames);
        Assert.Equal(SortColumn.KudosCount, fandom.SortColumn);
        Assert.Equal(SortDirection.Desc, fandom.SortDirection);

        var ship = new PopularTag(PopularTagKind.Ship, "Castiel/Dean Winchester").Filters();
        Assert.Equal(["Castiel/Dean Winchester"], ship.RelationshipNames);
        Assert.Empty(ship.FandomNames);

        var character = new PopularTag(PopularTagKind.Character, "Loki (Marvel)").Filters();
        Assert.Equal(["Loki (Marvel)"], character.CharacterNames);
    }

    [Fact]
    public void DisplayNamesTrimOnlyFandoms()
    {
        Assert.Equal("Harry Potter", new PopularTag(PopularTagKind.Fandom, "Harry Potter - J. K. Rowling").DisplayName);
        Assert.Equal("Castiel (Supernatural)", new PopularTag(PopularTagKind.Character, "Castiel (Supernatural)").DisplayName);
        Assert.Equal("A - B/C", new PopularTag(PopularTagKind.Ship, "A - B/C").DisplayName);
    }

    [Fact]
    public void RowSymbols()
    {
        Assert.Equal("gamecontroller", new PopularTag(PopularTagKind.Fandom, "Genshin Impact (Video Game)").Symbol);
        Assert.Equal("heart", new PopularTag(PopularTagKind.Ship, "A/B").Symbol);
        Assert.Equal("person", new PopularTag(PopularTagKind.Character, "C").Symbol);
    }
}
