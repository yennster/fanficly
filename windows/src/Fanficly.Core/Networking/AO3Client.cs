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
    private readonly Uri _baseUri;
    private readonly string _origin;
    private readonly ICookieVault _vault;
    private readonly Throttle _throttle;
    private readonly string _libraryDirectory;
    private readonly Lock _cookieGate = new();
    private CookieContainer _cookies = new();
    private bool _cookiesLoaded;
    private string? _lastSavedCookies;
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
        _http = handler is null
            ? new HttpClient(CreateDefaultHandler(), disposeHandler: true)
            : new HttpClient(handler, disposeHandler: false);
        _http.Timeout = Timeout.InfiniteTimeSpan; // timeouts are per attempt, below
    }

    public string UserAgent { get; }

    public static string UserAgentFor(string version) => $"Fanficly/{version} (+github.com/yennster/fanficly)";

    /// <summary>Waits between retries; tests replace it to run instantly.</summary>
    internal Func<TimeSpan, CancellationToken, Task> Sleep { get; set; } = Task.Delay;

    /// <summary>Whether the machine has any network. Retrying while offline just
    /// burns backoff time and throttle slots, so offline failures surface at once.</summary>
    internal Func<bool> IsNetworkAvailable { get; set; } = System.Net.NetworkInformation.NetworkInterface.GetIsNetworkAvailable;

    /// <summary>Where <see cref="ExportWorkAsync"/> writes: %TEMP%\Fanficly\Exports,
    /// which Windows' storage cleanup empties.</summary>
    internal string ExportsDirectory { get; set; } = Path.Combine(Path.GetTempPath(), "Fanficly", "Exports");

    private static SocketsHttpHandler CreateDefaultHandler() => new()
    {
        UseCookies = false,
        AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.All,
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        ConnectTimeout = DefaultRequestTimeout,
    };

    public void Dispose() => _http.Dispose();

    // MARK: - Session

    public async Task LoginAsync(string username, string password, CancellationToken ct = default)
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

        // Success: the response shows the logged-in user navigation.
        if (LoginParser.CurrentUsername(respHtml) is { } name)
        {
            _cachedUsername = name;
            return;
        }
        // Explicit AO3 error flash.
        if (LoginParser.DetectLoginFailure(respHtml) is { } err) throw AO3Exception.LoginFailed(err);
        // Still on the login form → credentials rejected.
        if (LoginParser.HasLoginForm(respHtml)) throw AO3Exception.LoginFailed("Incorrect username or password.");
        // Unexpected response — assume the session cookie was set anyway.
        if (SiteCookies().Any(c => c.Name.Contains("user_credentials", StringComparison.Ordinal)
                                   || c.Name.Contains("remember_user_token", StringComparison.Ordinal)))
        {
            _cachedUsername = username;
            return;
        }
        throw AO3Exception.LoginFailed("Couldn't confirm login. Please try again.");
    }

    public Task LogoutAsync()
    {
        lock (_cookieGate)
        {
            var keep = new CookieContainer();
            foreach (var c in _cookies.GetAllCookies().Where(c => !IsSiteCookie(c))) keep.Add(c);
            _cookies = keep;
        }
        _cachedUsername = null;
        PersistCookies();
        return Task.CompletedTask;
    }

    public Task<string?> CurrentUsernameAsync() => Task.FromResult(_cachedUsername);

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
        return SearchResultsParser.Parse(Decode(response.Body, "Bookmarks response"), "li.bookmark.blurb");
    }

    public async Task<AO3WorkPayload> FetchWorkAsync(int id, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.Work(id, _baseUri)), ct: ct).ConfigureAwait(false);
        return WorkPageParser.Parse(Decode(response.Body, "Work response"), id);
    }

    public async Task<AO3WorkMetadata> FetchWorkMetadataAsync(int id, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.Work(id, _baseUri)), ct: ct).ConfigureAwait(false);
        return WorkMetadataParser.Parse(Decode(response.Body, "Work response"), id);
    }

    /// <summary>Every subscription across all pages. AO3 paginates the index at 20
    /// per page — walk every page (each fetch throttled) or anything past the
    /// first 20 is invisible and its records get treated as stale. Any page
    /// failing throws the whole call, so a partial list can never reach the
    /// caller's delete pass. The 50-page ceiling only guards against a
    /// pagination-parse glitch turning one sync into an unbounded crawl.</summary>
    public async Task<IReadOnlyList<AO3Subscription>> FetchSubscriptionsAsync(string username, CancellationToken ct = default)
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
        return all;
    }

    // MARK: - Comments

    public async Task<IReadOnlyList<AO3Comment>> FetchCommentsAsync(int workId, int? chapterId, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(CommentsPageUri(workId, chapterId)), ct: ct).ConfigureAwait(false);
        return CommentsParser.Parse(Decode(response.Body, "Comments response"));
    }

    /// <summary>The page whose <c>?show_comments=true</c> thread we read/post against: a
    /// specific chapter when its id is known, else the work page.</summary>
    private Uri CommentsPageUri(int workId, int? chapterId) => chapterId is { } cid
        ? AO3Endpoints.ChapterComments(workId, cid, _baseUri)
        : AO3Endpoints.WorkComments(workId, _baseUri);

    public async Task PostCommentAsync(int workId, int? chapterId, string text, CancellationToken ct = default)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return;

        // Load the chapter's (or work's) comment page and replay its actual
        // new-comment form: the form's hidden inputs carry the CSRF token and the
        // `comment[commentable_id]`/`[commentable_type]` that bind the comment to
        // exactly the chapter AO3 would — so we never hardcode the POST shape.
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var pageUri = CommentsPageUri(workId, chapterId);
        var page = await PerformRequestAsync(Get(pageUri), ct: ct).ConfigureAwait(false);
        var pageHtml = Decode(page.Body, "Comment page");
        var form = CommentsParser.NewCommentForm(pageHtml, _baseUri)
            ?? throw AO3Exception.ParseFailed("comment form not found (login required?)");

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
        Directory.CreateDirectory(_libraryDirectory);
        var path = Path.Combine(_libraryDirectory, $"{workId}.epub");
        await WriteAtomicallyAsync(path, response.Body, ct).ConfigureAwait(false);
        return path;
    }

    public async Task<string> ExportWorkAsync(int workId, WorkExportFormat format, string filename, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct).ConfigureAwait(false);
        var response = await PerformRequestAsync(Get(AO3Endpoints.Download(workId, format, _baseUri)), ct: ct).ConfigureAwait(false);
        Directory.CreateDirectory(ExportsDirectory);
        var safe = SanitizeFilename(filename.Length == 0 ? $"work-{workId}" : filename);
        var path = Path.Combine(ExportsDirectory, $"{safe}.{format.Ext()}");
        if (File.Exists(path)) File.Delete(path);
        await WriteAtomicallyAsync(path, response.Body, ct).ConfigureAwait(false);
        return path;
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
        var pageUri = AO3Endpoints.Work(workId, _baseUri);
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
        if (response.Status >= 400 && response.Status != 422) throw AO3Exception.Http(response.Status);
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

    internal sealed record Response(int Status, byte[] Body, TimeSpan? RetryAfter, Uri FinalUri);

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
    internal async Task<Response> PerformRequestAsync(RequestSpec spec, int maxRetries = MaxRetries, CancellationToken ct = default)
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

            switch (response.Status)
            {
                case >= 200 and < 300 or 302:
                    return response;
                case 401 or 403:
                    throw AO3Exception.Unauthorized();
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

    private static SocketError? FindSocketError(Exception? e)
    {
        for (; e is not null; e = e.InnerException)
            if (e is SocketException se) return se.SocketErrorCode;
        return null;
    }

    private async Task<Response> SendFollowingRedirectsAsync(RequestSpec spec, CancellationToken ct)
    {
        using var resourceCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        resourceCts.CancelAfter(ResourceTimeout);
        var method = spec.Method;
        var uri = spec.Uri;
        var body = spec.FormBody;
        for (var hop = 0; ; hop++)
        {
            // HTTP/2 when AO3's edge offers it, as URLSession does on the Apple app;
            // HttpClient would otherwise stay on HTTP/1.1, which opens more
            // connections (each a TLS handshake) and is slower to first byte.
            using var request = new HttpRequestMessage(method, uri)
            {
                Version = HttpVersion.Version20,
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

            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(resourceCts.Token);
            timeoutCts.CancelAfter(spec.Timeout);
            HttpResponseMessage response;
            try
            {
                response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeoutCts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException e) when (!ct.IsCancellationRequested)
            {
                throw new TimeoutException("The request timed out.", e);
            }

            using (response)
            {
                StoreCookies(uri, response);
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
                return new Response(status, data, RetryAfterSeconds(response), uri);
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

    private void EnsureCookiesLoaded()
    {
        lock (_cookieGate)
        {
            if (_cookiesLoaded) return;
            _cookiesLoaded = true;
            IReadOnlyList<SerializableCookie> saved;
            try { saved = _vault.LoadCookies(); }
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

    private void StoreCookies(Uri uri, HttpResponseMessage response)
    {
        if (!response.Headers.TryGetValues("Set-Cookie", out var values)) return;
        lock (_cookieGate)
        {
            foreach (var value in values)
            {
                try { _cookies.SetCookies(uri, value); }
                catch (CookieException) { }
            }
        }
        PersistCookies();
    }

    /// <summary>Saves the site's cookies to the vault when they changed, so the
    /// session survives a restart.</summary>
    private void PersistCookies()
    {
        List<SerializableCookie> snapshot;
        lock (_cookieGate)
        {
            snapshot = SiteCookiesLocked().Select(SerializableCookie.FromCookie).ToList();
            var json = SerializableCookie.ToJson(snapshot);
            if (json == _lastSavedCookies) return;
            _lastSavedCookies = json;
        }
        try { _vault.SaveCookies(snapshot); }
        catch (Exception) { /* A vault failure must not fail the request. */ }
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
