using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Fanficly.Core;

/// <summary>The signed-in AO3 account, observable by the UI. Use it from the UI
/// thread (Swift's is <c>@MainActor</c>): change notifications are raised on the
/// thread that makes the change, and its awaits resume on the caller's context.</summary>
public sealed class AuthState : INotifyPropertyChanged
{
    private readonly ICookieVault _vault;
    private string? _username;
    private bool _isAuthenticating;
    private string? _lastError;
    private bool _isSessionExpired;

    public AuthState(ICookieVault? vault = null)
    {
        _vault = vault ?? CredentialStore.Shared;
        _username = _vault.StoredUsername();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public string? Username
    {
        get => _username;
        set
        {
            if (Set(ref _username, value)) OnPropertyChanged(nameof(IsLoggedIn));
        }
    }

    public bool IsAuthenticating
    {
        get => _isAuthenticating;
        set => Set(ref _isAuthenticating, value);
    }

    public string? LastError
    {
        get => _lastError;
        set => Set(ref _lastError, value);
    }

    /// <summary>A username is stored (the reader signed in on this PC). The session
    /// cookie may still have expired; see <see cref="IsSessionExpired"/>.</summary>
    public bool IsLoggedIn => Username is not null;

    /// <summary>AO3 dropped the session while a username is stored: a request that
    /// needs the account got the login page, or a page came back rendered for a
    /// guest. Only signing in again (or out) clears it.</summary>
    public bool IsSessionExpired
    {
        get => _isSessionExpired;
        private set => Set(ref _isSessionExpired, value);
    }

    /// <summary>Signed in with a live session: what account features need.</summary>
    public bool HasSession => IsLoggedIn && !IsSessionExpired;

    /// <summary>Marks the session expired when signed in (a guest has nothing to expire).</summary>
    public void MarkSessionExpired()
    {
        if (IsLoggedIn) IsSessionExpired = true;
    }

    /// <summary>Notes a failed AO3 request: <c>Unauthorized</c> while signed in means
    /// the session expired. Returns whether it did.</summary>
    public bool NoteFailure(Exception error)
    {
        if (error is not AO3Exception { Kind: AO3ErrorKind.Unauthorized } || !IsLoggedIn) return false;
        IsSessionExpired = true;
        return true;
    }

    /// <summary>Notes a works listing (search, an author's works, bookmarks): one
    /// AO3 rendered for a guest while signed in means the session expired, and
    /// the listing is missing every restricted work. Returns whether it did.</summary>
    public bool NoteListing(AO3SearchResults results)
    {
        if (!results.ServedAsGuest || !IsLoggedIn) return false;
        IsSessionExpired = true;
        return true;
    }

    public async Task LoginAsync(IAO3Client client, string username, string password, CancellationToken ct = default)
    {
        IsAuthenticating = true;
        LastError = null;
        try
        {
            await client.LoginAsync(username, password, ct);
            // Signing in as someone else from the expired-session form skips
            // logout, so drop the previous account's kudos here.
            if (Username is { } previous && !string.Equals(previous, username, StringComparison.OrdinalIgnoreCase)) KudosStore.Clear();
            Username = username;
            _vault.SetUsername(username);
            IsSessionExpired = false;
        }
        catch (AO3Exception e) when (e.Kind == AO3ErrorKind.LoginFailed)
        {
            LastError = e.Reason;
        }
        catch (AO3Exception e) when (e.Kind == AO3ErrorKind.Network)
        {
            LastError = $"Network: {e.Reason}";
        }
        catch (Exception e)
        {
            LastError = e.Message;
        }
        finally
        {
            IsAuthenticating = false;
        }
    }

    public async Task LogoutAsync(IAO3Client client)
    {
        await client.LogoutAsync();
        _vault.SetUsername(null);
        KudosStore.Clear();
        Username = null;
        IsSessionExpired = false;
    }

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }

    private void OnPropertyChanged(string? name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
