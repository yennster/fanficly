using Fanficly.App.Shell;
using Fanficly.App.UI;
using Microsoft.UI.Xaml;

namespace Fanficly.App.Views.Settings;

/// <summary>Settings → Privacy (PrivacyTransparencyView): what Fanficly sees and
/// stores, in plain words, with the iCloud wording adapted to the sync folder.</summary>
public sealed class PrivacyScreen : Screen
{
    public PrivacyScreen() => Title = "Privacy";

    protected override FrameworkElement Build()
    {
        var page = UI.UI.VStack(16,
            UI.UI.Text("What this app sees and stores", Theme.Style.Title2).A11yHeading(),
            UI.UI.Text("Fanficly has no servers. Everything happens on your PC."),
            Block("What we collect",
                "Nothing. No analytics, no crash reports, no device IDs, no telemetry."),
            Block("What's stored on your PC",
                "• Your AO3 session cookie (encrypted with Windows Data Protection, so only your Windows account can read it), so you stay logged in.\n"
                + "• Works you've saved offline and your reading position (in app storage).\n"
                + "• Your preferences (theme, font size).\n"
                + "• An optional backup of your library and settings in a sync folder you choose (OneDrive, iCloud Drive or similar), if Sync across devices is on. That folder's own service uploads it under your account."),
            Block("What goes off your PC",
                "Requests to archiveofourown.org so you can read, search, and log in. We never send your data anywhere else."),
            Block("How to delete everything",
                "Uninstall the app. Windows erases all of its storage, including the session cookie. A backup in your sync folder stays until you delete it (or use Clear Synced Data in Settings → Sync first). There's no server to wipe — there's no server."));
        return SettingsKit.Page(page, "settings.privacy.page");
    }

    private static FrameworkElement Block(string title, string body) => UI.UI.VStack(6,
        UI.UI.Text(title, Theme.Style.Headline).A11yHeading(),
        UI.UI.Secondary(body, Theme.Style.Body).Also(t => t.IsTextSelectionEnabled = true));
}
