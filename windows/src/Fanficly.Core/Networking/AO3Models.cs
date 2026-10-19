namespace Fanficly.Core;

/// <summary>One page of a work listing (search, an author's works, bookmarks).</summary>
public sealed record AO3SearchResults(
    IReadOnlyList<AO3WorkSummary> Works,
    int TotalPages,
    int CurrentPage,
    /// <summary>The search page's "126,555 Found" total; null on listings without one.</summary>
    int? TotalFound = null);

/// <summary>A work as listed in a blurb or read from its work page.</summary>
public sealed record AO3WorkSummary
{
    public required int Id { get; init; }
    public string Title { get; init; } = "";
    public string Author { get; init; } = "";
    /// <summary>The author's AO3 login (the <c>/users/&lt;login&gt;</c> segment), used to open
    /// their works page. Empty for anonymous works or when not parsed.</summary>
    public string AuthorUsername { get; init; } = "";
    public string Summary { get; init; } = "";
    public string Rating { get; init; } = "Not Rated";
    public IReadOnlyList<string> Warnings { get; init; } = [];
    public IReadOnlyList<string> Categories { get; init; } = [];
    public IReadOnlyList<string> Fandoms { get; init; } = [];
    public IReadOnlyList<string> Characters { get; init; } = [];
    public IReadOnlyList<string> Relationships { get; init; } = [];
    public IReadOnlyList<string> Freeforms { get; init; } = [];
    public int WordCount { get; init; }
    public int ChapterCount { get; init; } = 1;
    public int? TotalChapters { get; init; }
    public string Language { get; init; } = "English";
    public int Kudos { get; init; }
    public int Hits { get; init; }
    public bool IsComplete { get; init; }
    public DateTimeOffset? UpdatedAt { get; init; }

    public bool Equals(AO3WorkSummary? other) =>
        other is not null &&
        Id == other.Id && Title == other.Title && Author == other.Author &&
        AuthorUsername == other.AuthorUsername && Summary == other.Summary &&
        Rating == other.Rating && Warnings.SequenceEqual(other.Warnings) &&
        Categories.SequenceEqual(other.Categories) && Fandoms.SequenceEqual(other.Fandoms) &&
        Characters.SequenceEqual(other.Characters) && Relationships.SequenceEqual(other.Relationships) &&
        Freeforms.SequenceEqual(other.Freeforms) && WordCount == other.WordCount &&
        ChapterCount == other.ChapterCount && TotalChapters == other.TotalChapters &&
        Language == other.Language && Kudos == other.Kudos && Hits == other.Hits &&
        IsComplete == other.IsComplete && UpdatedAt == other.UpdatedAt;

    public override int GetHashCode() => HashCode.Combine(Id, Title, Author, WordCount, ChapterCount, UpdatedAt);
}

/// <summary>A work page: its metadata plus every chapter's HTML.</summary>
public sealed record AO3WorkPayload(AO3WorkSummary Summary, IReadOnlyList<AO3ChapterPayload> Chapters);

/// <param name="Index">1-based chapter number.</param>
/// <param name="AoId">AO3's chapter database id, parsed from the chapter's
/// <c>/works/&lt;id&gt;/chapters/&lt;chapterId&gt;</c> link. Drives per-chapter comments;
/// null when the markup doesn't expose it, in which case callers fall back to
/// work-level comments.</param>
public sealed record AO3ChapterPayload(int Index, string Title, string BodyHtml, int? AoId = null);

/// <summary>A work as AO3 shows it by default, one chapter to a page: the work's
/// metadata and that chapter, plus every chapter's AO3 id in reading order (the
/// page's chapter menu). Much lighter than the whole work on one page, so a
/// reader can open on it while the rest loads.</summary>
/// <param name="IsWholeWork">Every chapter is already here: a one-shot, an
/// account set to show whole works, or a fallback to the full work page.</param>
public sealed record AO3WorkChapterPage(AO3WorkPayload Payload, IReadOnlyList<int> ChapterIds, bool IsWholeWork);

/// <summary>A live snapshot of popular fandoms, ships, and characters, derived
/// from AO3 HTML (media-page fandom counts + works-filter facet counts). Cached
/// on-device and refreshed about daily.</summary>
public sealed record PopularSnapshot(
    IReadOnlyList<string> Fandoms,
    IReadOnlyList<string> Ships,
    IReadOnlyList<string> Characters,
    DateTimeOffset FetchedAt);

/// <param name="Depth">Thread nesting: 0 = top-level, 1 = reply, etc.</param>
/// <param name="CommenterUsername">AO3 login for registered commenters; "" for guests.</param>
public sealed record AO3Comment(
    string Id,
    string CommenterName,
    string CommenterUsername,
    string DateText,
    string BodyHtml,
    int Depth);

/// <summary>One page of a chapter's (or one-shot's) comment threads (Swift's
/// <c>AO3CommentsPage</c>). AO3 paginates comments by top-level thread;
/// <paramref name="TotalPages"/> comes from the thread's will_paginate list and is
/// 1 when there is none.</summary>
public sealed record AO3CommentsPage(IReadOnlyList<AO3Comment> Comments, int CurrentPage = 1, int TotalPages = 1)
{
    public bool HasMore => CurrentPage < TotalPages;
}

public sealed record AO3WorkMetadata(int Id, int ChapterCount, int? TotalChapters, DateTimeOffset? UpdatedAt);

public enum AO3SubscriptionKind { Work, Series, User }

public sealed record AO3Subscription(AO3SubscriptionKind Kind, string ResourceId, string Title, string? Author)
{
    public static string KindRaw(AO3SubscriptionKind kind) => kind switch
    {
        AO3SubscriptionKind.Work => "work",
        AO3SubscriptionKind.Series => "series",
        _ => "user",
    };

    /// <summary>"work:123", "series:9", "user:name" — the SubscriptionRecord key.</summary>
    public string Key => $"{KindRaw(Kind)}:{ResourceId}";
    public string Id => Key;
}

/// <summary>One page of the subscriptions index plus its pagination.</summary>
public sealed record AO3SubscriptionsPage(IReadOnlyList<AO3Subscription> Subscriptions, int CurrentPage, int TotalPages);

/// <summary>One tag in the works-listing filter sidebar, with its work count.</summary>
public sealed record AO3TagFacet(string Name, int Count);

/// <summary>The faceted filter sidebar AO3 renders on a works listing
/// (<c>/tags/&lt;tag&gt;/works</c>).</summary>
public sealed record AO3WorkFilters(
    IReadOnlyList<AO3TagFacet> Relationships,
    IReadOnlyList<AO3TagFacet> Characters,
    IReadOnlyList<AO3TagFacet> Fandoms,
    IReadOnlyList<AO3TagFacet> Freeforms);

public enum AO3AutocompleteField
{
    Relationship, Character, Freeform, Fandom,
    /// <summary>Every canonical tag type at once — one request per search suggestion.</summary>
    Tag,
}

public static class AO3AutocompleteFieldExtensions
{
    public static string RawValue(this AO3AutocompleteField f) => f switch
    {
        AO3AutocompleteField.Relationship => "relationship",
        AO3AutocompleteField.Character => "character",
        AO3AutocompleteField.Freeform => "freeform",
        AO3AutocompleteField.Fandom => "fandom",
        _ => "tag",
    };
}

public enum WorkExportFormat { Azw3, Epub, Mobi, Pdf, Html }

public static class WorkExportFormatExtensions
{
    public static IReadOnlyList<WorkExportFormat> All { get; } =
        [WorkExportFormat.Azw3, WorkExportFormat.Epub, WorkExportFormat.Mobi, WorkExportFormat.Pdf, WorkExportFormat.Html];

    public static string Ext(this WorkExportFormat f) => f.ToString().ToLowerInvariant();

    public static string DisplayName(this WorkExportFormat f) => f.ToString().ToUpperInvariant();

    /// <summary>Icon id (SF Symbol name; the app maps it to a Fluent glyph).</summary>
    public static string Icon(this WorkExportFormat f) => f switch
    {
        WorkExportFormat.Azw3 => "books.vertical",
        WorkExportFormat.Epub => "book",
        WorkExportFormat.Mobi => "book.closed",
        WorkExportFormat.Pdf => "doc.richtext",
        _ => "globe",
    };
}

/// <summary>What AO3 said to a kudos POST (Swift's <c>KudosOutcome</c>). AO3 allows
/// one kudo per user per work and answers a second with "You have already left
/// kudos here. :)", which is still a kudo on the work.</summary>
public enum KudosOutcome { Left, AlreadyLeft }

public enum AO3ErrorKind { LoginFailed, RateLimited, Unauthorized, ParseFailed, Http, Network, Rejected }

/// <summary>Every failure the AO3 client surfaces (Swift's <c>AO3Error</c>).</summary>
public sealed class AO3Exception : Exception
{
    public AO3ErrorKind Kind { get; }
    /// <summary>The reason for LoginFailed / ParseFailed / Network.</summary>
    public string? Reason { get; }
    /// <summary>The HTTP status for Http.</summary>
    public int? Status { get; }

    public AO3Exception(AO3ErrorKind kind, string? reason = null, int? status = null, Exception? inner = null)
        : base(Describe(kind, reason, status), inner)
    {
        Kind = kind;
        Reason = reason;
        Status = status;
    }

    public static AO3Exception LoginFailed(string reason) => new(AO3ErrorKind.LoginFailed, reason);
    public static AO3Exception RateLimited() => new(AO3ErrorKind.RateLimited);
    public static AO3Exception Unauthorized() => new(AO3ErrorKind.Unauthorized);
    public static AO3Exception ParseFailed(string reason) => new(AO3ErrorKind.ParseFailed, reason);
    /// <summary>AO3 answered, but turned the action down (its error message, if any).</summary>
    public static AO3Exception Rejected(string reason) => new(AO3ErrorKind.Rejected, reason);
    /// <summary>Statuses meaning AO3 couldn't serve the page for now: 502, 503 and
    /// 504, and Cloudflare's 520–526 (its edge couldn't reach AO3's servers).</summary>
    public static bool IsServerUnavailable(int status) => status is 502 or 503 or 504 or (>= 520 and <= 526);

    public static AO3Exception Http(int status) => new(AO3ErrorKind.Http, status: status);
    public static AO3Exception Network(string underlying, Exception? inner = null) => new(AO3ErrorKind.Network, underlying, inner: inner);

    private static string Describe(AO3ErrorKind kind, string? reason, int? status) => kind switch
    {
        AO3ErrorKind.LoginFailed => reason ?? "Login failed.",
        AO3ErrorKind.RateLimited => "AO3 is rate-limiting requests. Try again in a minute.",
        AO3ErrorKind.Unauthorized => "You need to log in to AO3 for this.",
        AO3ErrorKind.ParseFailed => $"Couldn't read AO3's page ({reason}).",
        AO3ErrorKind.Rejected => reason is { Length: > 0 } ? $"AO3 didn't accept it: {reason}" : "AO3 didn't accept it.",
        AO3ErrorKind.Http when status is { } code && IsServerUnavailable(code) =>
            $"AO3 isn't responding right now (HTTP {code}). This is on AO3's side; try again in a minute.",
        AO3ErrorKind.Http => $"AO3 returned an error (HTTP {status}).",
        _ => $"Network error: {reason}",
    };
}
