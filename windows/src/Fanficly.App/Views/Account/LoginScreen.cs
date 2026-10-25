using System.ComponentModel;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace Fanficly.App.Views.Account;

/// <summary>
/// AO3 sign-in (LoginView). Logged out: username and password, the error AO3
/// gave, and Log in (Enter submits); on success the screen pops back to where
/// it was opened from. Logged in: who you are and Log out. Session expired
/// (#131): the form again, with the username filled in and a note saying why.
/// </summary>
public sealed class LoginScreen : Screen
{
    private readonly ScrollViewer _scroll = new()
    {
        HorizontalScrollMode = ScrollMode.Disabled,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
    };
    private TextBox? _username;
    private PasswordBox? _password;
    private Button? _submit;
    private StackPanel? _errorSlot;
    private bool _isVisible;

    public LoginScreen()
    {
        Title = "AO3 Login";
    }

    protected override FrameworkElement Build()
    {
        AppHost.Auth.PropertyChanged += OnAuthChanged;
        Render();
        return _scroll;
    }

    public override void OnAppearing()
    {
        _isVisible = true;
        if (IsBuilt) Render();
    }

    public override void OnDisappearing() => _isVisible = false;

    public override void OnRemoved() => AppHost.Auth.PropertyChanged -= OnAuthChanged;

    private void OnAuthChanged(object? sender, PropertyChangedEventArgs e) => AccountKit.OnUIThread(() =>
    {
        if (!_isVisible) return;
        switch (e.PropertyName)
        {
            case nameof(AuthState.Username):
            case nameof(AuthState.IsSessionExpired):
                Render();
                break;
            case nameof(AuthState.IsAuthenticating):
                UpdateSubmit();
                break;
            case nameof(AuthState.LastError):
                UpdateError();
                break;
        }
    });

    private void Render()
    {
        var auth = AppHost.Auth;
        var body = new StackPanel { Spacing = 20, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(24, 8, 24, 24) };
        if (auth.Username is { } current && !auth.IsSessionExpired)
        {
            _username = null;
            _password = null;
            _submit = null;
            _errorSlot = null;
            var logout = UI.UI.NavRow(UI.UI.Text("Log out", Theme.Style.Body, Theme.Danger), () => _ = LogOutAsync(), "Log out", chevron: false)
                .Id("login.logout");
            body.Children.Add(UI.UI.Section(null,
                [
                    UI.UI.SettingsRow("Logged in as", UI.UI.Secondary(current, Theme.Style.Body).Also(t => t.IsTextSelectionEnabled = true)),
                    logout,
                ],
                footer: "Logging out clears the session cookie Windows keeps protected for Fanficly on this PC. Your offline library stays on the device."));
        }
        else
        {
            _username = new TextBox
            {
                PlaceholderText = "Username",
                IsSpellCheckEnabled = false,
                IsTextPredictionEnabled = false,
                Text = _username?.Text is { Length: > 0 } typed ? typed : auth.Username ?? "",
            }.Id("login.username");
            AutomationProperties.SetName(_username, "Username");
            _password = new PasswordBox { PlaceholderText = "Password" }.Id("login.password");
            // The username is known when the session expired: start on the password.
            FrameworkElement first = _username.Text.Length > 0 ? _password : _username;
            first.Loaded += (_, _) => ((Control)first).Focus(FocusState.Programmatic);
            AutomationProperties.SetName(_password, "Password");

            _username.TextChanged += (_, _) => UpdateSubmit();
            _password.PasswordChanged += (_, _) => UpdateSubmit();
            _username.PreviewKeyDown += (_, e) =>
            {
                if (e.Key != VirtualKey.Enter) return;
                e.Handled = true;
                if (_password.Password.Length == 0) _password.Focus(FocusState.Keyboard);
                else Submit();
            };
            _password.PreviewKeyDown += (_, e) =>
            {
                if (e.Key != VirtualKey.Enter) return;
                e.Handled = true;
                Submit();
            };

            if (auth.IsSessionExpired) body.Children.Add(ExpiredNote());

            var fields = UI.UI.VStack(12, _username, _password);
            fields.Padding = new Thickness(14);
            body.Children.Add(UI.UI.Section(null, [fields],
                footer: "Credentials go directly to AO3. We never store your password — only the resulting session cookie, kept protected by Windows on this PC."));

            _errorSlot = new StackPanel();
            body.Children.Add(_errorSlot);

            _submit = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Center,
                MinHeight = 36,
            }.Id("login.submit");
            UI.UI.ApplyKind(_submit, UI.UI.ButtonKind.Accent);
            _submit.Click += (_, _) => Submit();
            body.Children.Add(_submit);
            UpdateError();
            UpdateSubmit();
        }
        _scroll.Content = body;
    }

    /// <summary>Why the form is back while a username is stored.</summary>
    private static FrameworkElement ExpiredNote()
    {
        var icon = UI.UI.Icon("person.crop.circle.badge.questionmark", 16, Theme.TextSecondary);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 2, 0, 0);
        var row = UI.UI.Grid("Auto,*", columnSpacing: 10);
        row.Padding = new Thickness(14, 12, 14, 12);
        row.Children.Add(icon.Col(0));
        var text = $"{SessionExpiry.Title}. Sign in again to keep using your AO3 bookmarks, subscriptions and comments, and to see restricted works.";
        row.Children.Add(UI.UI.Text(text, Theme.Style.Body).Col(1));
        AutomationProperties.SetName(row, text);
        return UI.UI.Section(null, [row]).Id("login.expired");
    }

    private bool CanSubmit =>
        !AppHost.Auth.IsAuthenticating && _username is { } u && _password is { } p && u.Text.Length > 0 && p.Password.Length > 0;

    private void UpdateSubmit()
    {
        if (_submit is null) return;
        var busy = AppHost.Auth.IsAuthenticating;
        _submit.Content = busy
            ? new ProgressRing { IsActive = true, Width = 18, Height = 18 }
            : UI.UI.Text("Log in", wrap: false);
        AutomationProperties.SetName(_submit, busy ? "Logging in" : "Log in");
        _submit.IsEnabled = CanSubmit;
        if (_username is not null) _username.IsEnabled = !busy;
        if (_password is not null) _password.IsEnabled = !busy;
    }

    private void UpdateError()
    {
        if (_errorSlot is null) return;
        _errorSlot.Children.Clear();
        if (AppHost.Auth.LastError is not { } error) return;
        var icon = UI.UI.Icon("exclamationmark.triangle.fill", 16, Theme.Danger);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 2, 0, 0);
        var row = UI.UI.Grid("Auto,*", columnSpacing: 10);
        row.Padding = new Thickness(14, 12, 14, 12);
        row.Children.Add(icon.Col(0));
        row.Children.Add(UI.UI.Text(error, Theme.Style.Body, Theme.Danger, selectable: true).Col(1));
        AutomationProperties.SetName(row, error);
        AutomationProperties.SetLiveSetting(row, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Assertive);
        _errorSlot.Children.Add(UI.UI.Section(null, [row]).Id("login.error"));
    }

    private void Submit()
    {
        if (!CanSubmit) return;
        _ = SubmitAsync(_username!.Text, _password!.Password);
    }

    private async Task SubmitAsync(string username, string password)
    {
        var auth = AppHost.Auth;
        UpdateSubmit();
        MainWindow.Current.Announce("Logging in");
        await auth.LoginAsync(AppHost.Client, username, password);
        if (auth.HasSession)
        {
            MainWindow.Current.Announce($"Logged in as {auth.Username}");
            // Pop back to wherever the sign-in was opened from.
            Navigator.Remove(this);
            return;
        }
        UpdateSubmit();
        UpdateError();
        if (auth.LastError is { } error) MainWindow.Current.Announce($"Login failed. {error}");
        _password?.Focus(FocusState.Programmatic);
        _password?.SelectAll();
    }

    private async Task LogOutAsync()
    {
        await AppHost.Auth.LogoutAsync(AppHost.Client);
        Render();
        MainWindow.Current.Announce("Logged out");
    }
}
