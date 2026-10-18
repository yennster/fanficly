using System.Globalization;

namespace Fanficly.Core;

/// <summary>Works an AO3 account has left kudos on, remembered on this PC so the
/// kudos item reads "Kudos Left" instead of inviting a second click (Swift's
/// <c>KudosStore</c>). Keyed by username because AO3 counts one kudo per account.
/// Not backed up: AO3 itself still refuses a duplicate, which reads as already left.</summary>
public static class KudosStore
{
    public static string Key(string username) => $"kudos.left.{username.ToLowerInvariant()}";

    public static bool HasLeft(int workId, string username, IKeyValueStore? store = null) =>
        WorkIds(username, store ?? KeyValueStores.Default).Contains(workId);

    public static void MarkLeft(int workId, string username, IKeyValueStore? store = null)
    {
        store ??= KeyValueStores.Default;
        var ids = WorkIds(username, store);
        if (ids.Contains(workId)) return;
        ids.Add(workId);
        store.SetString(Key(username), string.Join(",", ids.Select(id => id.ToString(CultureInfo.InvariantCulture))));
    }

    private static List<int> WorkIds(string username, IKeyValueStore store) =>
        (store.GetString(Key(username)) ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries)
            .Select(s => int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var id) ? id : 0)
            .Where(id => id > 0)
            .ToList();
}

/// <summary>What to tell the reader after a kudos click: a thank-you or AO3's
/// reason for refusing. <see cref="NeedsSignIn"/> offers the sign-in screen.</summary>
public sealed record KudosResult(string Title, string Message, bool NeedsSignIn = false);

/// <summary>Leaves kudos from a work's options menu (Swift's <c>KudosGiver</c>):
/// sign-in gated, once per work. The screen owns it, so what it presents comes
/// after the menu closes. The POST is never retried: after a dropped connection a
/// second click is safe, because AO3 answers a duplicate with "already left kudos".</summary>
public sealed class KudosGiver(IKeyValueStore? store = null)
{
    private readonly IKeyValueStore? _store = store;

    public bool IsSending { get; private set; }
    public bool HasLeft { get; private set; }

    /// <summary>Raised when <see cref="IsSending"/> or <see cref="HasLeft"/> changes.</summary>
    public event Action? Changed;

    public void Refresh(int workId, string? username)
    {
        var hasLeft = username is not null && KudosStore.HasLeft(workId, username, _store);
        if (hasLeft == HasLeft) return;
        HasLeft = hasLeft;
        Changed?.Invoke();
    }

    /// <summary>Sends the kudo; null when nothing was sent (signed out, already
    /// left, or a click while one is on its way).</summary>
    public async Task<KudosResult?> LeaveAsync(int workId, string? username, IAO3Client client)
    {
        if (username is null || IsSending || HasLeft) return null;
        IsSending = true;
        Changed?.Invoke();
        try
        {
            // No ConfigureAwait(false): Changed must fire on the caller's (UI) thread.
            var outcome = await client.LeaveKudosAsync(workId);
            KudosStore.MarkLeft(workId, username, _store);
            HasLeft = true;
            return outcome == KudosOutcome.Left
                ? new("Kudos left", "Thank you for leaving kudos!")
                : new("Kudos already left", "You've already left kudos on this work.");
        }
        catch (AO3Exception e) when (e.Kind == AO3ErrorKind.Unauthorized)
        {
            return new("Couldn't leave kudos", "Your AO3 session has expired. Sign in again, then try again.", NeedsSignIn: true);
        }
        catch (AO3Exception e) when (e.Kind == AO3ErrorKind.Rejected)
        {
            return new("Couldn't leave kudos", e.Reason is { Length: > 0 } reason ? reason : "AO3 didn't accept the kudos.");
        }
        catch (AO3Exception e) when (e.Kind == AO3ErrorKind.Network)
        {
            return new("Couldn't leave kudos", $"{e.Message} The kudos may still have landed; trying again is safe.");
        }
        catch (AO3Exception e)
        {
            return new("Couldn't leave kudos", e.Message);
        }
        finally
        {
            IsSending = false;
            Changed?.Invoke();
        }
    }
}
