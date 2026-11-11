namespace Fanficly.Core;

/// <summary>Why the poller's last check of a follow or subscription failed,
/// stored as its raw value in the record's <c>LastCheckFailure</c> (Swift's
/// <c>CheckFailure</c>, same raw values).</summary>
public enum CheckFailure
{
    /// <summary>AO3 asked for a sign-in: a restricted work followed while
    /// signed out, or an expired session.</summary>
    SignIn,
    /// <summary>AO3 has no such work or author any more (a 404).</summary>
    NotFound,
    /// <summary>Anything else: AO3 down, a Cloudflare page, unreadable markup.</summary>
    Other,
}

/// <summary>What a row says about a follow's or subscription's checks (#195,
/// Swift's <c>CheckStatus</c>). The poller stamps <c>LastCheckedAt</c> on every
/// attempt, since it orders the queue, so a follow that could never be checked
/// used to read "Checked just now" forever. Rows go by the last check that
/// worked instead, and after <see cref="FailuresBeforeWarning"/> failed checks
/// in a row say why they fail. <see cref="Failure"/> is null for
/// <see cref="CheckedAt"/>, and set when failing.</summary>
public sealed record CheckStatus(DateTimeOffset? CheckedAt, CheckFailure? Failure)
{
    /// <summary>One failure can be AO3 having a bad minute; two in a row is worth showing.</summary>
    public const int FailuresBeforeWarning = 2;

    public static CheckStatus Checked(DateTimeOffset at) => new(at, null);
    public static CheckStatus Failing(CheckFailure failure) => new(null, failure);

    /// <summary>The raw value kept in the database and in Swift's store.</summary>
    public static string RawValue(CheckFailure failure) => failure switch
    {
        CheckFailure.SignIn => "signIn",
        CheckFailure.NotFound => "notFound",
        _ => "other",
    };

    public static CheckFailure FromRawValue(string? raw) => raw switch
    {
        "signIn" => CheckFailure.SignIn,
        "notFound" => CheckFailure.NotFound,
        _ => CheckFailure.Other,
    };

    public static CheckFailure FailureOf(Exception error) => error switch
    {
        AO3Exception { Kind: AO3ErrorKind.Unauthorized } => CheckFailure.SignIn,
        AO3Exception { Kind: AO3ErrorKind.Http, Status: 404 } => CheckFailure.NotFound,
        _ => CheckFailure.Other,
    };

    /// <summary>The status to show, or null for nothing (never checked, or the
    /// only news is a failure not yet repeated and no check ever worked).</summary>
    public static CheckStatus? Of(DateTimeOffset? lastCheckedAt, DateTimeOffset? lastSucceededAt, int failures, string? failure)
    {
        if (failures >= FailuresBeforeWarning) return Failing(FromRawValue(failure));
        if (lastSucceededAt is { } succeeded) return Checked(succeeded);
        // A record from before #195 has only the attempt stamp. With no failure
        // recorded since, that's the best there is.
        if (failures == 0 && lastCheckedAt is { } attempted) return Checked(attempted);
        return null;
    }

    /// <summary>The row's text for a failing check.</summary>
    public static string Message(CheckFailure failure) => failure switch
    {
        CheckFailure.SignIn => "Couldn't check: sign in to AO3",
        CheckFailure.NotFound => "Couldn't check: not found on AO3",
        _ => "Couldn't check lately",
    };
}

/// <summary>The records the poller checks, each with the #195 fields.</summary>
public interface ICheckedRecord
{
    DateTimeOffset? LastCheckedAt { get; set; }
    DateTimeOffset? LastSucceededAt { get; set; }
    int CheckFailures { get; set; }
    string? LastCheckFailure { get; set; }
}

public static class CheckedRecordExtensions
{
    /// <summary>A check that read AO3's answer.</summary>
    public static void NoteCheckSucceeded(this ICheckedRecord record, DateTimeOffset? at = null)
    {
        record.LastSucceededAt = at ?? DateTimeOffset.Now;
        record.CheckFailures = 0;
        record.LastCheckFailure = null;
    }

    /// <summary>A check that didn't.</summary>
    public static void NoteCheckFailed(this ICheckedRecord record, CheckFailure failure)
    {
        record.CheckFailures++;
        record.LastCheckFailure = CheckStatus.RawValue(failure);
    }

    public static CheckStatus? CurrentCheckStatus(this ICheckedRecord record) =>
        CheckStatus.Of(record.LastCheckedAt, record.LastSucceededAt, record.CheckFailures, record.LastCheckFailure);
}
