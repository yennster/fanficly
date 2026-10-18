using Fanficly.App.Platform;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Settings;

/// <summary>Settings → About (SettingsView's About section): the version, the
/// source, feedback, and the Microsoft Store rating page.</summary>
public sealed class AboutScreen : Screen
{
    public const string SourceUrl = "https://github.com/yennster/fanficly";

    /// <summary>Pre-filled feedback email (subject percent-encoded so it survives the mailto).</summary>
    public const string FeedbackMailto = "mailto:jenny+fanficly@jennyplunkett.me?subject=Fanficly%20feedback";

    public AboutScreen() => Title = "About";

    protected override FrameworkElement Build()
    {
        var version = UI.UI.Text(AppHost.AppVersion, foreground: Theme.TextSecondary, selectable: true);
        AutomationProperties.SetAutomationId(version, "settings.version");

        var rate = SettingsKit.LinkRow("Rate Fanficly in the Microsoft Store",
            () => _ = StoreReviewRequester.OpenStoreReviewPageAsync(), "star", automationId: "settings.rate", chevron: false);
        ToolTipService.SetToolTip(rate, "Opens Fanficly's page in the Microsoft Store");

        var page = UI.UI.VStack(18,
            UI.UI.HStack(14,
                new Image
                {
                    Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri("ms-appx:///Assets/Square44x44Logo.targetsize-64.png")),
                    Width = 56,
                    Height = 56,
                }.A11yHidden(),
                UI.UI.VStack(2,
                    UI.UI.Text("Fanficly", Theme.Style.Title2).A11yHeading(),
                    UI.UI.Secondary("A reader for Archive of Our Own. No servers, no tracking.", Theme.Style.Body))
                    .Also(s => s.VerticalAlignment = VerticalAlignment.Center)),
            UI.UI.Section("About",
            [
                UI.UI.SettingsRow("Version", version),
                SettingsKit.LinkRow("Source on GitHub", () => _ = SettingsKit.OpenUriAsync(SourceUrl),
                    "chevron.left.forwardslash.chevron.right", automationId: "settings.source", chevron: false),
                SettingsKit.LinkRow("Send feedback", () => _ = SettingsKit.OpenUriAsync(FeedbackMailto), "envelope",
                    automationId: "settings.feedback", chevron: false),
                rate,
            ]));
        return SettingsKit.Page(page, "settings.about.page");
    }
}
