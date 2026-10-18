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

    public bool IsLoggedIn => Username is not null;

    public async Task LoginAsync(IAO3Client client, string username, string password, CancellationToken ct = default)
    {
        IsAuthenticating = true;
        LastError = null;
        try
        {
            await client.LoginAsync(username, password, ct);
            Username = username;
            _vault.SetUsername(username);
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
        Username = null;
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
