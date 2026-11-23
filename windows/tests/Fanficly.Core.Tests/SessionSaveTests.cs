using Fanficly.Core;
using Xunit;

namespace Fanficly.Core.Tests;

/// <summary>A sign-in the vault couldn't write is retried, and says so, rather
/// than being lost at the next launch (#210).</summary>
public sealed class SessionSaveTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "fanficly-session-tests-" + Guid.NewGuid().ToString("N"));
    private readonly FakeHandler _handler = new();
    private readonly FlakyVault _vault = new();

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (DirectoryNotFoundException) { }
    }

    private AO3Client MakeClient() =>
        new(Path.Combine(_dir, "library"), _vault, "9.9.9", handler: _handler, throttle: new Throttle(TimeSpan.Zero))
        {
            Sleep = (_, _) => Task.CompletedTask,
            IsNetworkAvailable = () => true,
            ExportsDirectory = Path.Combine(_dir, "exports"),
        };

    private const string LoginFormHtml = """
        <html><body><form id="new_user" action="/users/login" method="post">
          <input name="authenticity_token" type="hidden" value="TOKEN1"/>
          <input name="user[login]"/>
        </form></body></html>
        """;

    private const string SignedInHtml = """
        <html><body><div id="greeting"><a href="/users/reader">reader</a></div></body></html>
        """;

    private const string WorkHtml = """
        <html><body><dl class="stats"><dd class="chapters">3/5</dd><dd class="status">2024-03-12</dd></dl></body></html>
        """;

    private void ScriptLoginThenWorks(params string?[] workCookies)
    {
        var steps = new List<Func<HttpRequestMessage, HttpResponseMessage>>
        {
            _ => FakeHandler.Html(LoginFormHtml),
            _ => FakeHandler.Html(SignedInHtml, "remember_user_token=remember; path=/; expires=Wed, 21 Oct 2037 07:28:00 GMT; secure"),
        };
        steps.AddRange(workCookies.Select(c => (Func<HttpRequestMessage, HttpResponseMessage>)(_ => FakeHandler.Html(WorkHtml, c))));
        _handler.Respond([.. steps]);
    }

    [Fact]
    public async Task AFailedCookieSaveIsRetriedOnTheNextAnswer()
    {
        ScriptLoginThenWorks(null, null);
        var client = MakeClient();
        var auth = new AuthState(_vault);
        _vault.FailingKey = KeyedCookieVault.CookiesKey;

        await auth.LoginAsync(client, "reader", "pw");

        Assert.Equal("reader", auth.Username);
        Assert.Null(auth.LastError);
        Assert.Empty(_vault.LoadCookies());
        Assert.True(_vault.IsSessionUnsaved);
        Assert.False(new AuthState(_vault).IsSessionSaved);

        // Still failing: the next answer (with no new cookies) tries again.
        await client.FetchWorkMetadataAsync(1);
        Assert.Empty(_vault.LoadCookies());
        Assert.True(_vault.IsSessionUnsaved);

        _vault.FailingKey = null;
        var changes = 0;
        _vault.SessionSaveChanged += () => changes++;
        await client.FetchWorkMetadataAsync(1);

        // remember_user_token, which AO3 sends only at sign-in, reached the vault.
        Assert.Equal(["remember"], _vault.LoadCookies().Select(c => c.Value));
        Assert.False(_vault.IsSessionUnsaved);
        Assert.Equal(1, changes);
    }

    [Fact]
    public async Task AFailedUsernameWriteKeepsTheSessionAndIsRetriedWithTheNextCookieSave()
    {
        ScriptLoginThenWorks([null]);
        var client = MakeClient();
        var auth = new AuthState(_vault);
        _vault.FailingKey = KeyedCookieVault.UsernameKey;

        await auth.LoginAsync(client, "reader", "pw");

        Assert.Equal("reader", auth.Username);
        Assert.Null(auth.LastError);
        Assert.True(_vault.IsSessionUnsaved);
        // This run still counts as signed in, so cookies keep saving.
        Assert.Equal("reader", _vault.StoredUsername());
        Assert.Null(_vault.Written(KeyedCookieVault.UsernameKey));

        _vault.FailingKey = null;
        await client.FetchWorkMetadataAsync(1);

        Assert.Equal("reader", _vault.Written(KeyedCookieVault.UsernameKey));
        Assert.False(_vault.IsSessionUnsaved);
    }

    [Fact]
    public void SigningOutClearsAnUnsavedSession()
    {
        _vault.FailingKey = KeyedCookieVault.UsernameKey;
        Assert.ThrowsAny<IOException>(() => _vault.SetUsername("reader"));
        Assert.True(_vault.IsSessionUnsaved);

        _vault.SetUsername(null);

        Assert.False(_vault.IsSessionUnsaved);
        Assert.Null(_vault.StoredUsername());
    }

    [Fact]
    public async Task ASaveThatWorksTheFirstTimeIsNotRepeated()
    {
        ScriptLoginThenWorks(null, null);
        var client = MakeClient();
        await new AuthState(_vault).LoginAsync(client, "reader", "pw");
        var writes = _vault.CookieWrites;

        await client.FetchWorkMetadataAsync(1);
        await client.FetchWorkMetadataAsync(1);

        Assert.Equal(writes, _vault.CookieWrites);
        Assert.False(_vault.IsSessionUnsaved);
    }

    /// <summary>An in-memory vault whose writes to one key fail, like a locked
    /// file or a DPAPI error.</summary>
    private sealed class FlakyVault : KeyedCookieVault
    {
        private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);
        private readonly Lock _gate = new();
        public string? FailingKey { get; set; }
        public int CookieWrites { get; private set; }

        public string? Written(string key)
        {
            lock (_gate) return _values.TryGetValue(key, out var v) ? v : null;
        }

        protected override string? Read(string key) => Written(key);

        protected override void Write(string key, string value)
        {
            if (key == FailingKey) throw new IOException("The file is locked.");
            lock (_gate)
            {
                _values[key] = value;
                if (key == CookiesKey) CookieWrites++;
            }
        }

        protected override void Delete(string key)
        {
            lock (_gate) _values.Remove(key);
        }
    }
}
