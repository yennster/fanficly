namespace Fanficly.Core;

/// <summary>Reads AO3's login form and the pages around it: the CSRF token, the
/// logged-in username, and failure flashes.</summary>
public static class LoginParser
{
    /// <summary>The CSRF token: <c>&lt;meta name="csrf-token"&gt;</c>, else a form's
    /// <c>authenticity_token</c> input. Null when neither carries a value.</summary>
    public static string? AuthenticityToken(string html)
    {
        var doc = HtmlDom.Parse(html);
        if (doc.SelectFirst("meta[name='csrf-token']") is { } meta && meta.Attr("content") is { Length: > 0 } content)
            return content;
        if (doc.SelectFirst("form input[name='authenticity_token']") is { } input && input.Attr("value") is { Length: > 0 } value)
            return value;
        return null;
    }

    /// <summary>AO3's error flash after a failed login, or null.</summary>
    public static string? DetectLoginFailure(string html)
    {
        var doc = HtmlDom.Parse(html);
        if (doc.SelectFirst("div#flash_error, p.error, ul.errorlist li") is { } flash)
        {
            var msg = flash.Text().TrimSwiftWhitespaces();
            if (msg.Length > 0) return msg;
        }
        return null;
    }

    private static readonly string[] UserLinkSelectors =
    [
        // AO3's logged-in navbar (#greeting dropdown) links to /users/<name>.
        "#greeting a[href^='/users/']",
        "ul.user.navigation a[href^='/users/']",
        "ul#user-navigation a[href^='/users/']",
        "#header a[href^='/users/']",
    ];

    /// <summary>The logged-in user's login from the page's navigation, or null when
    /// logged out.</summary>
    public static string? CurrentUsername(string html)
    {
        var doc = HtmlDom.Parse(html);
        foreach (var sel in UserLinkSelectors)
        {
            foreach (var link in doc.Select(sel))
            {
                var parts = link.Attr("href").SwiftSplit('/');
                if (parts.Length < 2 || parts[0] != "users") continue;
                var name = parts[1];
                // Skip the login/logout/signup action links.
                if (name.ToLowerInvariant() is "login" or "logout" or "signup" or "activate") continue;
                return name;
            }
        }
        return null;
    }

    /// <summary>True if the page still shows the login form (i.e. we're not logged in).</summary>
    public static bool HasLoginForm(string html) =>
        HtmlDom.Parse(html).Select("form#new_user, input[name='user[login]'], #loginform").Count > 0;
}
