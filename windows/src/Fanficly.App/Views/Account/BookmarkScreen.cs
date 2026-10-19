using System.ComponentModel;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Account;

/// <summary>
/// Creates or edits the signed-in user's AO3 bookmark for a work: notes, their
/// own tags, rec and private (AO3BookmarkSheet). Loads AO3's own form from the
/// work page (prefilled when the work is already bookmarked) and posts it back,
/// so the field names and CSRF token come from AO3 rather than being hardcoded.
/// The Mac shows a sheet; here it's a pushed screen that pops itself on Save
/// or Cancel.
/// </summary>
public sealed class BookmarkScreen : Screen
{
    private readonly int _workId;
    private readonly ScrollViewer _scroll = new()
    {
        HorizontalScrollMode = ScrollMode.Disabled,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
    };
    private AO3BookmarkForm? _form;
    private string? _formUser;
    private CancellationTokenSource? _loadCts;
    private bool _isLoading;
    private string? _loadError;
    /// <summary>The load failed because the session is gone: offer Log In.</summary>
    private bool _loadNeedsSignIn;
    private bool _isSaving;
    private string? _saveError;
    private TextBox? _notes;
    private TextBox? _tags;
    private ToggleSwitch? _rec;
    private ToggleSwitch? _private;
    private Button? _save;
    private TextBlock? _saveErrorText;
    private bool _isVisible;
    private bool _isRemoved;

    public BookmarkScreen(int workId, string workTitle)
    {
        _workId = workId;
        Title = "Bookmark on AO3";
        Subtitle = string.IsNullOrWhiteSpace(workTitle) ? null : workTitle;
    }

    protected override FrameworkElement Build()
    {
        AppHost.Auth.PropertyChanged += OnAuthChanged;
        Render();
        _ = LoadAsync();
        return _scroll;
    }

    public override void OnAppearing()
    {
        _isVisible = true;
        // Returning from Log In: load the form in place of the sign-in prompt.
        if (IsBuilt) { Render(); _ = LoadAsync(); }
    }

    public override void OnDisappearing() => _isVisible = false;

    /// <summary>A save in flight isn't cancelled: the POST may already have
    /// reached AO3, so it finishes and its result is still announced.</summary>
    public override void OnRemoved()
    {
        _isRemoved = true;
        AppHost.Auth.PropertyChanged -= OnAuthChanged;
        _loadCts?.Cancel();
    }

    private void OnAuthChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(AuthState.Username)) return;
        AccountKit.OnUIThread(() =>
        {
            if (!_isVisible) return;
            Render();
            _ = LoadAsync();
        });
    }

    // MARK: - Load

    private async Task LoadAsync()
    {
        var username = AppHost.Auth.Username;
        // Another account's form (its token and pseud) must never be posted.
        if (_formUser != username) _form = null;
        if (username is null || _form is not null || _isLoading) return;
        _loadCts?.Cancel();
        var cts = _loadCts = new CancellationTokenSource();
        _isLoading = true;
        _loadError = null;
        _loadNeedsSignIn = false;
        Render();
        try
        {
            var form = await AppHost.Client.FetchBookmarkFormAsync(_workId, cts.Token);
            if (cts.IsCancellationRequested) return;
            _form = form;
            _formUser = username;
        }
        catch (Exception) when (cts.IsCancellationRequested)
        {
            return;
        }
        catch (AO3Exception e) when (e.Kind == AO3ErrorKind.Unauthorized)
        {
            _loadError = "Your AO3 session has expired. Sign in again to bookmark this work.";
            _loadNeedsSignIn = true;
        }
        catch (Exception e)
        {
            _loadError = Message(e);
        }
        finally
        {
            if (_loadCts == cts) _isLoading = false;
        }
        Render();
        if (_loadError is not null) MainWindow.Current.Announce($"Couldn't load your bookmark. {_loadError}");
    }

    // MARK: - Content

    private void Render()
    {
        Title = _form?.IsExisting == true ? "Edit Bookmark" : "Bookmark on AO3";
        ClearEditor();
        FrameworkElement content;
        if (AppHost.Auth.Username is null)
            content = UI.UI.EmptyState("person.crop.circle.badge.questionmark", "Log in to bookmark",
                "Log in to AO3 to bookmark this work on AO3.", "Log In", Routes.OpenLogin).Id("bookmark.login");
        else if (_form is { } form && _formUser == AppHost.Auth.Username)
            content = Editor(form);
        else if (_loadError is not null && !_isLoading)
            content = LoadErrorState(_loadError);
        else
            content = UI.UI.Loading("Loading…");
        _scroll.Content = content;
    }

    /// <summary>"Couldn't load your bookmark" with Retry, plus Log In when the
    /// session has expired.</summary>
    private FrameworkElement LoadErrorState(string message)
    {
        var state = UI.UI.EmptyState("exclamationmark.triangle", "Couldn't load your bookmark", message);
        var retry = UI.UI.Button("Retry", () => _ = LoadAsync(),
            kind: _loadNeedsSignIn ? UI.UI.ButtonKind.Standard : UI.UI.ButtonKind.Accent).Id("bookmark.retry");
        var actions = _loadNeedsSignIn
            ? UI.UI.HStack(8, UI.UI.Button("Log In", Routes.OpenLogin, kind: UI.UI.ButtonKind.Accent).Id("bookmark.login"), retry)
            : UI.UI.HStack(8, retry);
        actions.HorizontalAlignment = HorizontalAlignment.Center;
        actions.Margin = new Thickness(0, 6, 0, 0);
        if (state is StackPanel stack) stack.Children.Add(actions);
        return state;
    }

    private void ClearEditor()
    {
        _notes = null;
        _tags = null;
        _rec = null;
        _private = null;
        _save = null;
        _saveErrorText = null;
    }

    private StackPanel Editor(AO3BookmarkForm form)
    {
        var body = new StackPanel
        {
            Spacing = 20,
            MaxWidth = 640,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Margin = new Thickness(24, 8, 24, 24),
        };

        var notes = _notes = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 120,
            IsSpellCheckEnabled = true,
            Text = form.Notes,
        }.Id("bookmark.notes");
        AutomationProperties.SetName(_notes, "Notes");
        ScrollViewer.SetVerticalScrollBarVisibility(_notes, ScrollBarVisibility.Auto);
        // The text box keeps line breaks as "\r"; AO3 gets ordinary newlines.
        // Edits go to the current form, which a refresh after a failed save replaces.
        notes.TextChanged += (_, _) =>
        {
            if (_form is { } f) f.Notes = notes.Text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
        };
        body.Children.Add(UI.UI.Section("Notes", [Padded(_notes)],
            footer: "The creator's summary is added automatically."));

        var tags = _tags = new TextBox
        {
            PlaceholderText = "Your tags",
            TextWrapping = TextWrapping.Wrap,
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
            Text = form.Tags,
        }.Id("bookmark.tags");
        AutomationProperties.SetName(_tags, "Your tags");
        tags.TextChanged += (_, _) => { if (_form is { } f) f.Tags = tags.Text; };
        body.Children.Add(UI.UI.Section("Your tags", [Padded(_tags)],
            footer: "Comma separated. The creator's tags are added automatically."));

        _rec = UI.UI.Toggle(form.IsRec, on => { if (_form is { } f) f.IsRec = on; }, "Rec").Id("bookmark.rec");
        _private = UI.UI.Toggle(form.IsPrivate, on => { if (_form is { } f) f.IsPrivate = on; }, "Private bookmark").Id("bookmark.private");
        body.Children.Add(UI.UI.Section(null,
            [UI.UI.SettingsRow("Rec", _rec), UI.UI.SettingsRow("Private bookmark", _private)],
            footer: "A rec is a bookmark you recommend. A private bookmark is only visible to you."));

        _saveErrorText = UI.UI.Text("", Theme.Style.Body, Theme.Danger, selectable: true).Id("bookmark.error");
        AutomationProperties.SetLiveSetting(_saveErrorText, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Assertive);
        body.Children.Add(_saveErrorText);

        var cancel = UI.UI.Button("Cancel", () => Navigator.Remove(this)).Id("bookmark.cancel");
        _save = new Button { MinWidth = 96, MinHeight = 32 }.Id("bookmark.save");
        UI.UI.ApplyKind(_save, UI.UI.ButtonKind.Accent);
        _save.Click += (_, _) => _ = SaveAsync();
        var buttons = UI.UI.HStack(8, cancel, _save);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        body.Children.Add(buttons);
        UpdateSaving();
        return body;
    }

    private static StackPanel Padded(UIElement element) =>
        UI.UI.VStack(0, element).Also(s => s.Padding = new Thickness(14));

    private void UpdateSaving()
    {
        if (_save is not null)
        {
            _save.Content = _isSaving
                ? new ProgressRing { IsActive = true, Width = 18, Height = 18 }
                : UI.UI.Text("Save", wrap: false);
            AutomationProperties.SetName(_save, _isSaving ? "Saving bookmark" : "Save bookmark");
            _save.IsEnabled = !_isSaving;
        }
        foreach (var control in new Control?[] { _notes, _tags, _rec, _private })
            if (control is not null) control.IsEnabled = !_isSaving;
        if (_saveErrorText is not null)
        {
            _saveErrorText.Text = _saveError ?? "";
            _saveErrorText.Visibility = _saveError is null ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    // MARK: - Save

    private async Task SaveAsync()
    {
        if (_form is not { } form || _isSaving) return;
        _isSaving = true;
        _saveError = null;
        UpdateSaving();
        MainWindow.Current.Announce("Saving bookmark");
        try
        {
            // Never cancelled: leaving the screen mustn't abort a POST silently.
            await AppHost.Client.SaveBookmarkAsync(form);
            MainWindow.Current.Announce(form.IsExisting ? "Bookmark updated" : "Bookmarked on AO3");
            if (!_isRemoved) Navigator.Remove(this);
        }
        catch (Exception e)
        {
            _saveError = $"Couldn't save: {Message(e)}";
            if (_isRemoved)
            {
                MainWindow.Current.ShowMessage("Couldn't save your bookmark", Message(e), InfoBarSeverity.Error);
                return;
            }
            MainWindow.Current.Announce(_saveError);
            if (e is AO3Exception { Kind: AO3ErrorKind.Unauthorized })
            {
                // Signed out: a sign-in loads a fresh form for the new session.
                _form = null;
                _loadError = "Your AO3 session has expired. Sign in again to bookmark this work.";
                _loadNeedsSignIn = true;
                Render();
            }
            // Not when AO3 asked us to slow down.
            else if (e is not AO3Exception { Kind: AO3ErrorKind.RateLimited })
            {
                await RefreshFormAsync(form);
            }
        }
        finally
        {
            _isSaving = false;
            if (!_isRemoved)
            {
                UpdateSaving();
                // Disabling the controls while saving moved focus; give it back.
                if (_saveError is not null) _save?.Focus(FocusState.Programmatic);
            }
        }
    }

    /// <summary>After a failed save, reloads AO3's form but keeps the user's edits,
    /// so a second Save posts with a fresh token and, if the first one did land
    /// (a lost response), updates that bookmark instead of creating another. The
    /// editor already shows the edits, so it stays as it is (and keeps focus).</summary>
    private async Task RefreshFormAsync(AO3BookmarkForm edited)
    {
        var username = AppHost.Auth.Username;
        AO3BookmarkForm fresh;
        try { fresh = await AppHost.Client.FetchBookmarkFormAsync(_workId); }
        catch (Exception) { return; }
        if (_isRemoved || username != AppHost.Auth.Username || !ReferenceEquals(_form, edited)) return;
        fresh.Notes = edited.Notes;
        fresh.Tags = edited.Tags;
        fresh.IsPrivate = edited.IsPrivate;
        fresh.IsRec = edited.IsRec;
        _form = fresh;
        Title = fresh.IsExisting ? "Edit Bookmark" : "Bookmark on AO3";
    }

    private static string Message(Exception error) => error switch
    {
        AO3Exception { Kind: AO3ErrorKind.Unauthorized } => "Your AO3 session has expired. Log in again.",
        AO3Exception { Kind: AO3ErrorKind.Rejected or AO3ErrorKind.ParseFailed, Reason: { Length: > 0 } reason } => reason,
        AO3Exception { Kind: AO3ErrorKind.Http, Status: { } status } => $"AO3 returned HTTP {status}.",
        AO3Exception { Kind: AO3ErrorKind.Network, Reason: { } reason } => $"Network: {reason}",
        AO3Exception { Kind: AO3ErrorKind.RateLimited } => "AO3 is asking us to slow down. Try again in a minute.",
        _ => error.Message,
    };
}
