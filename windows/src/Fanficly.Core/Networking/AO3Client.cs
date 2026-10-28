using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace Fanficly.Core;

/// <summary>The live AO3 client: scrapes AO3's HTML over one shared
/// <see cref="HttpClient"/>, every request spaced by a 1 req/sec <see cref="Throttle"/>.
/// AO3 is generous to good citizens and hostile to bad ones, so nothing here ever
/// bypasses the throttle, and only idempotent GETs are ever retried.</summary>
public sealed class AO3Client : IAO3Client, IDisposable
{
    public static readonly Uri DefaultBaseUri = new("https://archiveofourown.org");

    /// <summary>Don't let a stalled request hang: the time allowed for a response to
    /// start arriving.</summary>
    internal static readonly TimeSpan DefaultRequestTimeout = TimeSpan.FromSeconds(30);
    /// <summary>AO3's search pages routinely take 20–30 s to start responding (the
    /// server is busy rendering, not stalled), so search gets longer.</summary>
    internal static readonly TimeSpan SearchRequestTimeout = TimeSpan.FromSeconds(60);
    /// <summary>The overall cap on one attempt, body included.</summary>
    internal static readonly TimeSpan ResourceTimeout = TimeSpan.FromSeconds(90);

    /// <summary>How many times a transient failure (timeout / dropped connection / a
    /// short 429) is retried before it surfaces to the caller.</summary>
    internal const int MaxRetries = 2;
    /// <summary>The longest Retry-After we're willing to wait out inside a request
    /// before surfacing RateLimited to the caller.</summary>
    internal static readonly TimeSpan MaxPoliteRetryAfter = TimeSpan.FromSeconds(10);
    private const int MaxRedirects = 10;

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    private readonly HttpClient _http;
    /// <summary>The HTTP/3 lane: its own pool, so connecting over QUIC can be capped
    /// at <see cref="Http3ConnectTimeout"/> without shortening HTTP/2's connects. The
    /// same client as <see cref="_http"/> when a test injects a handler.</summary>
    private readonly HttpClient _http3;
    private readonly Uri _baseUri;
    private readonly string _origin;
    private readonly ICookieVault _vault;
    private readonly Throttle _throttle;
    private readonly string _libraryDirectory;
    private readonly Lock _cookieGate = new();
    /// <summary>Held around every vault write, so a save can't land after logout
    /// cleared the vault (#145).</summary>
    private readonly Lock _vaultGate = new();
    private CookieContainer _cookies = new();
    private bool _cookiesLoaded;
    private string? _lastSavedCookies;
    /// <summary>Signed in on this PC: cookie changes are saved. Read from the
    /// vault at the first request, set by a sign-in, cleared by logout.</summary>
    private bool _signedIn;
    /// <summary>Goes up at every logout. A request sent at an older generation
    /// carried the old session's cookies, so its Set-Cookie headers are ignored.</summary>
    private int _cookieGeneration;
    private volatile string? _cachedUsername;

    /// <param name="libraryDirectory">Where <see cref="DownloadEpubAsync"/> stores
    /// <c>&lt;id&gt;.epub</c> files.</param>
    /// <param name="cookieVault">Persists the session cookies; defaults to
    /// <see cref="CredentialStore.Shared"/>.</param>
    /// <param name="appVersion">Goes in the User-Agent.</param>
    /// <param name="baseUri">The site; AO3 unless a test says otherwise.</param>
    /// <param name="handler">The transport; a cookie-less, non-redirecting
    /// <see cref="SocketsHttpHandler"/> unless a test injects a fake. The client
    /// handles cookies and redirects itself so every hop's Set-Cookie (the login
    /// POST's session cookie arrives on a 302) is captured and persisted.</param>
    /// <param name="throttle">Request spacing; 1 request/second by default.</param>
    public AO3Client(
        string libraryDirectory,
        ICookieVault? cookieVault = null,
        string appVersion = "1.0.0",
        Uri? baseUri = null,
        HttpMessageHandler? handler = null,
        Throttle? throttle = null)
    {
        _libraryDirectory = libraryDirectory;
        _vault = cookieVault ?? CredentialStore.Shared;
        _baseUri = baseUri ?? DefaultBaseUri;
        _origin = _baseUri.GetLeftPart(UriPartial.Authority);
        _throttle = throttle ?? new Throttle(TimeSpan.FromSeconds(1));
        UserAgent = UserAgentFor(appVersion);
        _realTransport = handler is null;
        PreferHttp3 = _realTransport;
        _http = handler is null
            ? new HttpClient(CreateDefaultHandler(DefaultRequestTimeout), disposeHandler: true)
            : new HttpClient(handler, disposeHandler: false);
        _http3 = handler is null ? new HttpClient(CreateDefaultHandler(Http3ConnectTimeout), disposeHandler: true) : _http;
        _http.Timeout = Timeout.InfiniteTimeSpan; // timeouts are per attempt, below
        _http3.Timeout = Timeout.InfiniteTimeSpan;
    }

    public string UserAgent { get; }

    public static string UserAgentFor(string version) => $"Fanficly/{version} (Windows; https://github.com/yennster/fanficly)";

    /// <summary>Waits between retries; tests replace it to run instantly.</summary>
    internal Func<TimeSpan, CancellationToken, Task> Sleep { get; set; } = Task.Delay;

    /// <summary>Whether the machine has any network. Retrying while offline just
    /// burns backoff time and throttle slots, so offline failures surface at once.</summary>
    internal Func<bool> IsNetworkAvailable { get; set; } = System.Net.NetworkInformation.NetworkInterface.GetIsNetworkAvailable;

    /// <summary>Where <see cref="ExportWorkAsync"/> writes: %TEMP%\Fanficly\Exports,
    /// which Windows' storage cleanup empties.</summary>
    /// <summary>A line per request for the app's local log: method, path, status,
    /// HTTP version and time to headers. Never the query, cookies or body.</summary>
    public Action<string>? Log { get; set; }

    internal string ExportsDirectory { get; set; } = Path.Combine(Path.GetTempPath(), "Fanficly", "Exports");

    private static SocketsHttpHandler CreateDefaultHandler(TimeSpan connectTimeout) => new()
    {
        UseCookies = false,
        AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.All,
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        ConnectTimeout = connectTimeout,
    };

    public void Dispose()
    {
        _http.Dispose();
        if (!ReferenceEquals(_http3, _http)) _http3.Dispose();
    }

    // MARK: - Session

    public async Task<string> LoginAsync(string username, string password, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var loginUri = AO3Endpoints.Login(_baseUri);
        var form = await PerformRequestAsync(Get(loginUri), ct: ct).ConfigureAwait(false);
        var formHtml = Decode(form.Body, "Login page");
        var token = LoginParser.AuthenticityToken(formHtml)
            ?? throw AO3Exception.ParseFailed("authenticity_token not found");

        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var post = Post(loginUri, [
            new("utf8", "✓"),
            new("authenticity_token", token),
            new("user[login]", username),
            new("user[password]", password),
            new("user[remember_me]", "1"),
            new("commit", "Log in"),
        ], [new("Origin", _origin), new("Referer", loginUri.AbsoluteUri)]);
        var response = await PerformRequestAsync(post, ct: ct).ConfigureAwait(false);
        var respHtml = TryDecode(response.Body) ?? "";

        // Success: the response shows the logged-in user navigation (and no
        // login form, whose header links aren't a name).
        if (!LoginParser.HasLoginForm(respHtml) && LoginParser.CurrentUsername(respHtml) is { } name)
            return SignedIn(name);
        // Explicit AO3 error flash.
        if (LoginParser.DetectLoginFailure(respHtml) is { } err) throw AO3Exception.LoginFailed(err);
        // Still on the login form → credentials rejected.
        if (LoginParser.HasLoginForm(respHtml)) throw AO3Exception.LoginFailed("Incorrect username or password.");
        // Unexpected response — assume the session cookie was set anyway.
        if (SiteCookies().Any(IsAccountCookie))
        {
            // The typed text may be an email address, which no /users/ page
            // takes, so ask AO3 for the login name.
            if (await FetchLoggedInNameAsync(ct).ConfigureAwait(false) is { } loggedIn) return SignedIn(loggedIn);
            if (!username.Contains('@')) return SignedIn(username);
        }
        throw AO3Exception.LoginFailed("Couldn't confirm login. Please try again.");
    }

    private string SignedIn(string name)
    {
        _cachedUsername = name;
        lock (_cookieGate) _signedIn = true;
        PersistCookies(signingIn: true);
        return name;
    }

    /// <summary>Signs out (#145): stops saving cookies and clears the vault's copy,
    /// asks AO3 to end the session so <c>remember_user_token</c> stops working there
    /// too (once, never retried; skipped when AO3 can't be reached), then forgets
    /// AO3's cookies here. Requests still running when it starts can't bring their
    /// cookies back: their Set-Cookie headers are ignored. The generation goes up
    /// again at the end, so a request that started (or retried) while this waited
    /// on AO3, carrying the old cookies, counts as late too. Swift's
    /// <c>AO3Client.logout</c>.</summary>
    public async Task LogoutAsync()
    {
        EnsureCookiesLoaded();
        bool hadSession;
        lock (_vaultGate)
        {
            lock (_cookieGate)
            {
                _signedIn = false;
                _cookieGeneration++;
                hadSession = SiteCookiesLocked().Any(IsAccountCookie);
                _lastSavedCookies = SerializableCookie.ToJson([]);
            }
            // The username too, right away (with the saved cookies; the jar still
            // has them for AO3's logout): close the app while AO3 is being asked,
            // or let the background task's client save cookies meanwhile, and the
            // next launch still starts signed out.
            try { _vault.SetUsername(null); }
            catch (Exception) { /* AuthState clears the vault again. */ }
        }
        if (hadSession) await EndAO3SessionAsync().ConfigureAwait(false);
        lock (_cookieGate)
        {
            _cookieGeneration++;
            var keep = new CookieContainer();
            foreach (var c in _cookies.GetAllCookies().Where(c => !IsSiteCookie(c))) keep.Add(c);
            _cookies = keep;
        }
        _cachedUsername = null;
    }

    private static readonly TimeSpan LogoutTimeout = TimeSpan.FromSeconds(10);

    /// <summary>The cookies that keep an AO3 account signed in.</summary>
    private static bool IsAccountCookie(Cookie c) =>
        c.Name.Contains("user_credentials", StringComparison.Ordinal)
        || c.Name.Contains("remember_user_token", StringComparison.Ordinal);

    /// <summary>AO3's own Log Out: a DELETE to <c>/users/logout</c> (Rails'
    /// <c>_method</c> form field) with the CSRF token from any page. Best effort
    /// with short timeouts, so signing out offline doesn't wait out the usual ones.</summary>
    private async Task EndAO3SessionAsync()
    {
        try
        {
            await _throttle.WaitAsync().ConfigureAwait(false);
            var page = await PerformRequestAsync(Get(_baseUri, LogoutTimeout), maxRetries: 0).ConfigureAwait(false);
            if (TryDecode(page.Body) is not { } html || LoginParser.AuthenticityToken(html) is not { } token) return;
            await _throttle.WaitAsync().ConfigureAwait(false);
            var post = Post(new Uri(_baseUri, "/users/logout"), [
                new("_method", "delete"),
                new("authenticity_token", token),
            ], [new("Origin", _origin), new("Referer", _baseUri.AbsoluteUri)]) with { Timeout = LogoutTimeout };
            await PerformRequestAsync(post).ConfigureAwait(false);
        }
        catch (Exception e) when (e is AO3Exception or HttpRequestException or TimeoutException)
        {
            // Offline or AO3 down: signed out on this PC all the same.
        }
    }

    public async Task<string?> CurrentUsernameAsync(CancellationToken ct = default)
    {
        if (_cachedUsername is { } cached) return cached;
        return _cachedUsername = await FetchLoggedInNameAsync(ct).ConfigureAwait(false);
    }

    /// <summary>The login name in the header of AO3's home page; null for a guest
    /// page or a failed request.</summary>
    private async Task<string?> FetchLoggedInNameAsync(CancellationToken ct)
    {
        try
        {
            await _throttle.WaitAsync(ct).ConfigureAwait(false);
            var response = await PerformRequestAsync(Get(_baseUri), ct: ct).ConfigureAwait(false);
            var html = TryDecode(response.Body);
            if (html is null || LoginParser.HasLoginForm(html)) return null;
            return LoginParser.CurrentUsername(html);
        }
        catch (Exception e) when (e is AO3Exception or HttpRequestException)
        {
            return null;
        }
    }

    // MARK: - Listings

    public async Task<AO3SearchResults> SearchAsync(AO3SearchFilters filters, int page, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var uri = AO3Endpoints.Search(filters, page, _baseUri);
        // The default 30 s timeout failed searches on slow days, then retried them
        // twice for a minute-plus wait. Give search 60 s and a single retry.
        var response = await PerformRequestAsync(Get(uri, timeout: SearchRequestTimeout), maxRetries: 1, ct: ct).ConfigureAwait(false);
        return SearchResultsParser.Parse(Decode(response.Body, "Search response"));
    }

    public async Task<AO3SearchResults> FetchAuthorWorksAsync(string username, int page, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.AuthorWorks(username, page, _baseUri)), ct: ct).ConfigureAwait(false);
        // An author's works page lists works with the same `li.work.blurb` markup
        // as search, so the search parser handles it unchanged.
        return SearchResultsParser.Parse(Decode(response.Body, "Author works response"));
    }

    public async Task<AO3SearchResults> FetchBookmarksAsync(string username, int page, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.UserBookmarks(username, page, _baseUri)), ct: ct).ConfigureAwait(false);
        // The bookmarks page wraps each work in `li.bookmark.blurb` (vs.
        // `li.work.blurb` on search) but the inner blurb markup is identical.
        var html = Decode(response.Body, "Bookmarks response");
        // Signed out, AO3 still shows the public bookmarks, under its guest
        // login form; an expired session must say so, not show a partial list.
        if (EndedAtLogin(response) || LoginParser.HasLoginForm(html)) throw AO3Exception.Unauthorized();
        return SearchResultsParser.Parse(html, "li.bookmark.blurb");
    }

    public async Task<AO3SearchResults> FetchMarkedForLaterAsync(string username, int page, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.UserMarkedForLater(username, page, _baseUri)), ct: ct).ConfigureAwait(false);
        if (EndedAtLogin(response)) throw AO3Exception.Unauthorized();
        return SearchResultsParser.ParseReadings(Decode(response.Body, "Marked for Later response"));
    }

    public async Task<AO3SearchResults> FetchReadingHistoryAsync(string username, int page, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.UserReadingHistory(username, page, _baseUri)), ct: ct).ConfigureAwait(false);
        if (EndedAtLogin(response)) throw AO3Exception.Unauthorized();
        return SearchResultsParser.ParseReadings(Decode(response.Body, "History response"));
    }

    public async Task<AO3WorkPayload> FetchWorkAsync(int id, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.Work(id, _baseUri)), ct: ct).ConfigureAwait(false);
        if (EndedAtLogin(response)) throw AO3Exception.Unauthorized();
        var payload = WorkPageParser.Parse(Decode(response.Body, "Work response"), id);
        // Fail closed: saving a payload replaces the stored chapters, so a page
        // that isn't the work (an error or interstitial) must never pass as one.
        if (payload.Chapters.Count == 0) throw AO3Exception.ParseFailed("no chapters on the work page");
        return payload;
    }

    public async Task<AO3WorkChapterPage> FetchWorkChapterAsync(int id, int chapter = 1, CancellationToken ct = default)
    {
        var page = await TryFetchChapterPageAsync(id, null, ct).ConfigureAwait(false);
        // Markup we can't read: the whole work, as before.
        if (page is null || page.Payload.Chapters.Count == 0)
            return new(await FetchWorkAsync(id, ct).ConfigureAwait(false), [], IsWholeWork: true);
        // The first page names every chapter's id, so a later chapter is one
        // more small page.
        if (chapter <= 1 || page.IsWholeWork || chapter > page.ChapterIds.Count
            || page.Payload.Chapters.Any(c => c.Index == chapter))
            return page;
        var later = await TryFetchChapterPageAsync(id, page.ChapterIds[chapter - 1], ct).ConfigureAwait(false);
        return later is { Payload.Chapters.Count: > 0 } ? later : page;
    }

    /// <summary>A chapter page, or null when it isn't a work page at all (the parser
    /// fails closed); the caller then falls back. The login page still throws.</summary>
    private async Task<AO3WorkChapterPage?> TryFetchChapterPageAsync(int id, int? chapterId, CancellationToken ct)
    {
        try { return await FetchChapterPageAsync(id, chapterId, ct).ConfigureAwait(false); }
        catch (AO3Exception e) when (e.Kind == AO3ErrorKind.ParseFailed) { return null; }
    }

    private async Task<AO3WorkChapterPage> FetchChapterPageAsync(int id, int? chapterId, CancellationToken ct)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.WorkChapter(id, chapterId, _baseUri)), ct: ct).ConfigureAwait(false);
        if (EndedAtLogin(response)) throw AO3Exception.Unauthorized();
        return WorkPageParser.ParseChapterPage(Decode(response.Body, "Work response"), id);
    }

    public async Task<AO3WorkMetadata> FetchWorkMetadataAsync(int id, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.WorkPage(id, _baseUri)), ct: ct).ConfigureAwait(false);
        if (EndedAtLogin(response)) throw AO3Exception.Unauthorized();
        return WorkMetadataParser.TryParse(Decode(response.Body, "Work response"), id)
            ?? throw AO3Exception.ParseFailed("no chapter count on the work page");
    }

    /// <summary>Every subscription across all pages. AO3 paginates the index at 20
    /// per page — walk every page (each fetch throttled) or anything past the
    /// first 20 is invisible and its records get treated as stale. Any page
    /// failing throws the whole call, so a partial list can never reach the
    /// caller's delete pass. The 50-page ceiling only guards against a
    /// pagination-parse glitch turning one sync into an unbounded crawl.</summary>
    public async Task<AO3SubscriptionList> FetchSubscriptionsAsync(string username, CancellationToken ct = default)
    {
        const int maxPages = 50;
        var all = new List<AO3Subscription>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var page = 1;
        var totalPages = 1;
        while (page <= Math.Min(totalPages, maxPages))
        {
            await _throttle.WaitAsync(ct).ConfigureAwait(false);
            var uri = AO3Endpoints.UserSubscriptions(username, page, _baseUri);
            var response = await PerformRequestAsync(Get(uri), ct: ct).ConfigureAwait(false);
            var parsed = SubscriptionsParser.ParsePage(Decode(response.Body, "Subscriptions response"));
            foreach (var sub in parsed.Subscriptions)
                if (seen.Add(sub.Key)) all.Add(sub);
            totalPages = parsed.TotalPages;
            page++;
        }
        // Past the ceiling (over 1,000 subscriptions) the list is cut short, so
        // it says so: the poller then keeps the records it didn't reach.
        return new AO3SubscriptionList(all, IsComplete: totalPages <= maxPages);
    }

    // MARK: - Comments

    public async Task<AO3CommentsPage> FetchCommentsAsync(int workId, int? chapterId, int page, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(CommentsPageUri(workId, chapterId, page)), ct: ct).ConfigureAwait(false);
        return CommentsParser.ParsePage(Decode(response.Body, "Comments response"));
    }

    /// <summary>The page whose <c>?show_comments=true</c> thread we read/post against: a
    /// specific chapter when its id is known, else the work page.</summary>
    private Uri CommentsPageUri(int workId, int? chapterId, int page = 1) => chapterId is { } cid
        ? AO3Endpoints.ChapterComments(workId, cid, _baseUri, page)
        : AO3Endpoints.WorkComments(workId, _baseUri, page);

    public async Task PostCommentAsync(int workId, int? chapterId, string text, CancellationToken ct = default)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) throw AO3Exception.Rejected("The comment is empty.");

        // Load the chapter's (or work's) comment page and replay its actual
        // new-comment form: the form's hidden inputs carry the CSRF token and the
        // `comment[commentable_id]`/`[commentable_type]` that bind the comment to
        // exactly the chapter AO3 would — so we never hardcode the POST shape.
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var pageUri = CommentsPageUri(workId, chapterId);
        var page = await PerformRequestAsync(Get(pageUri), ct: ct).ConfigureAwait(false);
        var pageHtml = Decode(page.Body, "Comment page");
        var form = CommentsParser.NewCommentForm(pageHtml, _baseUri)
            ?? throw (KudosParser.IsSignedIn(pageHtml)
                ? AO3Exception.ParseFailed("comment form not found")
                : AO3Exception.Unauthorized());
        // AO3 shows its guest form (name and email) once the session has ended.
        // Posting it without them is refused, and posting as a guest isn't what a
        // signed-in reader meant.
        if (form.IsGuest) throw AO3Exception.Unauthorized();

        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var headers = new List<KeyValuePair<string, string>>
        {
            new("Referer", pageUri.AbsoluteUri),
            new("Origin", _origin),
        };
        if (form.Fields.TryGetValue("authenticity_token", out var token)) headers.Add(new("X-CSRF-Token", token));
        var fields = new Dictionary<string, string>(form.Fields, StringComparer.Ordinal)
        {
            ["comment[comment_content]"] = trimmed,
            ["commit"] = "Comment",
        };
        var response = await PerformRequestAsync(Post(form.Action, fields.ToList(), headers), ct: ct).ConfigureAwait(false);
        if (response.Status >= 400) throw AO3Exception.Http(response.Status);
        // AO3 answers a refused comment with a 200 page (or a redirect the client
        // follows), never an error status, so judge by the page: reading a refusal
        // as posted would clear the draft.
        var outcome = CommentsParser.PostOutcome(TryDecode(response.Body) ?? "", response.FinalUri, form.Action);
        switch (outcome.Status)
        {
            case CommentPostStatus.SignedOut: throw AO3Exception.Unauthorized();
            case CommentPostStatus.Rejected: throw AO3Exception.Rejected(outcome.Message ?? CommentPostOutcome.Unconfirmed);
        }
    }

    // MARK: - Browse & popular

    public async Task<IReadOnlyList<BrowseFandom>> FetchFandomsInCategoryAsync(string categoryName, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.MediaFandoms(categoryName, _baseUri)), ct: ct).ConfigureAwait(false);
        return MediaCategoryParser.Parse(Decode(response.Body, "Media category response"));
    }

    /// <summary>The works-filter facet sidebar for a tag (<c>/tags/&lt;tag&gt;/works</c>) — its
    /// top relationships/characters/freeforms with counts.</summary>
    private async Task<AO3WorkFilters> FetchWorkFiltersAsync(string tagName, CancellationToken ct)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.TagWorks(tagName, _baseUri)), ct: ct).ConfigureAwait(false);
        return WorkFiltersParser.Parse(Decode(response.Body, "Tag works response"));
    }

    /// <summary>Builds a live popular snapshot: fandoms ranked by AO3's media-page
    /// work counts, then ships/characters aggregated from the facet sidebars of
    /// the top few fandoms. Each list falls back to the curated
    /// <see cref="PopularTags"/> seed when AO3 yields nothing (offline / markup
    /// drift), so the tab is never empty. ~10–13 throttled requests — meant to run
    /// in the background and be cached for a day.</summary>
    public async Task<PopularSnapshot> FetchPopularSnapshotAsync(CancellationToken ct = default)
    {
        var fandomCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var category in FandomCatalog.All)
        {
            IReadOnlyList<BrowseFandom> fandoms;
            try { fandoms = await FetchFandomsInCategoryAsync(category.AO3CanonicalName, ct).ConfigureAwait(false); }
            catch (Exception e) when (!IsCallerCancellation(e, ct)) { continue; }
            foreach (var fandom in fandoms)
            {
                if ((fandom.WorkCount ?? 0) <= 0) continue;
                fandomCounts[fandom.CanonicalName] = Math.Max(fandomCounts.GetValueOrDefault(fandom.CanonicalName), fandom.WorkCount ?? 0);
            }
        }
        var topFandoms = Ranked(fandomCounts);

        var shipCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        var charCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        // Aggregate ship/character facets from the top few fandoms — enough
        // fandoms to surface ~30 unique ships/characters for the Popular lists.
        foreach (var fandom in topFandoms.Take(5))
        {
            AO3WorkFilters filters;
            try { filters = await FetchWorkFiltersAsync(fandom, ct).ConfigureAwait(false); }
            catch (Exception e) when (!IsCallerCancellation(e, ct)) { continue; }
            foreach (var r in filters.Relationships) shipCounts[r.Name] = shipCounts.GetValueOrDefault(r.Name) + Math.Max(r.Count, 1);
            foreach (var c in filters.Characters) charCounts[c.Name] = charCounts.GetValueOrDefault(c.Name) + Math.Max(c.Count, 1);
        }
        var topShips = Ranked(shipCounts);
        var topChars = Ranked(charCounts);

        return new PopularSnapshot(
            topFandoms.Count == 0 ? PopularTags.Fandoms : topFandoms.Take(30).ToList(),
            topShips.Count == 0 ? PopularTags.Ships : topShips.Take(30).ToList(),
            topChars.Count == 0 ? PopularTags.Characters : topChars.Take(30).ToList(),
            DateTimeOffset.Now);

        static List<string> Ranked(Dictionary<string, int> counts) =>
            counts.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => kv.Key).ToList();
    }

    // MARK: - Autocomplete

    public async Task<IReadOnlyList<string>> AutocompleteAsync(AO3AutocompleteField field, string term, CancellationToken ct = default)
    {
        var trimmed = term.TrimSwiftWhitespaces();
        if (trimmed.Length == 0) return [];
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var uri = AO3Endpoints.Autocomplete(field.RawValue(), trimmed, _baseUri);
        // The default Accept is text/html, but AO3's autocomplete only serves JSON
        // — Rails content-negotiation 404s an HTML request.
        var request = Get(uri, accept: "application/json, text/javascript, */*; q=0.01",
            headers: [new("X-Requested-With", "XMLHttpRequest")]);
        var response = await PerformRequestAsync(request, ct: ct).ConfigureAwait(false);
        return DecodeAutocomplete(response.Body);
    }

    /// <summary>Reads AO3's <c>[{id, name}]</c> autocomplete JSON: each item's name,
    /// else its id. Anything malformed reads as no suggestions.</summary>
    internal static IReadOnlyList<string> DecodeAutocomplete(byte[] body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return [];
            var result = new List<string>();
            foreach (var item in doc.RootElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) continue;
                if ((StringProp(item, "name") ?? StringProp(item, "id")) is { } value) result.Add(value);
            }
            return result;
        }
        catch (JsonException)
        {
            return [];
        }

        static string? StringProp(JsonElement o, string key) =>
            o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    }

    // MARK: - Downloads

    public async Task<string> DownloadEpubAsync(int workId, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.Epub(workId, _baseUri)), ct: ct).ConfigureAwait(false);
        EnsureDownloadedFile(response, WorkExportFormat.Epub);
        Directory.CreateDirectory(_libraryDirectory);
        var path = Path.Combine(_libraryDirectory, $"{workId}.epub");
        await WriteAtomicallyAsync(path, response.Body, ct).ConfigureAwait(false);
        return path;
    }

    public async Task<string> ExportWorkAsync(int workId, WorkExportFormat format, string filename, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.Download(workId, format, _baseUri)), ct: ct).ConfigureAwait(false);
        EnsureDownloadedFile(response, format);
        Directory.CreateDirectory(ExportsDirectory);
        var safe = SanitizeFilename(filename.Length == 0 ? $"work-{workId}" : filename);
        var path = Path.Combine(ExportsDirectory, $"{safe}.{format.Ext()}");
        if (File.Exists(path)) File.Delete(path);
        await WriteAtomicallyAsync(path, response.Body, ct).ConfigureAwait(false);
        return path;
    }

    /// <summary>A download is really the file, not a page: a work for signed-in
    /// users only, fetched signed out, redirects to the login page (a 200), which
    /// would otherwise be saved as the book and shown as Downloaded.</summary>
    internal static void EnsureDownloadedFile(Response response, WorkExportFormat format)
    {
        if (EndedAtLogin(response)) throw AO3Exception.Unauthorized();
        if (format == WorkExportFormat.Html) return;
        // EPUB/AZW3 are zips, MOBI and PDF binary; none starts with markup.
        var body = response.Body;
        var i = body.Length >= 3 && body[0] == 0xEF && body[1] == 0xBB && body[2] == 0xBF ? 3 : 0;
        while (i < body.Length && body[i] is (byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n') i++;
        if (body.Length == 0 || (i < body.Length && body[i] == (byte)'<'))
            throw AO3Exception.ParseFailed($"AO3 sent a web page instead of the {format.Ext().ToUpperInvariant()} file");
    }

    /// <summary>AO3 answers a request it wants a signed-in user for by redirecting
    /// to its login page, with a 200.</summary>
    private static bool EndedAtLogin(Response response) =>
        response.FinalUri.AbsolutePath.StartsWith("/users/login", StringComparison.Ordinal);

    /// <summary>The page's error message (AO3's error flash or form errors), if any.</summary>
    private static string? PageError(Response response)
    {
        if (TryDecode(response.Body) is not { } html) return null;
        var doc = HtmlDom.Parse(html);
        var text = string.Join(" ", doc.Select("#error li, div.flash.error, div.error li")
            .Select(e => e.Text().TrimSwiftWhitespaces()).Where(t => t.Length > 0).Distinct());
        return text.Length > 0 ? text : null;
    }

    /// <summary>Replaces characters that can't appear in a file name with "-", keeps
    /// the first 80 characters, and trims spaces.</summary>
    internal static string SanitizeFilename(string name)
    {
        const string invalid = "/\\?%*|\"<>:";
        var cleaned = new string(name.Select(c => invalid.Contains(c) ? '-' : c).ToArray());
        var info = new StringInfo(cleaned);
        if (info.LengthInTextElements > 80) cleaned = info.SubstringByTextElements(0, 80);
        return cleaned.TrimSwiftWhitespaces();
    }

    private static async Task WriteAtomicallyAsync(string path, byte[] data, CancellationToken ct)
    {
        var tmp = path + ".tmp";
        await File.WriteAllBytesAsync(tmp, data, ct).ConfigureAwait(false);
        File.Move(tmp, path, overwrite: true);
    }

    // MARK: - Subscribe

    public async Task SubscribeToWorkAsync(int workId, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var pageUri = AO3Endpoints.WorkPage(workId, _baseUri);
        var page = await PerformRequestAsync(Get(pageUri), ct: ct).ConfigureAwait(false);
        var token = (TryDecode(page.Body) is { } pageHtml ? LoginParser.AuthenticityToken(pageHtml) : null)
            ?? throw AO3Exception.ParseFailed("authenticity_token not found on work page");

        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var request = Post(AO3Endpoints.WorkSubscriptions(workId, _baseUri), [
            new("authenticity_token", token),
            new("subscription[subscribable_id]", workId.ToString(CultureInfo.InvariantCulture)),
            new("subscription[subscribable_type]", "Work"),
        ], [new("Referer", pageUri.AbsoluteUri), new("Origin", _origin), new("X-CSRF-Token", token)]);
        var response = await PerformRequestAsync(request, ct: ct).ConfigureAwait(false);
        // 422 is Rails refusing the security token: not subscribed.
        if (response.Status >= 400) throw AO3Exception.Http(response.Status);
        if (EndedAtLogin(response)) throw AO3Exception.Unauthorized();
        // Both outcomes redirect back to the work; a refusal carries an error
        // flash. Already subscribed is what we wanted.
        if (PageError(response) is { } error && !error.Contains("already", StringComparison.OrdinalIgnoreCase))
            throw AO3Exception.Rejected(error);
    }

    // MARK: - Kudos

    public async Task<KudosOutcome> LeaveKudosAsync(int workId, CancellationToken ct = default)
    {
        // Read the work page first: it carries the kudos form (absent on your own
        // work or one whose creator blocked you) and shows whether the session is
        // still signed in. AO3 takes guest kudos too, so posting with an expired
        // cookie would silently leave one as a guest.
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        // The first page is enough for the form and the greeting: no view_full_work.
        var pageUri = AO3Endpoints.WorkChapter(workId, null, _baseUri);
        var page = await PerformRequestAsync(Get(pageUri), ct: ct).ConfigureAwait(false);
        if (EndedAtLogin(page)) throw AO3Exception.Unauthorized();
        var pageHtml = Decode(page.Body, "Work page");
        if (!KudosParser.IsSignedIn(pageHtml)) throw AO3Exception.Unauthorized();
        var fields = KudosParser.FormFields(pageHtml)
            ?? throw AO3Exception.Rejected("AO3 doesn't offer kudos on this work. It may be your own, or its creator may have blocked you.");
        // The page-wide token (<meta name="csrf-token">), as comments and subscribe
        // use. AO3 has Rails' per-form tokens on, so the form's own token only
        // validates for a POST to /kudos, not /kudos.js; AO3's script gets through
        // because it also sends the meta token.
        var token = LoginParser.AuthenticityToken(pageHtml)
            ?? throw AO3Exception.ParseFailed("authenticity_token not found on work page");
        fields["authenticity_token"] = token;

        // Post the form the way AO3's own script does (/kudos.js): it answers 201
        // on success and 422 with {"error_message": …} otherwise, instead of a
        // redirect whose flash we'd have to scrape.
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var headers = new List<KeyValuePair<string, string>>
        {
            new("Referer", pageUri.AbsoluteUri),
            new("Origin", _origin),
            new("X-Requested-With", "XMLHttpRequest"),
            new("X-CSRF-Token", token),
        };
        var response = await PerformRequestAsync(Post(AO3Endpoints.Kudos(_baseUri), fields.ToList(), headers),
            ct: ct, passing: [422]).ConfigureAwait(false);
        switch (response.Status)
        {
            case 201:
                return KudosOutcome.Left;
            case 422:
                var body = TryDecode(response.Body) ?? "";
                // A refused token (the session ended between the two requests)
                // answers {"errors": {"auth_error": …}} instead.
                if (KudosParser.IsAuthError(body)) throw AO3Exception.Unauthorized();
                var message = KudosParser.ErrorMessage(body) ?? "";
                if (KudosParser.IsAlreadyLeft(message)) return KudosOutcome.AlreadyLeft;
                throw AO3Exception.Rejected(message);
            default:
                // Anything else (a maintenance page, a proxy) isn't AO3's kudos
                // answer, so it mustn't be remembered as a kudo.
                throw AO3Exception.Rejected($"AO3 gave an unexpected answer (HTTP {response.Status}), so the kudos may not have been left. Trying again is safe.");
        }
    }

    // MARK: - Bookmark

    public async Task<AO3BookmarkForm> FetchBookmarkFormAsync(int workId, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.WorkPage(workId, _baseUri)), ct: ct).ConfigureAwait(false);
        if (EndedAtLogin(response)) throw AO3Exception.Unauthorized();
        var html = Decode(response.Body, "Work response");
        if (BookmarkFormParser.Parse(html, _baseUri) is { } form) return form;
        // AO3 only renders the form for a signed-in user; a page without it
        // that isn't signed out is an error page or changed markup.
        if (LoginParser.HasLoginForm(html) || LoginParser.CurrentUsername(html) is null) throw AO3Exception.Unauthorized();
        throw AO3Exception.ParseFailed("bookmark form not found on the work page");
    }

    public async Task SaveBookmarkAsync(AO3BookmarkForm form, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var headers = new List<KeyValuePair<string, string>>
        {
            new("Referer", form.Action.AbsoluteUri),
            new("Origin", _origin),
        };
        if (form.HiddenFields.TryGetValue("authenticity_token", out var token)) headers.Add(new("X-CSRF-Token", token));
        var response = await PerformRequestAsync(Post(form.Action, form.PostFields.ToList(), headers), ct: ct).ConfigureAwait(false);
        // 422 is Rails refusing the security token: not saved.
        if (response.Status >= 400) throw AO3Exception.Http(response.Status);
        // AO3 redirects a saved bookmark (new or updated) to `/bookmarks/<id>`.
        // A rejected one re-renders the form with an `#error` list, an expired
        // session lands on the login form, and a refused account or pseud is
        // redirected elsewhere with an error flash. Judge by the final page.
        var html = TryDecode(response.Body) ?? "";
        if (EndedAtLogin(response) || LoginParser.HasLoginForm(html)) throw AO3Exception.Unauthorized();
        // A failed update re-renders on `/bookmarks/<id>` too, so form errors
        // come first; a flash on the saved bookmark's page (say, a collection
        // it couldn't join) doesn't undo the save.
        if (BookmarkFormParser.SaveErrors(html) is { Count: > 0 } errors)
            throw AO3Exception.Rejected(string.Join(" ", errors));
        if (!BookmarkFormParser.IsBookmarkPage(response.FinalUri.AbsolutePath))
            throw AO3Exception.Rejected(BookmarkFormParser.FlashErrors(html) is { Count: > 0 } flash
                ? string.Join(" ", flash)
                : "AO3 didn't save the bookmark.");
    }

    // MARK: - Transport

    /// <summary>One request, described so it can be re-sent on a retry or a redirect.</summary>
    internal sealed record RequestSpec(
        HttpMethod Method,
        Uri Uri,
        string Accept,
        IReadOnlyList<KeyValuePair<string, string>> Headers,
        string? FormBody,
        TimeSpan Timeout);

    /// <summary><paramref name="CfMitigated"/>: the response carried Cloudflare's
    /// <c>cf-mitigated</c> header (its bot challenge answered instead of AO3).</summary>
    internal sealed record Response(int Status, byte[] Body, TimeSpan? RetryAfter, Uri FinalUri, bool CfMitigated = false);

    private const string DefaultAccept = "text/html,application/xhtml+xml";

    private static RequestSpec Get(Uri uri, TimeSpan? timeout = null, string accept = DefaultAccept,
        IReadOnlyList<KeyValuePair<string, string>>? headers = null) =>
        new(HttpMethod.Get, uri, accept, headers ?? [], null, timeout ?? DefaultRequestTimeout);

    private static RequestSpec Post(Uri uri, IReadOnlyList<KeyValuePair<string, string>> form,
        IReadOnlyList<KeyValuePair<string, string>> headers) =>
        new(HttpMethod.Post, uri, DefaultAccept, headers, EncodeForm(form), DefaultRequestTimeout);

    /// <summary>Sends <paramref name="spec"/>, retrying transient failures. Only idempotent
    /// reads are retried: replaying a POST (login, comment, subscribe) after a
    /// timeout could double-submit — a comment that actually landed but whose
    /// response was lost — so those surface the error instead.</summary>
    /// <remarks><paramref name="passing"/> lists error statuses the caller reads itself
    /// (the kudos POST's 422 carries AO3's reason) instead of having them thrown.</remarks>
    internal async Task<Response> PerformRequestAsync(RequestSpec spec, int maxRetries = MaxRetries, CancellationToken ct = default,
        IReadOnlyCollection<int>? passing = null)
    {
        EnsureCookiesLoaded();
        for (var attempt = 0; ; attempt++)
        {
            var canRetry = spec.Method == HttpMethod.Get && attempt < maxRetries;
            Response response;
            try
            {
                response = await SendFollowingRedirectsAsync(spec, ct).ConfigureAwait(false);
            }
            catch (Exception e) when (!IsCallerCancellation(e, ct) && e is not AO3Exception)
            {
                if (!(canRetry && IsTransient(e))) throw AO3Exception.Network(e.Message, e);
                // Timeouts and dropped connections are often transient (a slow AO3
                // response, a network blip) — retry with backoff instead of failing
                // the whole load.
                await Sleep(Backoff(attempt), ct).ConfigureAwait(false);
                await _throttle.WaitAsync(ct).ConfigureAwait(false);
                continue;
            }

            if (passing?.Contains(response.Status) == true) return response;
            switch (response.Status)
            {
                case >= 200 and < 300 or 302:
                    return response;
                case 401:
                    throw AO3Exception.Unauthorized();
                case 403:
                    throw ForbiddenError(response);
                case 429:
                    // Rate-limited. Only retry when AO3's own Retry-After says the
                    // window is short enough to politely wait out; otherwise fail
                    // fast. Blind backoff would send more requests into a window the
                    // server just declared closed — real 429s for a client already
                    // throttled to 1 req/s mean a clamp-down much longer than any
                    // in-request backoff.
                    if (canRetry && response.RetryAfter is { } retryAfter && retryAfter <= MaxPoliteRetryAfter)
                    {
                        await Sleep(retryAfter, ct).ConfigureAwait(false);
                        await _throttle.WaitAsync(ct).ConfigureAwait(false);
                        continue;
                    }
                    throw AO3Exception.RateLimited();
                case var status when AO3Exception.IsServerUnavailable(status) && canRetry:
                    // AO3 overloaded or restarting (503), or Cloudflare unable to
                    // reach it (502/504, 520–526). These come and go, so a page load
                    // tries again after a longer, polite pause than a network blip.
                    await Sleep(ServerBackoff(attempt), ct).ConfigureAwait(false);
                    await _throttle.WaitAsync(ct).ConfigureAwait(false);
                    continue;
                default:
                    throw AO3Exception.Http(response.Status);
            }
        }
    }

    /// <summary>What a 403 means (Swift's <c>AO3Client.forbiddenError</c>). Only AO3's
    /// login page (or a redirect that ended there) is a sign-in problem. Cloudflare's bot
    /// challenge and block pages answer 403 to signed-out readers too, and AO3's own
    /// "forbidden" pages don't change with a new session, so telling the reader to sign
    /// in again (or marking their session expired) would just fail the same way. AO3 is
    /// always served through Cloudflare, so <c>Server: cloudflare</c> alone can't tell the
    /// two apart: the <c>cf-mitigated</c> header and the challenge page's markup can.</summary>
    internal static AO3Exception ForbiddenError(Response response)
    {
        // Cloudflare first: it can challenge the login page itself (signing in, or a
        // stale session's redirect there).
        if (response.CfMitigated) return AO3Exception.BlockedByProtection();
        var html = Encoding.UTF8.GetString(response.Body);
        if (CloudflareMarkers.Any(m => html.Contains(m, StringComparison.OrdinalIgnoreCase)))
            return AO3Exception.BlockedByProtection();
        var path = response.FinalUri.AbsolutePath;
        if (path.StartsWith("/users/login", StringComparison.Ordinal) || path.StartsWith("/auth_error", StringComparison.Ordinal))
            return AO3Exception.Unauthorized();
        if (AO3PageCheck.IsLoginPage(HtmlDom.Parse(html))) return AO3Exception.Unauthorized();
        return AO3Exception.Forbidden();
    }

    /// <summary>Markup only Cloudflare's challenge ("Just a moment…") and block
    /// ("Attention Required!", error 1020) pages carry. Not
    /// <c>/cdn-cgi/challenge-platform/</c>: Cloudflare injects that script into ordinary
    /// pages too.</summary>
    private static readonly string[] CloudflareMarkers =
        ["_cf_chl_opt", "cf-error-details", "<title>Just a moment", "Attention Required! | Cloudflare"];

    /// <summary>Exponential backoff before a retry: ~0.5 s, then ~1 s.</summary>
    internal static TimeSpan Backoff(int attempt) => TimeSpan.FromSeconds(0.5 * Math.Pow(2, attempt));

    /// <summary>Backoff before retrying a page AO3 couldn't serve: 2 s, then 5 s.</summary>
    internal static TimeSpan ServerBackoff(int attempt) => TimeSpan.FromSeconds(attempt == 0 ? 2 : 5);

    private static bool IsCallerCancellation(Exception e, CancellationToken ct) =>
        e is OperationCanceledException && ct.IsCancellationRequested;

    /// <summary>Failures worth retrying — network hiccups rather than permanent
    /// errors: timeouts, connection failures and resets, DNS, TLS handshakes.
    /// Never while offline.</summary>
    private bool IsTransient(Exception e)
    {
        if (!IsNetworkAvailable()) return false;
        if (FindSocketError(e) is SocketError.NetworkDown or SocketError.NetworkUnreachable) return false;
        return e switch
        {
            TimeoutException => true,
            HttpRequestException { HttpRequestError: HttpRequestError.NameResolutionError
                or HttpRequestError.ConnectionError
                or HttpRequestError.SecureConnectionError
                or HttpRequestError.ResponseEnded } => true,
            HttpIOException { HttpRequestError: HttpRequestError.ResponseEnded } => true,
            _ => FindSocketError(e) is SocketError.ConnectionReset or SocketError.ConnectionAborted
                or SocketError.TimedOut or SocketError.HostNotFound or SocketError.TryAgain
                or SocketError.ConnectionRefused or SocketError.HostUnreachable,
        };
    }

    private static string Elapsed(long started) =>
        $"{System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalSeconds:0.00} s";

    private static SocketError? FindSocketError(Exception? e)
    {
        for (; e is not null; e = e.InnerException)
            if (e is SocketException se) return se.SocketErrorCode;
        return null;
    }

    private readonly bool _realTransport;
    private int _transportLogged;
    private int _altSvcLogged;
    private long _http3OffUntil;

    /// <summary>Ask for HTTP/3 from the first request instead of waiting for AO3's
    /// Alt-Svc: AO3's edge answers HTTP/2 slowly or with 503/525s, so even the one
    /// request .NET would send before upgrading lands in the slow lane. On by
    /// default for the real transport; tests turn it on to cover the fallback.</summary>
    internal bool PreferHttp3 { get; set; }

    /// <summary>Says once per run what can keep HTTP/3 away: .NET never uses
    /// it through a proxy (the system's, or HTTPS_PROXY), nor where QUIC is
    /// missing. The proxy's host and port only, never its credentials.</summary>
    private void LogTransportOnce(Uri uri)
    {
        if (!_realTransport || Log is not { } log || Interlocked.Exchange(ref _transportLogged, 1) != 0) return;
        string proxy;
        try
        {
            proxy = HttpClient.DefaultProxy.GetProxy(uri) is { } p && !HttpClient.DefaultProxy.IsBypassed(uri)
                ? $"through a proxy at {p.Host}:{p.Port}, so no HTTP/3"
                : "with no proxy";
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            proxy = $"(couldn't read the proxy settings: {e.Message})";
        }
        var quic = (OperatingSystem.IsWindows() || OperatingSystem.IsLinux() || OperatingSystem.IsMacOS())
                   && System.Net.Quic.QuicConnection.IsSupported;
        log($"Connecting to {uri.Host} {proxy}; QUIC (HTTP/3) {(quic ? "available" : "not available")}");
    }

    /// <summary>How long connecting over QUIC may take, so a network that silently
    /// drops UDP costs seconds rather than the full timeout. Only the connect: once
    /// connected, a request waits its own timeout, since AO3 search often takes
    /// 20–30 s to start answering and cutting it off would make AO3 render it twice
    /// (#147).</summary>
    private static readonly TimeSpan Http3ConnectTimeout = TimeSpan.FromSeconds(5);

    /// <summary>How long HTTP/2 is used after HTTP/3 fails, before HTTP/3 is tried
    /// again: the failure may have been the network dropping, not UDP being blocked.</summary>
    private static readonly TimeSpan Http3RetryAfter = TimeSpan.FromMinutes(10);

    private bool Http3Off => Environment.TickCount64 < Volatile.Read(ref _http3OffUntil);

    private void TurnHttp3Off() =>
        Volatile.Write(ref _http3OffUntil, Environment.TickCount64 + (long)Http3RetryAfter.TotalMilliseconds);

    /// <summary>HTTP/3 couldn't connect: QUIC missing or blocked, a proxy, or HTTP/3
    /// off in the runtime.</summary>
    private static bool IsHttp3ConnectFailure(HttpRequestException e) =>
        e.HttpRequestError is HttpRequestError.ConnectionError or HttpRequestError.SecureConnectionError
            or HttpRequestError.VersionNegotiationError;

    /// <summary>Whether the request that failed over HTTP/3 may go again over HTTP/2.
    /// A GET may. A POST only when HTTP/3 was never on offer (version negotiation):
    /// a QUIC connection lost after the stream went out can surface as a connection
    /// error too, and sending a comment or a login again could post it twice.</summary>
    private static bool CanResendOverHttp2(HttpMethod method, HttpRequestException e) =>
        method == HttpMethod.Get || e.HttpRequestError is HttpRequestError.VersionNegotiationError;

    /// <summary>The QUIC connect ran past <see cref="Http3ConnectTimeout"/>: UDP
    /// silently dropped. SocketsHttpHandler reports that as a cancellation wrapping
    /// a <see cref="TimeoutException"/>, not an <see cref="HttpRequestException"/>.
    /// No connection existed, so nothing went out and even a POST can go again.</summary>
    private static bool IsConnectTimeout(OperationCanceledException e) => e.InnerException is TimeoutException;

    /// <summary>Logs once what AO3 advertised on the first answer that wasn't
    /// HTTP/3, since .NET only tries HTTP/3 after an Alt-Svc offering h3.</summary>
    private void NoteAltSvc(Uri uri, HttpResponseMessage response)
    {
        if (!_realTransport || response.Version.Major >= 3) return;
        var altSvc = response.Headers.TryGetValues("Alt-Svc", out var values) ? string.Join(", ", values) : null;
        if (Interlocked.Exchange(ref _altSvcLogged, 1) != 0) return;
        Log?.Invoke(altSvc is null ? $"{uri.Host} sent no Alt-Svc header" : $"{uri.Host} advertises Alt-Svc: {altSvc}");
    }

    private static string ExceptionChain(Exception e)
    {
        var parts = new List<string>();
        for (var x = e; x is not null; x = x.InnerException) parts.Add($"{x.GetType().Name}: {x.Message}");
        return string.Join(" → ", parts);
    }

    private async Task<Response> SendFollowingRedirectsAsync(RequestSpec spec, CancellationToken ct)
    {
        using var resourceCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        resourceCts.CancelAfter(ResourceTimeout);
        var method = spec.Method;
        var uri = spec.Uri;
        var body = spec.FormBody;
        int generation;
        lock (_cookieGate) generation = _cookieGeneration;
        LogTransportOnce(uri);
        var useHttp2 = false;
        for (var hop = 0; ; hop++)
        {
            // HTTP/3, as URLSession and browsers use: AO3's Cloudflare edge answered
            // HTTP/1.1 and HTTP/2 clients far slower, or with 503/525s, while HTTP/3
            // got the same pages in under a second. With PreferHttp3 it's asked for
            // outright from the first request; where it can't connect (Windows 10,
            // a proxy, UDP blocked) a GET goes again over HTTP/2 in its own throttle
            // slot, and so do the next 10 minutes of requests.
            using var request = new HttpRequestMessage(method, uri)
            {
                Version = HttpVersion.Version30,
                VersionPolicy = HttpVersionPolicy.RequestVersionOrLower,
            };
            request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
            request.Headers.TryAddWithoutValidation("Accept", spec.Accept);
            request.Headers.TryAddWithoutValidation("Accept-Language", "en-US,en;q=0.9");
            foreach (var (name, value) in spec.Headers) request.Headers.TryAddWithoutValidation(name, value);
            var cookieHeader = CookieHeader(uri);
            if (cookieHeader.Length > 0) request.Headers.TryAddWithoutValidation("Cookie", cookieHeader);
            if (body is not null)
            {
                request.Content = new ByteArrayContent(Encoding.UTF8.GetBytes(body));
                request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/x-www-form-urlencoded");
            }

            var http3Only = PreferHttp3 && !useHttp2 && !Http3Off;
            if (http3Only)
            {
                request.VersionPolicy = HttpVersionPolicy.RequestVersionExact;
            }
            else if (PreferHttp3)
            {
                request.Version = HttpVersion.Version20;
            }

            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(resourceCts.Token);
            timeoutCts.CancelAfter(spec.Timeout);
            HttpResponseMessage response;
            var started = System.Diagnostics.Stopwatch.GetTimestamp();
            try
            {
                response = await (http3Only ? _http3 : _http).SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeoutCts.Token).ConfigureAwait(false);
            }
            catch (HttpRequestException e) when (http3Only && !ct.IsCancellationRequested && IsHttp3ConnectFailure(e))
            {
                TurnHttp3Off();
                var resend = CanResendOverHttp2(method, e);
                Log?.Invoke($"HTTP/3 to {uri.Host} failed after {Elapsed(started)}, so HTTP/2 for the next 10 minutes"
                            + $"{(resend ? "" : $"; the {method} isn't sent again")}: {ExceptionChain(e)}");
                if (!resend) throw;
                useHttp2 = true;
                hop--;
                // The resend is a request of its own, so it takes its own slot.
                await _throttle.WaitAsync(ct).ConfigureAwait(false);
                continue;
            }
            catch (OperationCanceledException e) when (http3Only && !ct.IsCancellationRequested
                                                       && !timeoutCts.IsCancellationRequested && IsConnectTimeout(e))
            {
                TurnHttp3Off();
                Log?.Invoke($"HTTP/3 to {uri.Host} couldn't connect in {Elapsed(started)}, so HTTP/2 for the next 10 minutes: {ExceptionChain(e)}");
                useHttp2 = true;
                hop--;
                await _throttle.WaitAsync(ct).ConfigureAwait(false);
                continue;
            }
            catch (OperationCanceledException e) when (!ct.IsCancellationRequested)
            {
                Log?.Invoke($"{method} {uri.AbsolutePath} timed out after {Elapsed(started)}");
                throw new TimeoutException("The request timed out.", e);
            }
            catch (HttpRequestException e)
            {
                Log?.Invoke($"{method} {uri.AbsolutePath} failed after {Elapsed(started)}: {e.Message}");
                throw;
            }
            // Path only: queries can hold search terms, and nothing here is a secret.
            Log?.Invoke($"{method} {uri.AbsolutePath} → {(int)response.StatusCode} over HTTP/{response.Version} in {Elapsed(started)}");
            NoteAltSvc(uri, response);

            using (response)
            {
                StoreCookies(uri, response, generation);
                var status = (int)response.StatusCode;
                if (status is 301 or 302 or 303 or 307 or 308 && hop < MaxRedirects && response.Headers.Location is { } location)
                {
                    uri = location.IsAbsoluteUri ? location : new Uri(uri, location);
                    // Like a browser (and URLSession): 303 always, and 301/302 after a
                    // POST, continue as a GET without the body.
                    if (status == 303 || (status is 301 or 302 && method == HttpMethod.Post))
                    {
                        method = HttpMethod.Get;
                        body = null;
                    }
                    continue;
                }

                byte[] data;
                try
                {
                    data = await response.Content.ReadAsByteArrayAsync(resourceCts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException e) when (!ct.IsCancellationRequested)
                {
                    throw new TimeoutException("The request timed out.", e);
                }
                return new Response(status, data, RetryAfterSeconds(response), uri, response.Headers.Contains("cf-mitigated"));
            }
        }
    }

    /// <summary>A 429's Retry-After in its delta-seconds form; the HTTP-date form
    /// reads as null, which callers treat as "don't retry".</summary>
    private static TimeSpan? RetryAfterSeconds(HttpResponseMessage response)
    {
        if (!response.Headers.TryGetValues("Retry-After", out var values)) return null;
        var raw = values.FirstOrDefault()?.Trim();
        if (raw is null || !double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds)
            || !double.IsFinite(seconds) || seconds < 0)
            return null;
        return TimeSpan.FromSeconds(seconds);
    }

    // MARK: - Cookies

    /// <summary>Puts the saved session in the jar before the first request, when a
    /// username is stored (signed in).</summary>
    private void EnsureCookiesLoaded()
    {
        lock (_cookieGate)
        {
            if (_cookiesLoaded) return;
            _cookiesLoaded = true;
            _signedIn = StoredUsername() is not null;
            IReadOnlyList<SerializableCookie> saved;
            try { saved = _signedIn ? _vault.LoadCookies() : []; }
            catch (Exception) { saved = []; }
            foreach (var c in saved)
            {
                try { _cookies.Add(c.ToCookie()); }
                catch (CookieException) { }
            }
            _lastSavedCookies = SerializableCookie.ToJson(SiteCookiesLocked().Select(SerializableCookie.FromCookie));
        }
    }

    private string CookieHeader(Uri uri)
    {
        lock (_cookieGate) return _cookies.GetCookieHeader(uri);
    }

    private string? StoredUsername()
    {
        try { return _vault.StoredUsername(); }
        catch (Exception) { return null; }
    }

    /// <summary>Takes a response's cookies, unless the request went out before the
    /// last logout: those belong to the session it ended.</summary>
    private void StoreCookies(Uri uri, HttpResponseMessage response, int generation)
    {
        if (!response.Headers.TryGetValues("Set-Cookie", out var values)) return;
        lock (_cookieGate)
        {
            if (generation != _cookieGeneration) return;
            foreach (var value in values)
            {
                try { _cookies.SetCookies(uri, value); }
                catch (CookieException) { }
            }
        }
        PersistCookies();
    }

    /// <summary>Saves the site's cookies to the vault when they changed and the
    /// reader is signed in, so the session survives a restart. Away from a sign-in
    /// it also needs a username in the vault: the app may have signed out while
    /// the background task's client was polling.</summary>
    private void PersistCookies(bool signingIn = false)
    {
        lock (_vaultGate)
        {
            List<SerializableCookie> snapshot;
            string json;
            lock (_cookieGate)
            {
                if (!_signedIn) return;
                snapshot = SiteCookiesLocked().Select(SerializableCookie.FromCookie).ToList();
                json = SerializableCookie.ToJson(snapshot);
                if (json == _lastSavedCookies) return;
            }
            // Outside the cookie lock: a file read and a DPAPI decrypt.
            if (!signingIn && StoredUsername() is null) return;
            lock (_cookieGate)
            {
                // Logout can't run meanwhile (it takes _vaultGate first).
                _lastSavedCookies = json;
            }
            try { _vault.SaveCookies(snapshot); }
            catch (Exception) { /* A vault failure must not fail the request. */ }
        }
    }

    private List<Cookie> SiteCookies()
    {
        lock (_cookieGate) return SiteCookiesLocked();
    }

    private List<Cookie> SiteCookiesLocked() => _cookies.GetAllCookies().Where(c => !c.Expired && IsSiteCookie(c)).ToList();

    private bool IsSiteCookie(Cookie c)
    {
        var domain = c.Domain.TrimStart('.');
        var host = _baseUri.Host;
        return host.Equals(domain, StringComparison.OrdinalIgnoreCase)
            || host.EndsWith("." + domain, StringComparison.OrdinalIgnoreCase);
    }

    // MARK: - Helpers

    private static string Decode(byte[] data, string what)
    {
        return TryDecode(data) ?? throw AO3Exception.ParseFailed($"{what} not UTF-8");
    }

    private static string? TryDecode(byte[] data)
    {
        try { return StrictUtf8.GetString(data); }
        catch (DecoderFallbackException) { return null; }
    }

    internal static string EncodeForm(IEnumerable<KeyValuePair<string, string>> pairs) =>
        string.Join("&", pairs.Select(kv => $"{Uri.EscapeDataString(kv.Key)}={Uri.EscapeDataString(kv.Value)}"));
}
