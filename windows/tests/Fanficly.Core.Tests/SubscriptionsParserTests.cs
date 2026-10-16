using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class SubscriptionsParserTests
{
    [Fact]
    public void ParsesWorkSubscriptions()
    {
        const string html = """
        <html><body>
        <dl class="subscription index group">
          <dt>
            <a href="/works/12345">A Coffee Shop Tale</a>
            by
            <a rel="author" href="/users/alice/pseuds/alice">alice</a>
          </dt>
          <dd><a class="delete">Unsubscribe</a></dd>
          <dt>
            <a href="/works/67890">Another Story</a>
            by
            <a rel="author" href="/users/bob">bob</a>
          </dt>
          <dd><a class="delete">Unsubscribe</a></dd>
        </dl>
        </body></html>
        """;
        var subs = SubscriptionsParser.Parse(html);
        Assert.Equal(2, subs.Count);
        Assert.Equal(AO3SubscriptionKind.Work, subs[0].Kind);
        Assert.Equal("12345", subs[0].ResourceId);
        Assert.Equal("A Coffee Shop Tale", subs[0].Title);
        Assert.Equal("alice", subs[0].Author);
        Assert.Equal(AO3SubscriptionKind.Work, subs[1].Kind);
        Assert.Equal("67890", subs[1].ResourceId);
    }

    [Fact]
    public void ParsesSeriesSubscriptions()
    {
        const string html = """
        <html><body>
        <dl class="subscription index group">
          <dt>
            <a href="/series/100">A Long Saga</a>
            by
            <a rel="author" href="/users/carol">carol</a>
          </dt>
        </dl>
        </body></html>
        """;
        var subs = SubscriptionsParser.Parse(html);
        Assert.Single(subs);
        Assert.Equal(AO3SubscriptionKind.Series, subs[0].Kind);
        Assert.Equal("100", subs[0].ResourceId);
        Assert.Equal("carol", subs[0].Author);
    }

    [Fact]
    public void ParsesUserSubscriptions()
    {
        const string html = """
        <html><body>
        <dl class="subscription index group">
          <dt>
            <a href="/users/dave">dave</a>
          </dt>
        </dl>
        </body></html>
        """;
        var subs = SubscriptionsParser.Parse(html);
        Assert.Single(subs);
        Assert.Equal(AO3SubscriptionKind.User, subs[0].Kind);
        Assert.Equal("dave", subs[0].ResourceId);
        Assert.Null(subs[0].Author);
    }

    [Fact]
    public void Dedupes()
    {
        const string html = """
        <html><body>
        <dl class="subscription">
          <dt><a href="/works/1">Same</a></dt>
          <dt><a href="/works/1">Same</a></dt>
        </dl>
        </body></html>
        """;
        Assert.Single(SubscriptionsParser.Parse(html));
    }

    // A page with neither a subscriptions list nor the index shell must fail
    // closed — reading it as "zero subscriptions" would make the poller delete
    // every real record.
    [Fact]
    public void PageWithoutSubscriptionMarkersThrows()
    {
        var e = Assert.Throws<AO3Exception>(() => SubscriptionsParser.Parse("<html></html>"));
        Assert.Equal(AO3ErrorKind.ParseFailed, e.Kind);
    }

    // With an expired session cookie AO3 302s /users/<name>/subscriptions to the
    // login page and the client follows it, so the parser receives login HTML
    // with a 200. It must throw — and in particular must not scrape the page's
    // /users/login link into a phantom "user:login" subscription.
    [Fact]
    public void LoginPageThrowsUnauthorized()
    {
        const string html = """
        <html><body class="logged-out">
        <div id="main" class="sessions-new">
          <h2 class="heading">Log In</h2>
          <form class="new_user" id="new_user" action="/users/login" method="post">
            <input name="authenticity_token" type="hidden" value="abc123">
            <label for="user_login">User name or email:</label>
            <input id="user_login" name="user[login]" type="text">
            <input id="user_password" name="user[password]" type="password">
            <input name="commit" type="submit" value="Log In">
          </form>
          <a href="/users/login">Log in</a>
          <a href="/users/password/new">Forgot password?</a>
        </div>
        </body></html>
        """;
        var e = Assert.Throws<AO3Exception>(() => SubscriptionsParser.Parse(html));
        Assert.Equal(AO3ErrorKind.Unauthorized, e.Kind);
    }

    // A user with zero subscriptions still gets the index shell — that must
    // parse as an empty list, not an error.
    [Fact]
    public void EmptySubscriptionsIndexIsEmpty()
    {
        const string html = """
        <html><body>
        <div id="main" class="subscriptions-index dashboard region">
          <h2 class="heading">My Subscriptions</h2>
          <p>You don't have any subscriptions yet.</p>
        </div>
        </body></html>
        """;
        Assert.Empty(SubscriptionsParser.Parse(html));
    }

    [Fact]
    public void ParsePage_ReadsPagination()
    {
        const string html = """
        <html><body>
        <dl class="subscription index group">
          <dt><a href="/works/1">First</a></dt>
        </dl>
        <ol class="pagination actions">
          <li class="previous"><span class="disabled">← Previous</span></li>
          <li><span class="current">2</span></li>
          <li><a href="/users/x/subscriptions?page=3">3</a></li>
          <li class="next"><a href="/users/x/subscriptions?page=3">Next →</a></li>
        </ol>
        </body></html>
        """;
        var page = SubscriptionsParser.ParsePage(html);
        Assert.Single(page.Subscriptions);
        Assert.Equal(2, page.CurrentPage);
        Assert.Equal(3, page.TotalPages);
    }

    [Fact]
    public void ParsePage_DefaultsToSinglePage()
    {
        const string html = """
        <html><body>
        <dl class="subscription index group">
          <dt><a href="/works/1">Only</a></dt>
        </dl>
        </body></html>
        """;
        var page = SubscriptionsParser.ParsePage(html);
        Assert.Equal(1, page.CurrentPage);
        Assert.Equal(1, page.TotalPages);
    }
}
