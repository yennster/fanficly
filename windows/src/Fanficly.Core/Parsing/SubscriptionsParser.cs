using AngleSharp.Dom;

namespace Fanficly.Core;

/// <summary>Parses the subscriptions index (<c>/users/&lt;name&gt;/subscriptions</c>). Fails
/// closed: a page that isn't recognisably the index throws rather than reading
/// as "zero subscriptions", so the poller's delete pass can never mass-delete.</summary>
public static class SubscriptionsParser
{
    public static IReadOnlyList<AO3Subscription> Parse(string html) => ParsePage(html).Subscriptions;

    /// <exception cref="AO3Exception">Unauthorized for the login page (expired
    /// session); ParseFailed for a page with neither a subscription list nor the
    /// index shell.</exception>
    public static AO3SubscriptionsPage ParsePage(string html)
    {
        var doc = HtmlDom.Parse(html);

        // Fail closed on a stale session: AO3 302s /users/<name>/subscriptions to
        // the login page, the HTTP client follows the redirect, and the caller
        // hands us login HTML with a 200. Returning [] here (or a phantom row
        // scraped from the login page's own links) would make the poller prune
        // every real SubscriptionRecord, so it must be an error.
        if (LooksLikeLoginPage(doc)) throw AO3Exception.Unauthorized();

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var results = new List<AO3Subscription>();

        var containers = doc.Select("dl.subscription, ul.subscription, dl.subscriptions, ul.subscriptions, ol.subscription, ol.subscriptions");

        // No subscription list at all: only trust that as "zero subscriptions"
        // when the page carries the subscriptions-index shell — anything else
        // (error page, markup drift, unexpected redirect) must not read as an
        // empty account.
        if (containers.Count == 0 && !HasIndexMarker(doc))
            throw AO3Exception.ParseFailed("Not a subscriptions page");

        foreach (var scope in containers)
        {
            var entries = scope.Select("dt, li.subscription, li.work, li.series, li.user");
            IReadOnlyList<IElement> entrySource = entries.Count == 0 ? [scope] : entries;

            foreach (var entry in entrySource)
            {
                var links = entry.Select("a[href]");
                if (PickPrimaryLink(links) is not { } primary) continue;
                if (Classify(primary.Attr("href")) is not { } parsed) continue;
                if (!seen.Add(parsed.Key)) continue;

                var title = primary.Text().TrimSwiftWhitespaces();
                var author = AuthorFromEntry(links, primary);
                results.Add(new AO3Subscription(parsed.Kind, parsed.Id, title, author));
            }
        }

        // Same will_paginate markup as the search pages — see HtmlDom.Pagination
        // for why "current" is checked on both the <li> and its inner element.
        var (currentPage, totalPages) = HtmlDom.Pagination(doc);
        return new AO3SubscriptionsPage(results, currentPage, totalPages);
    }

    /// <summary>A logged-in-only page can never legitimately contain a login form, so
    /// its presence means the session cookie expired and AO3 redirected us.</summary>
    private static bool LooksLikeLoginPage(IDocument doc) =>
        doc.Select("form").Any(form =>
        {
            var action = form.Attr("action");
            return action.EndsWith("/users/login", StringComparison.Ordinal)
                || action.Contains("/users/login?", StringComparison.Ordinal);
        });

    /// <summary>The subscriptions index shell: the <c>subscriptions-index</c> main div
    /// (Rails' controller-action class) or a heading naming the page. Present even
    /// when the user has zero subscriptions.</summary>
    private static bool HasIndexMarker(IDocument doc)
    {
        if (doc.Select("div.subscriptions-index, div.subscription-index").Count > 0) return true;
        return doc.Select("h2.heading, h3.heading")
            .Any(h => h.Text().Contains("subscription", StringComparison.CurrentCultureIgnoreCase));
    }

    private static IElement? PickPrimaryLink(IReadOnlyList<IElement> links) =>
        links.FirstOrDefault(link =>
        {
            var href = link.Attr("href");
            return Classify(href) is not null && !href.Contains("/comments", StringComparison.Ordinal);
        });

    private static string? AuthorFromEntry(IReadOnlyList<IElement> links, IElement primary)
    {
        foreach (var link in links)
        {
            if (ReferenceEquals(link, primary)) continue;
            if (!link.Attr("href").StartsWith("/users/", StringComparison.Ordinal)) continue;
            var text = link.Text().TrimSwiftWhitespaces();
            if (text.Length > 0) return text;
        }
        return null;
    }

    private readonly record struct Classified(AO3SubscriptionKind Kind, string Id)
    {
        public string Key => $"{AO3Subscription.KindRaw(Kind)}:{Id}";
    }

    private static Classified? Classify(string href)
    {
        var trimmed = href.SwiftSplit('?').FirstOrDefault() ?? href;
        var parts = trimmed.SwiftSplit('/');
        if (parts.Length < 2) return null;
        return parts[0] switch
        {
            "works" => new Classified(AO3SubscriptionKind.Work, parts[1]),
            "series" => new Classified(AO3SubscriptionKind.Series, parts[1]),
            "users" when parts.Length == 2 || parts[2] == "pseuds" => new Classified(AO3SubscriptionKind.User, parts[1]),
            _ => null,
        };
    }
}
