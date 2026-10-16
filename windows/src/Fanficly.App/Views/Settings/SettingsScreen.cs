using System.ComponentModel;
using Fanficly.App.Platform;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Settings;

/// <summary>
/// The Settings tab (SettingsView): account, reader, appearance, library,
/// sync, notifications, content &amp; safety, input, privacy and about, as
/// grouped cards in the Windows 11 Settings style. Reader settings, sync,
/// keyboard shortcuts, privacy and about open as sub-pages.
/// </summary>
public sealed class SettingsScreen : Screen
{
    /// <summary>"library.showReadingProgress": the Library rows' progress bar.</summary>
    public const string ShowReadingProgressKey = "library.showReadingProgress";

    private readonly StackPanel _accountHost = new();
    private readonly StackPanel _notificationsHost = new();
    private Expander? _controllerExpander;
    private TextBlock? _controllerStatus;
    private Button? _syncRow;
    private bool _signingOut;
    private bool _appearing;

    public SettingsScreen() => Title = "Settings";

    protected override FrameworkElement Build()
    {
        AutomationProperties.SetAutomationId(_accountHost, "settings.account");
        RefreshAccount();
        RefreshNotifications();

        var page = UI.UI.VStack(18,
            _accountHost,
            UI.UI.Section("Reader",
            [
                SettingsKit.LinkRow("Theme & typography", () => Navigator.Push(new ReaderSettingsScreen()), "textformat",
                    "Profiles, fonts, spacing, page layout and Listen", automationId: "settings.reader"),
            ]),
            AppearanceSection(),
            UI.UI.Section("Library",
            [
                SettingsKit.ToggleRow("Show reading progress",
                    KeyValueStores.Default.GetBool(ShowReadingProgressKey, true),
                    on => KeyValueStores.Default.SetBool(ShowReadingProgressKey, on),
                    "chart.bar.xaxis", automationId: "settings.showReadingProgress"),
            ], footer: "Shows a progress bar and percentage on works you've started. Your reading position is always saved — this only hides the display."),
            SyncSection(),
            _notificationsHost,
            // The Content & Safety section (mature filter, hidden works, content policy):
            // Views.Account.ContentSafetyViews.Section(), // wired at merge
            InputSection(),
            UI.UI.Section("Privacy",
            [
                SettingsKit.LinkRow("What this app sees and stores", () => Navigator.Push(new PrivacyScreen()), "hand.raised",
                    automationId: "settings.privacy"),
            ]),
            UI.UI.Section("About",
            [
                SettingsKit.LinkRow("About Fanficly", () => Navigator.Push(new AboutScreen()), "info.circle",
                    $"Version {AppHost.AppVersion}", automationId: "settings.about"),
            ]));
        return SettingsKit.Page(page, "settings.list");
    }

    public override void OnAppearing()
    {
        if (_appearing) return;
        _appearing = true;
        AppHost.Auth.PropertyChanged += OnAuthChanged;
        GamepadInput.ControllersChanged += RefreshController;
        if (MainWindow.Current is { } window) window.Activated += OnWindowActivated;
        if (IsBuilt)
        {
            // Sign-in, sync and notification state can change while away
            // (the sign-in page, Windows Settings, a controller plugged in).
            RefreshAccount();
            RefreshNotifications();
            RefreshSyncRow();
            RefreshController();
        }
    }

    public override void OnDisappearing()
    {
        if (!_appearing) return;
        _appearing = false;
        AppHost.Auth.PropertyChanged -= OnAuthChanged;
        GamepadInput.ControllersChanged -= RefreshController;
        if (MainWindow.Current is { } window) window.Activated -= OnWindowActivated;
    }

    private void OnAuthChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AuthState.Username) or null)
            MainWindow.Current?.DispatcherQueue.TryEnqueue(RefreshAccount);
    }

    /// <summary>Coming back from Windows Settings: notification permission may have changed.</summary>
    private void OnWindowActivated(object sender, WindowActivatedEventArgs e)
    {
        if (e.WindowActivationState != WindowActivationState.Deactivated) RefreshNotifications();
    }

    // MARK: - Account

    private void RefreshAccount()
    {
        _accountHost.Children.Clear();
        var username = AppHost.Auth.Username;
        UIElement trailing;
        if (username is null)
        {
            trailing = UI.UI.Button("Sign In", Routes.OpenLogin, kind: UI.UI.ButtonKind.Accent)
                .Also(b => AutomationProperties.SetAutomationId(b, "settings.signIn"));
        }
        else
        {
            trailing = UI.UI.Button(_signingOut ? "Signing Out…" : "Sign Out", () => _ = SignOutAsync(), kind: UI.UI.ButtonKind.Destructive)
                .Also(b => { b.IsEnabled = !_signingOut; AutomationProperties.SetAutomationId(b, "settings.signOut"); });
        }
        var row = UI.UI.SettingsRow("AO3 Login", trailing,
            username is null ? "Not signed in" : $"Signed in as {username}", "person.crop.circle");
        _accountHost.Children.Add(UI.UI.Section("Account", [row],
            footer: username is null
                ? "Sign in to subscribe to works on AO3, see your AO3 bookmarks and subscriptions, and comment. Credentials go directly to AO3 — Fanficly never stores your password, only the resulting session cookie, encrypted for your Windows account."
                : "Signing out clears the session cookie from this PC. Your offline library stays on the device."));
    }

    private async Task SignOutAsync()
    {
        if (_signingOut) return;
        _signingOut = true;
        RefreshAccount();
        try
        {
            await AppHost.Auth.LogoutAsync(AppHost.Client);
            // The login-gated tabs rebuild for the signed-out state next time they open.
            MainWindow.Current.ResetRoot(SidebarItem.Bookmarks);
            MainWindow.Current.ResetRoot(SidebarItem.Subscriptions);
            MainWindow.Current.Announce("Signed out of AO3");
        }
        catch (Exception e)
        {
            AppHost.Log($"Sign out failed: {e.Message}");
            await Dialogs.AlertAsync("Couldn't Sign Out", e.Message);
        }
        finally
        {
            _signingOut = false;
            RefreshAccount();
        }
    }

    // MARK: - Appearance

    private static StackPanel AppearanceSection()
    {
        var combo = SettingsKit.Choice("App theme", AppearanceSettings.Options.Select(o => (o.Raw, o.Name)),
            AppearanceSettings.Current, raw => AppearanceSettings.Current = raw);
        AutomationProperties.SetAutomationId(combo, "settings.theme");
        return UI.UI.Section("Appearance",
        [
            UI.UI.SettingsRow("App theme", combo, "Light or dark, or follow your Windows setting", "circle.lefthalf.filled"),
        ], footer: "Stories keep their own page theme, set in Theme & typography.");
    }

    // MARK: - Sync

    private StackPanel SyncSection()
    {
        _syncRow = SettingsKit.LinkRow("Sync across devices", () => Navigator.Push(new SyncSettingsScreen()),
            "arrow.triangle.2.circlepath", SyncSubtitle(), automationId: "settings.sync");
        return UI.UI.Section("Sync", [_syncRow]);
    }

    private static string SyncSubtitle()
    {
        if (!AppHost.Sync.IsSyncEnabled) return "Off — back up and share your library through OneDrive or iCloud Drive";
        var folder = AppHost.Sync.SyncFolder;
        return string.IsNullOrEmpty(folder) ? "On — choose a sync folder" : $"On · {folder}";
    }

    private void RefreshSyncRow()
    {
        if (_syncRow is null) return;
        var index = _syncRow.Parent is Panel p ? p.Children.IndexOf(_syncRow) : -1;
        if (index < 0) return;
        var parent = (Panel)_syncRow.Parent;
        _syncRow = SettingsKit.LinkRow("Sync across devices", () => Navigator.Push(new SyncSettingsScreen()),
            "arrow.triangle.2.circlepath", SyncSubtitle(), automationId: "settings.sync");
        parent.Children[index] = _syncRow;
    }

    // MARK: - Notifications

    private void RefreshNotifications()
    {
        _notificationsHost.Children.Clear();
        var enabled = Notifications.IsEnabled;
        var open = UI.UI.Button("Open Windows notification settings", () => _ = Notifications.OpenSystemSettingsAsync(),
            "arrow.up.right.square");
        AutomationProperties.SetAutomationId(open, "settings.notifications.open");
        var status = UI.UI.SettingsRow("Notifications", open,
            enabled ? "On — Fanficly can tell you about new chapters and new works."
                    : "Off — Windows won't show Fanficly's new-chapter and new-work alerts.",
            "bell");
        _notificationsHost.Children.Add(UI.UI.Section("Notifications", [status],
            footer: "Fanficly checks the works and authors you follow, and your AO3 subscriptions, in the background and posts a notification when something new appears. Click a notification to open what it's about."));
    }

    // MARK: - Input

    private StackPanel InputSection()
    {
        _controllerStatus = UI.UI.Secondary("", Theme.Style.Footnote);
        var header = UI.UI.Grid("Auto,*", columnSpacing: 12);
        header.Children.Add(UI.UI.Icon("gamecontroller", 16, Theme.Accent).Also(i => i.VerticalAlignment = VerticalAlignment.Center).Col(0));
        header.Children.Add(UI.UI.VStack(1, UI.UI.Text("Xbox controller"), _controllerStatus).Col(1));

        var map = UI.UI.Grid("Auto,*", columnSpacing: 16, rowSpacing: 6);
        var mapRows = ControllerMap;
        for (var i = 0; i < mapRows.Count; i++)
        {
            if (map.RowDefinitions.Count <= i) map.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            map.Children.Add(UI.UI.Text(mapRows[i].Button, Theme.Style.Headline).Col(0).Row(i));
            map.Children.Add(UI.UI.Secondary(mapRows[i].Action, Theme.Style.Body).Col(1).Row(i));
        }

        _controllerExpander = new Expander
        {
            Header = header,
            Content = UI.UI.VStack(10,
                UI.UI.Secondary("Any Xbox or XInput controller works: plug it in or pair it over Bluetooth.", Theme.Style.Footnote),
                map),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetAutomationId(_controllerExpander, "settings.controller");
        RefreshController();

        return UI.UI.VStack(2,
            UI.UI.SectionHeader("Input"),
            UI.UI.VStack(6,
                _controllerExpander,
                UI.UI.Section(null,
                [
                    SettingsKit.LinkRow("Keyboard shortcuts", () => Navigator.Push(new ShortcutsScreen()), "keyboard",
                        "Tabs, zoom, full screen, back, and page turns in the reader", automationId: "settings.shortcuts"),
                ])));
    }

    /// <summary>What each controller button does (GamepadInput's mapping).</summary>
    internal static readonly IReadOnlyList<(string Button, string Action)> ControllerMap =
    [
        ("A", "Select the focused item"),
        ("B", "Go back"),
        ("D-pad / left stick", "Move between items; turn pages in the reader"),
        ("LB / RB", "Previous / next sidebar tab"),
        ("LT / RT", "Previous / next page in the reader"),
        ("Right stick", "Scroll"),
        ("View", "Full screen"),
        ("Menu", "Show or hide the sidebar"),
    ];

    private void RefreshController()
    {
        if (_controllerStatus is null || _controllerExpander is null) return;
        var connected = GamepadInput.HasController;
        _controllerStatus.Text = connected ? "Connected" : "Not connected";
        AutomationProperties.SetName(_controllerExpander, connected ? "Xbox controller, connected" : "Xbox controller, not connected");
    }
}
