using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Exercises the live client's transport against a scripted handler:
/// status mapping, which failures retry (and how long they wait), cookies,
/// redirects and the CSRF flows. The Swift app had no tests here; this is the
/// riskiest seam of the port.</summary>
public sealed class AO3ClientTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "fanficly-client-tests-" + Guid.NewGuid().ToString("N"));
    private readonly FakeHandler _handler = new();
    private readonly InMemoryCookieVault _vault = new();
    private readonly List<TimeSpan> _sleeps = [];
    private bool _online = true;

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (DirectoryNotFoundException) { }
    }

    private AO3Client MakeClient(Throttle? throttle = null) =>
        new(Path.Combine(_dir, "library"), _vault, "9.9.9", handler: _handler, throttle: throttle ?? new Throttle(TimeSpan.Zero))
        {
            Sleep = (d, _) => { lock (_sleeps) _sleeps.Add(d); return Task.CompletedTask; },
            IsNetworkAvailable = () => _online,
            ExportsDirectory = Path.Combine(_dir, "exports"),
        };

    private const string WorkHtml = """
        <html><body><dl class="stats"><dd class="chapters">3/5</dd><dd class="status">2024-03-12</dd></dl></body></html>
        """;

    // MARK: - Headers & status mapping

    [Fact]
    public async Task SendsIdentifyingHeaders()
    {
        _handler.Respond(_ => FakeHandler.Html(WorkHtml));
        var meta = await MakeClient().FetchWorkMetadataAsync(7);

        Assert.Equal(3, meta.ChapterCount);
        var req = Assert.Single(_handler.Requests);
        Assert.Equal("GET", req.Method);
        Assert.Equal("https://archiveofourown.org/works/7?view_full_work=true&view_adult=true", req.Uri.AbsoluteUri);
        Assert.Equal("Fanficly/9.9.9 (Windows; https://github.com/yennster/fanficly)", req.Header("User-Agent"));
        Assert.Equal("text/html,application/xhtml+xml", req.Header("Accept"));
        Assert.Equal("en-US,en;q=0.9", req.Header("Accept-Language"));
    }

    [Fact]
    public async Task FetchSeriesRequestsTheSeriesPage()
    {
        _handler.Respond(_ => FakeHandler.Html("""
            <html><body><div id="main" class="series-show region"><h2 class="heading">Shore</h2>
            <dl class="series meta group"><dt>Creator:</dt><dd><a rel="author" href="/users/ana/pseuds/ana">ana</a></dd></dl>
            <ul class="series work index group"><li id="work_11" class="work blurb group"><h4 class="heading"><a href="/works/11">One</a></h4></li></ul>
            </div></body></html>
            """));
        var series = await MakeClient().FetchSeriesAsync(9, 2);

        Assert.Equal("Shore", series.Title);
        Assert.Equal([11], series.Works.Select(w => w.Id));
        var req = Assert.Single(_handler.Requests);
        Assert.Equal("GET", req.Method);
        Assert.Equal("https://archiveofourown.org/series/9?page=2", req.Uri.AbsoluteUri);
    }

    [Fact]
    public async Task AsksForHttp3WithFallback()
    {
        _handler.Respond(_ => FakeHandler.Html(WorkHtml));
        await MakeClient().FetchWorkMetadataAsync(7);

        var req = Assert.Single(_handler.Requests);
        Assert.Equal(HttpVersion.Version30, req.Version);
        Assert.Equal(HttpVersionPolicy.RequestVersionOrLower, req.VersionPolicy);
    }

    [Fact]
    public async Task AsksForHttp3OutrightWhenPreferred()
    {
        _handler.Respond(_ => { var r = FakeHandler.Html(WorkHtml); r.Version = HttpVersion.Version30; return r; });
        var client = MakeClient();
        client.PreferHttp3 = true;
        await client.FetchWorkMetadataAsync(7);
        await client.FetchWorkMetadataAsync(8);

        Assert.All(_handler.Requests, req =>
        {
            Assert.Equal(HttpVersion.Version30, req.Version);
            Assert.Equal(HttpVersionPolicy.RequestVersionExact, req.VersionPolicy);
        });
    }

    /// <summary>Where QUIC can't connect (UDP blocked, a proxy) the same request
    /// goes again over HTTP/2 at once, and later ones skip HTTP/3.</summary>
    [Fact]
    public async Task FallsBackToHttp2WhenHttp3CantConnect()
    {
        _handler.Respond(req => req.Version.Major == 3
            ? throw new HttpRequestException(HttpRequestError.ConnectionError, "QUIC handshake failed")
            : FakeHandler.Html(WorkHtml));
        var lines = new List<string>();
        var client = MakeClient();
        client.PreferHttp3 = true;
        client.Log = lines.Add;

        Assert.Equal(3, (await client.FetchWorkMetadataAsync(7)).ChapterCount);
        await client.FetchWorkMetadataAsync(8);

        Assert.Equal(
            new (Version, HttpVersionPolicy)[]
            {
                (HttpVersion.Version30, HttpVersionPolicy.RequestVersionExact),
                (HttpVersion.Version20, HttpVersionPolicy.RequestVersionOrLower),
                (HttpVersion.Version20, HttpVersionPolicy.RequestVersionOrLower),
            },
            _handler.Requests.Select(r => (r.Version, r.VersionPolicy)));
        Assert.Contains(lines, l => l.StartsWith("HTTP/3 to archiveofourown.org failed", StringComparison.Ordinal)
                                    && l.Contains("QUIC handshake failed", StringComparison.Ordinal));
    }

    [Fact]
    public async Task LogsEachRequestWithoutItsQuery()
    {
        _handler.Respond(_ => FakeHandler.Html(WorkHtml));
        var lines = new List<string>();
        var client = MakeClient();
        client.Log = lines.Add;
        await client.FetchWorkMetadataAsync(7);

        var line = Assert.Single(lines);
        Assert.StartsWith("GET /works/7 → 200 over HTTP/", line);
        Assert.DoesNotContain("view_adult", line);
    }

    [Theory]
    [InlineData(401, AO3ErrorKind.Unauthorized)]
    [InlineData(403, AO3ErrorKind.Unauthorized)]
    [InlineData(404, AO3ErrorKind.Http)]
    [InlineData(500, AO3ErrorKind.Http)]
    public async Task MapsErrorStatusesWithoutRetrying(int status, AO3ErrorKind kind)
    {
        _handler.Respond(_ => new HttpResponseMessage((HttpStatusCode)status));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchWorkMetadataAsync(1));
        Assert.Equal(kind, e.Kind);
        if (kind == AO3ErrorKind.Http) Assert.Equal(status, e.Status);
        Assert.Single(_handler.Requests);
        Assert.Empty(_sleeps);
    }

    [Fact]
    public async Task NonUtf8BodyIsAParseFailure()
    {
        _handler.Respond(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([0xC3, 0x28, 0xFF]) });
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchWorkMetadataAsync(1));
        Assert.Equal(AO3ErrorKind.ParseFailed, e.Kind);
        Assert.Equal("Work response not UTF-8", e.Reason);
    }

    // MARK: - Retries

    [Fact]
    public async Task TransientGetFailuresRetryWithBackoff()
    {
        _handler.Respond(
            _ => throw new HttpRequestException(HttpRequestError.ConnectionError, "refused"),
            _ => throw new HttpRequestException(HttpRequestError.NameResolutionError, "dns"),
            _ => FakeHandler.Html(WorkHtml));

        var meta = await MakeClient().FetchWorkMetadataAsync(1);

        Assert.Equal(3, meta.ChapterCount);
        Assert.Equal(3, _handler.Requests.Count);
        Assert.Equal([TimeSpan.FromSeconds(0.5), TimeSpan.FromSeconds(1)], _sleeps);
    }

    [Theory]
    [InlineData(502)]
    [InlineData(503)]
    [InlineData(504)]
    [InlineData(520)]
    [InlineData(525)]
    [InlineData(526)]
    public async Task ServerUnavailableGetsRetryPolitely(int status)
    {
        _handler.Respond(
            _ => new HttpResponseMessage((HttpStatusCode)status),
            _ => new HttpResponseMessage((HttpStatusCode)status),
            _ => FakeHandler.Html(WorkHtml));

        var meta = await MakeClient().FetchWorkMetadataAsync(1);

        Assert.Equal(3, meta.ChapterCount);
        Assert.Equal(3, _handler.Requests.Count);
        Assert.Equal([TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5)], _sleeps);
    }

    [Fact]
    public async Task ServerUnavailableSurfacesAPlainMessageAfterRetries()
    {
        _handler.Respond(_ => new HttpResponseMessage((HttpStatusCode)525));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchWorkMetadataAsync(1));
        Assert.Equal(AO3ErrorKind.Http, e.Kind);
        Assert.Equal(525, e.Status);
        Assert.Equal(3, _handler.Requests.Count);
        Assert.Equal("AO3 isn't responding right now (HTTP 525). This is on AO3's side; try again in a minute.", e.Message);
    }

    [Fact]
    public async Task ServerUnavailablePostIsNeverRetried()
    {
        _handler.Respond(
            _ => FakeHandler.Html(LoginFormHtml),
            _ => new HttpResponseMessage(HttpStatusCode.ServiceUnavailable));
        await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().LoginAsync("user", "pw"));
        Assert.Equal(["GET", "POST"], _handler.Requests.Select(r => r.Method));
        Assert.Empty(_sleeps);
    }

    [Fact]
    public async Task RetriesAreCappedThenSurfaceAsNetworkError()
    {
        _handler.Respond(_ => throw new HttpRequestException(HttpRequestError.SecureConnectionError, "tls"));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchWorkMetadataAsync(1));
        Assert.Equal(AO3ErrorKind.Network, e.Kind);
        Assert.Equal(3, _handler.Requests.Count); // first try + 2 retries
    }

    [Fact]
    public async Task TimeoutsAndResetsAreTransient()
    {
        _handler.Respond(
            _ => throw new TaskCanceledException("timed out"),
            _ => throw new IOException("reset", new SocketException((int)SocketError.ConnectionReset)),
            _ => FakeHandler.Html(WorkHtml));
        await MakeClient().FetchWorkMetadataAsync(1);
        Assert.Equal(3, _handler.Requests.Count);
    }

    [Fact]
    public async Task PermanentFailuresAreNotRetried()
    {
        _handler.Respond(_ => throw new HttpRequestException(HttpRequestError.InvalidResponse, "garbage"));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchWorkMetadataAsync(1));
        Assert.Equal(AO3ErrorKind.Network, e.Kind);
        Assert.Single(_handler.Requests);
    }

    [Fact]
    public async Task NeverRetriesWhileOffline()
    {
        _online = false;
        _handler.Respond(_ => throw new HttpRequestException(HttpRequestError.NameResolutionError, "no network"));
        await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchWorkMetadataAsync(1));
        Assert.Single(_handler.Requests);
        Assert.Empty(_sleeps);
    }

    [Fact]
    public async Task NetworkUnreachableCountsAsOffline()
    {
        _handler.Respond(_ => throw new HttpRequestException(HttpRequestError.ConnectionError, "down",
            new SocketException((int)SocketError.NetworkUnreachable)));
        await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchWorkMetadataAsync(1));
        Assert.Single(_handler.Requests);
    }

    [Fact]
    public async Task PostsAreNeverRetried()
    {
        // Replaying a POST after a timeout could double-submit (a comment that
        // landed but whose response was lost).
        _handler.Respond(
            _ => FakeHandler.Html("""<html><head><meta name="csrf-token" content="T"/></head></html>"""),
            _ => throw new HttpRequestException(HttpRequestError.ConnectionError, "refused"));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().SubscribeToWorkAsync(5));
        Assert.Equal(AO3ErrorKind.Network, e.Kind);
        Assert.Equal(["GET", "POST"], _handler.Requests.Select(r => r.Method));
    }

    [Fact]
    public async Task SearchRetriesOnlyOnce()
    {
        _handler.Respond(_ => throw new TaskCanceledException("timed out"));
        await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().SearchAsync(new AO3SearchFilters(), 1));
        Assert.Equal(2, _handler.Requests.Count);
        Assert.Equal([TimeSpan.FromSeconds(0.5)], _sleeps);
    }

    [Fact]
    public async Task CallerCancellationPropagatesWithoutRetry()
    {
        using var cts = new CancellationTokenSource();
        _handler.Respond(_ =>
        {
            cts.Cancel();
            throw new TaskCanceledException();
        });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => MakeClient().FetchWorkMetadataAsync(1, cts.Token));
        Assert.Single(_handler.Requests);
    }

    [Fact]
    public async Task RateLimitWithShortRetryAfterWaitsItOut()
    {
        _handler.Respond(_ => FakeHandler.TooManyRequests("2"), _ => FakeHandler.Html(WorkHtml));
        await MakeClient().FetchWorkMetadataAsync(1);
        Assert.Equal(2, _handler.Requests.Count);
        Assert.Equal([TimeSpan.FromSeconds(2)], _sleeps);
    }

    [Theory]
    [InlineData("30")]                              // longer than we politely wait
    [InlineData("Wed, 21 Oct 2026 07:28:00 GMT")]  // the HTTP-date form isn't honoured
    [InlineData(null)]                              // no header: fail fast, no blind backoff
    public async Task RateLimitOtherwiseFailsFast(string? retryAfter)
    {
        _handler.Respond(_ => FakeHandler.TooManyRequests(retryAfter));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchWorkMetadataAsync(1));
        Assert.Equal(AO3ErrorKind.RateLimited, e.Kind);
        Assert.Single(_handler.Requests);
        Assert.Empty(_sleeps);
    }

    [Fact]
    public async Task EveryRequestGoesThroughTheThrottle()
    {
        _handler.Respond(_ => FakeHandler.Html(WorkHtml));
        var client = MakeClient(new Throttle(TimeSpan.FromSeconds(0.1)));
        var sw = Stopwatch.StartNew();
        await Task.WhenAll(client.FetchWorkMetadataAsync(1), client.FetchWorkMetadataAsync(2), client.FetchWorkMetadataAsync(3));
        Assert.True(sw.Elapsed >= TimeSpan.FromSeconds(0.18), $"three throttled requests took {sw.Elapsed}");
    }

    // MARK: - Cookies & login

    private const string LoginFormHtml = """
        <html><body><form id="new_user" action="/users/login" method="post">
          <input name="authenticity_token" type="hidden" value="TOKEN1"/>
          <input name="user[login]"/>
        </form></body></html>
        """;

    [Fact]
    public async Task LoginReplaysTheFormFollowsTheRedirectAndPersistsTheSession()
    {
        _handler.Respond(
            _ => FakeHandler.Html(LoginFormHtml),
            _ =>
            {
                var r = new HttpResponseMessage(HttpStatusCode.Found);
                r.Headers.Location = new Uri("/users/reader", UriKind.Relative);
                r.Headers.Add("Set-Cookie", "_otwarchive_session=abc123; path=/; secure; HttpOnly");
                r.Headers.Add("Set-Cookie", "remember_user_token=xyz; path=/; expires=Wed, 21 Oct 2037 07:28:00 GMT; secure");
                return r;
            },
            _ => FakeHandler.Html("""<html><body><div id="greeting"><a href="/users/reader">reader</a></div></body></html>"""));

        var client = MakeClient();
        await client.LoginAsync("reader", "p@ss word");

        Assert.Equal("reader", await client.CurrentUsernameAsync());
        var post = _handler.Requests[1];
        Assert.Equal("POST", post.Method);
        Assert.Equal("https://archiveofourown.org/users/login", post.Uri.AbsoluteUri);
        Assert.Equal("application/x-www-form-urlencoded", post.Header("Content-Type"));
        Assert.Equal("https://archiveofourown.org", post.Header("Origin"));
        Assert.Equal("https://archiveofourown.org/users/login", post.Header("Referer"));
        Assert.Equal(
            "utf8=%E2%9C%93&authenticity_token=TOKEN1&user%5Blogin%5D=reader&user%5Bpassword%5D=p%40ss%20word&user%5Bremember_me%5D=1&commit=Log%20in",
            post.Body);

        // The 302 continues as a GET, without the body, carrying the new cookies.
        var follow = _handler.Requests[2];
        Assert.Equal("GET", follow.Method);
        Assert.Equal("https://archiveofourown.org/users/reader", follow.Uri.AbsoluteUri);
        Assert.Null(follow.Body);
        Assert.Contains("_otwarchive_session=abc123", follow.Header("Cookie"));
        Assert.Contains("remember_user_token=xyz", follow.Header("Cookie"));

        var saved = _vault.LoadCookies();
        Assert.Equal(["_otwarchive_session", "remember_user_token"], saved.Select(c => c.Name).Order());
        Assert.Null(saved.Single(c => c.Name == "_otwarchive_session").ExpiresDate);
        Assert.NotNull(saved.Single(c => c.Name == "remember_user_token").ExpiresDate);
    }

    [Fact]
    public async Task LoginFailureFlashSurfaces()
    {
        _handler.Respond(
            _ => FakeHandler.Html(LoginFormHtml),
            _ => FakeHandler.Html("""<html><body><div id="flash_error">The password or username you entered doesn't match our records.</div></body></html>"""));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().LoginAsync("reader", "wrong"));
        Assert.Equal(AO3ErrorKind.LoginFailed, e.Kind);
        Assert.Contains("password", e.Reason);
    }

    [Fact]
    public async Task LoginStillOnTheFormIsRejected()
    {
        _handler.Respond(_ => FakeHandler.Html(LoginFormHtml));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().LoginAsync("reader", "wrong"));
        Assert.Equal("Incorrect username or password.", e.Reason);
    }

    [Fact]
    public async Task LoginWithoutTokenIsAParseFailure()
    {
        _handler.Respond(_ => FakeHandler.Html("<html></html>"));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().LoginAsync("reader", "x"));
        Assert.Equal(AO3ErrorKind.ParseFailed, e.Kind);
        Assert.Single(_handler.Requests);
    }

    [Fact]
    public async Task LoginTrustsASessionCookieWhenThePageIsUnrecognised()
    {
        _handler.Respond(
            _ => FakeHandler.Html(LoginFormHtml),
            _ => FakeHandler.Html("<html><body>Welcome</body></html>", "user_credentials=1; path=/"));
        var client = MakeClient();
        await client.LoginAsync("typed_name", "x");
        Assert.Equal("typed_name", await client.CurrentUsernameAsync());
    }

    // MARK: - A chapter at a time

    [Fact]
    public async Task FirstChapterIsOneLightPage()
    {
        _handler.Respond(_ => FakeHandler.Html(WorkChapterPageTests.ChapterPage(1)));
        var page = await MakeClient().FetchWorkChapterAsync(55);

        var req = Assert.Single(_handler.Requests);
        Assert.Equal("https://archiveofourown.org/works/55?view_adult=true", req.Uri.AbsoluteUri);
        Assert.Equal(1, Assert.Single(page.Payload.Chapters).Index);
        Assert.False(page.IsWholeWork);
    }

    [Fact]
    public async Task ALaterChapterFollowsTheFirstPagesMenu()
    {
        _handler.Respond(
            _ => FakeHandler.Html(WorkChapterPageTests.ChapterPage(1)),
            _ => FakeHandler.Html(WorkChapterPageTests.ChapterPage(3)));
        var page = await MakeClient().FetchWorkChapterAsync(55, chapter: 3);

        Assert.Equal(
            ["https://archiveofourown.org/works/55?view_adult=true", "https://archiveofourown.org/works/55/chapters/703?view_adult=true"],
            _handler.Requests.Select(r => r.Uri.AbsoluteUri));
        var chapter = Assert.Single(page.Payload.Chapters);
        Assert.Equal(3, chapter.Index);
        Assert.Equal(703, chapter.AoId);
    }

    [Fact]
    public async Task AChapterPastTheEndStaysOnTheFirst()
    {
        _handler.Respond(_ => FakeHandler.Html(WorkChapterPageTests.ChapterPage(1)));
        var page = await MakeClient().FetchWorkChapterAsync(55, chapter: 9);

        Assert.Single(_handler.Requests);
        Assert.Equal(1, Assert.Single(page.Payload.Chapters).Index);
    }

    [Fact]
    public async Task UnreadableChapterPageFallsBackToTheWholeWork()
    {
        _handler.Respond(
            _ => FakeHandler.Html("<html><body>Something else</body></html>"),
            _ => FakeHandler.Html(WorkChapterPageTests.ChapterPage(1)));
        var page = await MakeClient().FetchWorkChapterAsync(55);

        Assert.Equal("https://archiveofourown.org/works/55?view_full_work=true&view_adult=true", _handler.Requests[1].Uri.AbsoluteUri);
        Assert.True(page.IsWholeWork);
    }

    [Fact]
    public async Task SavedCookiesAreLoadedBeforeTheFirstRequest()
    {
        _vault.SaveCookies([new SerializableCookie("_otwarchive_session", "saved", "archiveofourown.org", "/", null, true, true)]);
        _handler.Respond(_ => FakeHandler.Html(WorkHtml));
        await MakeClient().FetchWorkMetadataAsync(1);
        Assert.Equal("_otwarchive_session=saved", _handler.Requests[0].Header("Cookie"));
    }

    [Fact]
    public async Task LogoutForgetsAndPersistsTheEmptySession()
    {
        _vault.SaveCookies([new SerializableCookie("_otwarchive_session", "saved", "archiveofourown.org", "/", null, true, true)]);
        _handler.Respond(_ => FakeHandler.Html(WorkHtml));
        var client = MakeClient();
        await client.FetchWorkMetadataAsync(1);
        await client.LogoutAsync();
        await client.FetchWorkMetadataAsync(1);

        Assert.Null(_handler.Requests[1].Header("Cookie"));
        Assert.Empty(_vault.LoadCookies());
        Assert.Null(await client.CurrentUsernameAsync());
    }

    // MARK: - Endpoint flows

    [Fact]
    public async Task AutocompleteAsksForJsonAndDecodesTolerantly()
    {
        _handler.Respond(_ => FakeHandler.Json("""[{"id":"Harry Potter/Draco Malfoy","name":"Harry Potter/Draco Malfoy"},{"id":"Only Id"},{"id":null,"name":null},{"id":5,"name":"Numeric Id"}]"""));
        var names = await MakeClient().AutocompleteAsync(AO3AutocompleteField.Relationship, "  harry/draco ");

        Assert.Equal(["Harry Potter/Draco Malfoy", "Only Id", "Numeric Id"], names);
        var req = Assert.Single(_handler.Requests);
        Assert.Equal("https://archiveofourown.org/autocomplete/relationship?term=harry%2Fdraco", req.Uri.AbsoluteUri);
        Assert.Equal("application/json, text/javascript, */*; q=0.01", req.Header("Accept"));
        Assert.Equal("XMLHttpRequest", req.Header("X-Requested-With"));
    }

    [Fact]
    public async Task AutocompleteMalformedJsonIsNoSuggestions()
    {
        _handler.Respond(_ => FakeHandler.Json("<html>not json</html>"));
        Assert.Empty(await MakeClient().AutocompleteAsync(AO3AutocompleteField.Tag, "x"));
    }

    [Fact]
    public async Task AutocompleteBlankTermSendsNothing()
    {
        Assert.Empty(await MakeClient().AutocompleteAsync(AO3AutocompleteField.Tag, "   "));
        Assert.Empty(_handler.Requests);
    }

    private static string SubscriptionsPage(int page, int total, params int[] workIds) => $"""
        <html><body><dl class="subscription index group">
        {string.Join("\n", workIds.Select(id => $"<dt><a href=\"/works/{id}\">Work {id}</a></dt>"))}
        </dl><ol class="pagination actions"><li><span class="current">{page}</span></li><li><a href="?page={total}">{total}</a></li></ol></body></html>
        """;

    [Fact]
    public async Task FetchSubscriptionsWalksEveryPageAndDedupes()
    {
        _handler.Respond(
            _ => FakeHandler.Html(SubscriptionsPage(1, 3, 1, 2)),
            _ => FakeHandler.Html(SubscriptionsPage(2, 3, 2, 3)),
            _ => FakeHandler.Html(SubscriptionsPage(3, 3, 4)));
        var subs = await MakeClient().FetchSubscriptionsAsync("reader");

        Assert.Equal(["1", "2", "3", "4"], subs.Select(s => s.ResourceId));
        Assert.Equal(
            ["https://archiveofourown.org/users/reader/subscriptions",
             "https://archiveofourown.org/users/reader/subscriptions?page=2",
             "https://archiveofourown.org/users/reader/subscriptions?page=3"],
            _handler.Requests.Select(r => r.Uri.AbsoluteUri));
    }

    [Fact]
    public async Task FetchSubscriptionsFailsWholeWhenAnyPageFails()
    {
        // A partial list must never reach the poller's delete pass.
        _handler.Respond(
            _ => FakeHandler.Html(SubscriptionsPage(1, 2, 1)),
            _ => FakeHandler.Html("<html><body>Something went wrong</body></html>"));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchSubscriptionsAsync("reader"));
        Assert.Equal(AO3ErrorKind.ParseFailed, e.Kind);
    }

    [Fact]
    public async Task FetchSubscriptionsStopsAtFiftyPages()
    {
        _handler.Respond(_ => FakeHandler.Html(SubscriptionsPage(1, 999, 1)));
        await MakeClient().FetchSubscriptionsAsync("reader");
        Assert.Equal(50, _handler.Requests.Count);
    }

    [Fact]
    public async Task FetchCommentsRequestsTheChapterPageAndReadsItsPagination()
    {
        _handler.Respond(_ => FakeHandler.Html("""
            <html><body><div id="comments_placeholder">
              <ol class="pagination actions" role="navigation" title="pagination">
                <li class="previous" title="previous"><a rel="prev" href="/works/12/chapters/34?page=1&amp;show_comments=true#comments">← Previous</a></li>
                <li><a href="/works/12/chapters/34?page=1&amp;show_comments=true#comments">1</a></li>
                <li><span class="current">2</span></li>
                <li><a href="/works/12/chapters/34?page=3&amp;show_comments=true#comments">3</a></li>
                <li class="next" title="next"><a rel="next" href="/works/12/chapters/34?page=3&amp;show_comments=true#comments">Next →</a></li>
              </ol>
              <ol class="thread"><li class="comment group" id="comment_5"><blockquote class="userstuff"><p>Hi</p></blockquote></li></ol>
            </div></body></html>
            """));

        var page = await MakeClient().FetchCommentsAsync(12, 34, 2);

        Assert.Equal("https://archiveofourown.org/works/12/chapters/34?view_adult=true&show_comments=true&page=2#comments",
            Assert.Single(_handler.Requests).Uri.AbsoluteUri);
        Assert.Equal("5", Assert.Single(page.Comments).Id);
        Assert.Equal(2, page.CurrentPage);
        Assert.Equal(3, page.TotalPages);
        Assert.True(page.HasMore);
    }

    [Fact]
    public async Task PostCommentReplaysThePagesOwnForm()
    {
        _handler.Respond(
            _ => FakeHandler.Html("""
                <html><body><form action="/works/12/chapters/34/comments" method="post">
                  <input type="hidden" name="authenticity_token" value="CSRF">
                  <input type="hidden" name="comment[commentable_id]" value="34">
                  <select name="comment[pseud_id]"><option value="77" selected>me</option></select>
                  <textarea name="comment[comment_content]"></textarea>
                </form></body></html>
                """),
            _ => FakeHandler.Redirect("/works/12/chapters/34#comment_1"),
            _ => FakeHandler.Html("<html></html>"));

        await MakeClient().PostCommentAsync(12, 34, "  Loved it!  ");

        Assert.Equal("https://archiveofourown.org/works/12/chapters/34?view_adult=true&show_comments=true#comments",
            _handler.Requests[0].Uri.AbsoluteUri);
        var post = _handler.Requests[1];
        Assert.Equal("POST", post.Method);
        Assert.Equal("https://archiveofourown.org/works/12/chapters/34/comments", post.Uri.AbsoluteUri);
        Assert.Equal("CSRF", post.Header("X-CSRF-Token"));
        Assert.Equal(_handler.Requests[0].Uri.AbsoluteUri, post.Header("Referer"));
        var form = post.Body!.Split('&').ToHashSet();
        Assert.Contains("authenticity_token=CSRF", form);
        Assert.Contains("comment%5Bcommentable_id%5D=34", form);
        Assert.Contains("comment%5Bpseud_id%5D=77", form);
        Assert.Contains("comment%5Bcomment_content%5D=Loved%20it%21", form);
        Assert.Contains("commit=Comment", form);
    }

    private const string CommentFormHtml = """
        <html><body><form action="/works/12/comments" method="post">
          <input type="hidden" name="authenticity_token" value="CSRF">
          <textarea name="comment[comment_content]"></textarea>
        </form></body></html>
        """;

    [Fact]
    public async Task ARefusedCommentIsNotPosted()
    {
        // AO3 re-renders the form with a 200 when it won't save a comment.
        _handler.Respond(
            _ => FakeHandler.Html(CommentFormHtml),
            _ => FakeHandler.Html("""<html><body><div class="flash error">Couldn't save comment!</div></body></html>"""));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().PostCommentAsync(12, null, "hi"));
        Assert.Equal(AO3ErrorKind.Rejected, e.Kind);
        Assert.Contains("Couldn't save comment!", e.Message);
    }

    [Fact]
    public async Task ACommentThatEndsAtLoginNeedsASignIn()
    {
        _handler.Respond(
            _ => FakeHandler.Html(CommentFormHtml),
            _ => FakeHandler.Redirect("/users/login"),
            _ => FakeHandler.Html(LoginFormHtml));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().PostCommentAsync(12, null, "hi"));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
    }

    [Fact]
    public async Task PostCommentIgnoresBlankText()
    {
        await MakeClient().PostCommentAsync(12, null, " \n ");
        Assert.Empty(_handler.Requests);
    }

    [Fact]
    public async Task PostCommentWithoutAComposerFails()
    {
        _handler.Respond(_ => FakeHandler.Html("<html><body>Log in to comment</body></html>"));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().PostCommentAsync(12, null, "hi"));
        Assert.Equal(AO3ErrorKind.ParseFailed, e.Kind);
        Assert.Single(_handler.Requests);
    }

    [Fact]
    public async Task SubscribePostsTheCsrfForm()
    {
        _handler.Respond(
            _ => FakeHandler.Html("""<html><head><meta name="csrf-token" content="T0K"/></head></html>"""),
            _ => FakeHandler.Html("<html></html>"));
        await MakeClient().SubscribeToWorkAsync(42);

        var post = _handler.Requests[1];
        Assert.Equal("https://archiveofourown.org/works/42/subscriptions", post.Uri.AbsoluteUri);
        Assert.Equal("T0K", post.Header("X-CSRF-Token"));
        Assert.Equal("authenticity_token=T0K&subscription%5Bsubscribable_id%5D=42&subscription%5Bsubscribable_type%5D=Work", post.Body);
    }

    [Fact]
    public async Task ARefusedTokenIsNotSubscribed()
    {
        _handler.Respond(
            _ => FakeHandler.Html("""<html><head><meta name="csrf-token" content="T0K"/></head></html>"""),
            _ => new HttpResponseMessage(HttpStatusCode.UnprocessableEntity));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().SubscribeToWorkAsync(42));
        Assert.Equal(AO3ErrorKind.Http, e.Kind);
    }

    [Fact]
    public async Task ASubscriptionAO3TurnsDownIsNotSubscribed()
    {
        _handler.Respond(
            _ => FakeHandler.Html("""<html><head><meta name="csrf-token" content="T0K"/></head></html>"""),
            _ => FakeHandler.Redirect("/works/42"),
            _ => FakeHandler.Html("""<html><body><div class="flash error">You can't subscribe to that.</div></body></html>"""));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().SubscribeToWorkAsync(42));
        Assert.Equal(AO3ErrorKind.Rejected, e.Kind);
    }

    [Fact]
    public async Task AlreadySubscribedCountsAsSubscribed()
    {
        _handler.Respond(
            _ => FakeHandler.Html("""<html><head><meta name="csrf-token" content="T0K"/></head></html>"""),
            _ => FakeHandler.Html("""<html><body><div class="flash error">You are already subscribed to that.</div></body></html>"""));
        await MakeClient().SubscribeToWorkAsync(42);
    }

    [Fact]
    public async Task ARestrictedWorkSignedOutIsNotReadAsOneChapter()
    {
        // The poller would otherwise reset its new-chapter baseline to 1.
        _handler.Respond(_ => FakeHandler.Redirect("/users/login?restricted=true"), _ => FakeHandler.Html(LoginFormHtml));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchWorkMetadataAsync(7));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
    }

    [Fact]
    public async Task AWorkPageWithoutAChapterCountFails()
    {
        _handler.Respond(_ => FakeHandler.Html("<html><body>Something went wrong</body></html>"));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchWorkMetadataAsync(7));
        Assert.Equal(AO3ErrorKind.ParseFailed, e.Kind);
    }

    [Fact]
    public async Task AWorkPageWithoutChaptersFails()
    {
        // Saving it would replace the stored chapters with none.
        _handler.Respond(_ => FakeHandler.Html("<html><body>Something went wrong</body></html>"));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchWorkAsync(7));
        Assert.Equal(AO3ErrorKind.ParseFailed, e.Kind);
    }

    [Fact]
    public async Task AnEpubThatEndsAtLoginIsNotSaved()
    {
        _handler.Respond(_ => FakeHandler.Redirect("/users/login?restricted=true"), _ => FakeHandler.Html(LoginFormHtml));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().DownloadEpubAsync(55));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
        Assert.False(File.Exists(Path.Combine(_dir, "library", "55.epub")));
    }

    [Theory]
    [InlineData("<!DOCTYPE html><html><body>Retry later</body></html>")]
    [InlineData("\uFEFF  \n<html></html>")]
    [InlineData("")]
    public async Task AWebPageIsNotSavedAsTheBook(string body)
    {
        _handler.Respond(_ => FakeHandler.Html(body));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().DownloadEpubAsync(55));
        Assert.Equal(AO3ErrorKind.ParseFailed, e.Kind);
        Assert.False(File.Exists(Path.Combine(_dir, "library", "55.epub")));
        await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().ExportWorkAsync(55, WorkExportFormat.Pdf, "x"));
    }

    [Fact]
    public async Task AnHtmlExportIsAWebPage()
    {
        _handler.Respond(_ => FakeHandler.Html("<html><body>The story</body></html>"));
        var path = await MakeClient().ExportWorkAsync(55, WorkExportFormat.Html, "x");
        Assert.True(File.Exists(path));
    }

    [Fact]
    public async Task BookmarksSignedOutAskForASignIn()
    {
        _handler.Respond(_ => FakeHandler.Html("""
            <html><body><div id="login"><form id="new_user" action="/users/login"></form></div>
            <ol class="bookmark index group"></ol></body></html>
            """));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchBookmarksAsync("reader", 1));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
    }

    [Fact]
    public async Task MarkedForLaterReadsTheReadingsPage()
    {
        _handler.Respond(_ => FakeHandler.Html("""
            <html><body><div id="main" class="readings-index dashboard region">
            <ol class="reading work index group">
              <li id="work_4242" class="reading work blurb group"><div class="header module">
                <h4 class="heading"><a href="/works/4242">Saved</a></h4></div></li>
            </ol></div></body></html>
            """));
        var result = await MakeClient().FetchMarkedForLaterAsync("reader", 2);
        Assert.Equal([4242], result.Works.Select(w => w.Id));
        Assert.Equal("https://archiveofourown.org/users/reader/readings?show=to-read&page=2", _handler.Requests[0].Uri.AbsoluteUri);
    }

    [Fact]
    public async Task ReadingHistoryReadsTheUnfilteredReadingsPage()
    {
        _handler.Respond(_ => FakeHandler.Html("""
            <html><body><div id="main" class="readings-index dashboard region">
            <ol class="reading work index group">
              <li id="work_11" class="reading work blurb group"><div class="header module">
                <h4 class="heading"><a href="/works/11">Visited</a></h4></div></li>
            </ol></div></body></html>
            """));
        var result = await MakeClient().FetchReadingHistoryAsync("reader", 1);
        Assert.Equal([11], result.Works.Select(w => w.Id));
        Assert.Equal("https://archiveofourown.org/users/reader/readings", _handler.Requests[0].Uri.AbsoluteUri);
    }

    [Fact]
    public async Task MarkedForLaterSignedOutAsksForASignIn()
    {
        _handler.Respond(_ => FakeHandler.Html("""
            <html><body><div id="login"><form id="new_user" action="/users/login"></form></div></body></html>
            """));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().FetchMarkedForLaterAsync("reader", 1));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
    }

    [Fact]
    public async Task DownloadEpubWritesIntoTheLibrary()
    {
        _handler.Respond(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([1, 2, 3]) });
        var path = await MakeClient().DownloadEpubAsync(55);

        Assert.Equal(Path.Combine(_dir, "library", "55.epub"), path);
        Assert.Equal([1, 2, 3], await File.ReadAllBytesAsync(path));
        Assert.Equal("https://archiveofourown.org/downloads/55/work.epub", _handler.Requests[0].Uri.AbsoluteUri);
    }

    [Fact]
    public async Task ExportWorkSanitizesTheFilename()
    {
        _handler.Respond(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([9]) });
        var client = MakeClient();
        var path = await client.ExportWorkAsync(55, WorkExportFormat.Pdf, "What? A/B: \"Story\"");
        Assert.Equal(Path.Combine(_dir, "exports", "What- A-B- -Story-.pdf"), path);
        Assert.True(File.Exists(path));

        var fallback = await client.ExportWorkAsync(55, WorkExportFormat.Epub, "");
        Assert.Equal(Path.Combine(_dir, "exports", "work-55.epub"), fallback);
    }

    [Fact]
    public void SanitizeFilenameKeepsEightyCharacters()
    {
        Assert.Equal(new string('a', 80), AO3Client.SanitizeFilename(new string('a', 100)));
        Assert.Equal("x", AO3Client.SanitizeFilename("  x  "));
    }

    [Fact]
    public async Task PopularSnapshotFallsBackToCuratedListsWhenAO3Fails()
    {
        _handler.Respond(_ => new HttpResponseMessage(HttpStatusCode.InternalServerError));
        var snapshot = await MakeClient().FetchPopularSnapshotAsync();
        Assert.Equal(PopularTags.Fandoms, snapshot.Fandoms);
        Assert.Equal(PopularTags.Ships, snapshot.Ships);
        Assert.Equal(PopularTags.Characters, snapshot.Characters);
    }

    [Fact]
    public async Task PopularSnapshotRanksLiveCounts()
    {
        _handler.Respond(req =>
        {
            var path = req.RequestUri!.AbsolutePath;
            if (path.StartsWith("/media/", StringComparison.Ordinal))
                return FakeHandler.Html("""<ol><li><a href="/tags/Small/works">Small</a> (10)</li><li><a href="/tags/Big/works">Big</a> (900)</li></ol>""");
            return FakeHandler.Html("""
                <label for="include_work_search_relationship_ids_1"><span>A/B (5)</span></label>
                <label for="include_work_search_character_ids_2"><span>Cee (7)</span></label>
                """);
        });
        var snapshot = await MakeClient().FetchPopularSnapshotAsync();
        Assert.Equal(["Big", "Small"], snapshot.Fandoms);
        Assert.Equal(["A/B"], snapshot.Ships);
        Assert.Equal(["Cee"], snapshot.Characters);
    }

    // MARK: - Kudos

    /// <summary>A signed-in work page with AO3's kudos form.</summary>
    private const string KudosPageHtml = """
        <html><head><meta name="csrf-token" content="META"/></head><body>
        <div id="greeting"><a href="/users/reader">Hi, reader!</a></div>
        <form id="new_kudo" action="/kudos" accept-charset="UTF-8" method="post">
          <input type="hidden" name="authenticity_token" value="FORM" autocomplete="off" />
          <input value="42" autocomplete="off" type="hidden" name="kudo[commentable_id]" id="kudo_commentable_id" />
          <input value="Work" autocomplete="off" type="hidden" name="kudo[commentable_type]" id="kudo_commentable_type" />
          <input type="submit" name="commit" value="Kudos ♥" id="kudo_submit" />
        </form></body></html>
        """;

    private static HttpResponseMessage KudosRefused(string message) =>
        new(HttpStatusCode.UnprocessableEntity)
        {
            Content = new StringContent($$"""{"error_message":"{{message}}"}""", Encoding.UTF8, "application/json"),
        };

    [Fact]
    public async Task LeaveKudosPostsTheWorkPagesFormToKudosJs()
    {
        _handler.Respond(
            _ => FakeHandler.Html(KudosPageHtml),
            _ => new HttpResponseMessage(HttpStatusCode.Created) { Content = new StringContent("// js", Encoding.UTF8, "text/javascript") });

        Assert.Equal(KudosOutcome.Left, await MakeClient().LeaveKudosAsync(42));

        Assert.Equal("https://archiveofourown.org/works/42?view_adult=true", _handler.Requests[0].Uri.AbsoluteUri);
        var post = _handler.Requests[1];
        Assert.Equal("POST", post.Method);
        Assert.Equal("https://archiveofourown.org/kudos.js", post.Uri.AbsoluteUri);
        // The page-wide meta token, not the form's per-form one (valid only for /kudos).
        Assert.Equal("META", post.Header("X-CSRF-Token"));
        Assert.Equal("XMLHttpRequest", post.Header("X-Requested-With"));
        Assert.Equal(_handler.Requests[0].Uri.AbsoluteUri, post.Header("Referer"));
        var form = post.Body!.Split('&').ToHashSet();
        Assert.Equal(["authenticity_token=META", "kudo%5Bcommentable_id%5D=42", "kudo%5Bcommentable_type%5D=Work"], form.Order());
    }

    [Fact]
    public async Task KudosAlreadyLeftCountAsLeft()
    {
        _handler.Respond(
            _ => FakeHandler.Html(KudosPageHtml),
            _ => KudosRefused("You have already left kudos here. :)"));
        Assert.Equal(KudosOutcome.AlreadyLeft, await MakeClient().LeaveKudosAsync(42));
    }

    [Fact]
    public async Task RefusedKudosCarryAO3sReason()
    {
        _handler.Respond(
            _ => FakeHandler.Html(KudosPageHtml),
            _ => KudosRefused("Sorry, you have been blocked by one or more of this work's creators."));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().LeaveKudosAsync(42));
        Assert.Equal(AO3ErrorKind.Rejected, e.Kind);
        Assert.Equal("Sorry, you have been blocked by one or more of this work's creators.", e.Reason);
    }

    [Fact]
    public async Task KudosNeedASignedInPage()
    {
        // AO3 takes guest kudos, so a page without the signed-in greeting must
        // stop before the POST rather than leave one as a guest.
        _handler.Respond(_ => FakeHandler.Html(KudosPageHtml.Replace("""<div id="greeting"><a href="/users/reader">Hi, reader!</a></div>""", "")));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().LeaveKudosAsync(42));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
        Assert.Single(_handler.Requests);
    }

    [Fact]
    public async Task KudosStopOnAO3sSignedOutHeader()
    {
        // The header's /users/login?return_to=… link once read as a signed-in name.
        _handler.Respond(_ => FakeHandler.Html(KudosParserTests.SignedOutHeader.Replace("</header>",
            """</header><form id="new_kudo" action="/kudos"><input type="hidden" name="kudo[commentable_id]" value="42"></form>""")));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().LeaveKudosAsync(42));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
        Assert.Single(_handler.Requests);
    }

    [Fact]
    public async Task NoKudosButtonMeansNoPost()
    {
        // Your own work, or a creator who blocked you: AO3 leaves the form out.
        _handler.Respond(_ => FakeHandler.Html("""<html><body><div id="greeting"><a href="/users/reader">reader</a></div></body></html>"""));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().LeaveKudosAsync(42));
        Assert.Equal(AO3ErrorKind.Rejected, e.Kind);
        Assert.Single(_handler.Requests);
    }

    [Fact]
    public async Task ARefusedTokenNeedsASignIn()
    {
        _handler.Respond(
            _ => FakeHandler.Html(KudosPageHtml),
            _ => new HttpResponseMessage(HttpStatusCode.UnprocessableEntity)
            {
                Content = new StringContent("""{"errors":{"auth_error":"Your current session has expired."}}""", Encoding.UTF8, "application/json"),
            });
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().LeaveKudosAsync(42));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
    }

    [Fact]
    public async Task OnlyA201CountsAsLeft()
    {
        // A 200 maintenance or proxy page isn't AO3's kudos answer.
        _handler.Respond(
            _ => FakeHandler.Html(KudosPageHtml),
            _ => FakeHandler.Html("<html><body>Down for maintenance</body></html>"));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().LeaveKudosAsync(42));
        Assert.Equal(AO3ErrorKind.Rejected, e.Kind);
    }

    [Fact]
    public async Task AKudosPostIsNeverRetried()
    {
        _handler.Respond(
            _ => FakeHandler.Html(KudosPageHtml),
            _ => throw new HttpRequestException(HttpRequestError.ConnectionError, "refused"));
        var e = await Assert.ThrowsAsync<AO3Exception>(() => MakeClient().LeaveKudosAsync(42));
        Assert.Equal(AO3ErrorKind.Network, e.Kind);
        Assert.Equal(["GET", "POST"], _handler.Requests.Select(r => r.Method));
    }
}

/// <summary>A scripted <see cref="HttpMessageHandler"/>: each request gets the next
/// responder (the last one repeats) and is recorded.</summary>
internal sealed class FakeHandler : HttpMessageHandler
{
    private readonly List<Func<HttpRequestMessage, HttpResponseMessage>> _responders = [];
    private readonly Lock _gate = new();
    private int _next;

    public List<RecordedRequest> Requests { get; } = [];

    public void Respond(params Func<HttpRequestMessage, HttpResponseMessage>[] responders) => _responders.AddRange(responders);

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(ct);
        Func<HttpRequestMessage, HttpResponseMessage> responder;
        lock (_gate)
        {
            Requests.Add(new RecordedRequest(request.Method.Method, request.RequestUri!, request.Version, request.VersionPolicy,
                // The raw values, as written (reading the parsed ones re-formats them).
                request.Headers.NonValidated.Select(h => (h.Key, Value: string.Join(", ", h.Value)))
                    .Concat(request.Content is null ? [] : request.Content.Headers.NonValidated.Select(h => (h.Key, Value: string.Join(", ", h.Value))))
                    .ToDictionary(h => h.Key, h => h.Value, StringComparer.OrdinalIgnoreCase),
                body));
            responder = _responders[Math.Min(_next++, _responders.Count - 1)];
        }
        return responder(request);
    }

    public static HttpResponseMessage Html(string html, string? setCookie = null)
    {
        var r = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(html, Encoding.UTF8, "text/html") };
        if (setCookie is not null) r.Headers.Add("Set-Cookie", setCookie);
        return r;
    }

    public static HttpResponseMessage Redirect(string location)
    {
        var r = new HttpResponseMessage(HttpStatusCode.Found);
        r.Headers.Location = new Uri(location, UriKind.Relative);
        return r;
    }

    public static HttpResponseMessage Json(string json) =>
        new(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    public static HttpResponseMessage TooManyRequests(string? retryAfter)
    {
        var r = new HttpResponseMessage(HttpStatusCode.TooManyRequests);
        if (retryAfter is not null) r.Headers.TryAddWithoutValidation("Retry-After", retryAfter);
        return r;
    }
}

internal sealed record RecordedRequest(string Method, Uri Uri, Version Version, HttpVersionPolicy VersionPolicy, IReadOnlyDictionary<string, string> Headers, string? Body)
{
    public string? Header(string name) => Headers.TryGetValue(name, out var v) ? v : null;
}
