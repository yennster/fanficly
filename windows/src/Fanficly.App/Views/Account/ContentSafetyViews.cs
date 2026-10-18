using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using ContentControl = Fanficly.Core.ContentControl;

namespace Fanficly.App.Views.Account;

/// <summary>
/// The UGC safeguards' screens (ContentSafetyViews.swift): the first-launch
/// 17+ confirmation, the Settings "Content &amp; Safety" section (the
/// Mature/Explicit filter, hidden works, the content policy), the hidden-works
/// list and the content policy itself.
/// </summary>
public static class ContentSafetyViews
{
    /// <summary>The developer's feedback address (SettingsView.feedbackMailto).</summary>
    public static readonly Uri FeedbackMailto = new("mailto:jenny+fanficly@jennyplunkett.me?subject=Fanficly%20feedback");

    // MARK: - Settings section

    /// <summary>
    /// The Settings page's "Content &amp; Safety" section: the "Filter mature
    /// &amp; explicit works" toggle (content.filterMatureExplicit, default on),
    /// and rows that push Hidden works and Content policy. Add it to the
    /// Settings page's stack where SettingsView has it (after the sync section,
    /// before Privacy).
    /// </summary>
    public static UIElement Section()
    {
        var toggle = UI.UI.Toggle(
            KeyValueStores.Default.GetBool(ContentControl.FilterMatureKey, true),
            on =>
            {
                KeyValueStores.Default.SetBool(ContentControl.FilterMatureKey, on);
                // The setting rides along in library backups.
                LibrarySyncManager.QueueBackupShared(AppHost.Library);
            },
            "Filter mature & explicit works").Id("settings.filterMature");

        return UI.UI.Section("Content & Safety",
            [
                UI.UI.SettingsRow("Filter mature & explicit works", toggle),
                UI.UI.NavRow(UI.UI.Text("Hidden works"), OpenHiddenWorks, "Hidden works").Id("settings.hiddenWorks"),
                UI.UI.NavRow(UI.UI.Text("Content policy"), OpenContentPolicy, "Content policy").Id("settings.contentPolicy"),
            ],
            footer: "Fanficly shows works from Archive of Our Own, which are created by other users. Filtering hides Mature- and Explicit-rated works; hiding removes individual works from your results.");
    }

    public static void OpenHiddenWorks() => MainWindow.Current.Navigator.Push(new HiddenWorksScreen());

    public static void OpenContentPolicy() => MainWindow.Current.Navigator.Push(new ContentPolicyScreen());

    // MARK: - Age gate

    private static Task? _gate;

    /// <summary>
    /// The first-launch 17+ confirmation (AgeGateView, a full-screen cover over
    /// RootView). Covers the window's content until the user confirms, then
    /// stores content.ageConfirmed and completes. Completes at once when already
    /// confirmed, and in demo mode (so screenshot automation isn't blocked).
    /// Call it once the window has its first tab on screen.
    /// </summary>
    public static Task EnsureAgeGateAsync()
    {
        if (AppHost.IsDemoMode || KeyValueStores.Default.GetBool(ContentControl.AgeConfirmedKey)) return Task.CompletedTask;
        return _gate ??= ShowAgeGateAsync();
    }

    private static async Task ShowAgeGateAsync()
    {
        var window = MainWindow.Current;
        var root = window.RootElement;
        var done = new TaskCompletionSource();

        // Hide (not just cover) the content so Tab and Narrator can't reach it.
        var hidden = new List<UIElement>();
        foreach (var child in root.Children)
        {
            if (child is FrameworkElement fe && Grid.GetRow(fe) >= 1 && child.Visibility == Visibility.Visible)
            {
                hidden.Add(child);
                child.Visibility = Visibility.Collapsed;
            }
        }

        var confirm = new Button
        {
            Content = UI.UI.Text("I'm 17 or older", Theme.Style.Headline, wrap: false),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(12, 10, 12, 10),
        }.Id("agegate.confirm");
        UI.UI.ApplyKind(confirm, UI.UI.ButtonKind.Accent);
        AutomationProperties.SetName(confirm, "I'm 17 or older");

        var policy = new HyperlinkButton
        {
            Content = UI.UI.Text("Read the content policy", Theme.Style.Subheadline, Theme.Accent, wrap: false),
            HorizontalAlignment = HorizontalAlignment.Center,
        }.Id("agegate.policy");
        AutomationProperties.SetName(policy, "Read the content policy");
        policy.Click += (_, _) => _ = Dialogs.SheetAsync("Content policy", ContentPolicyContent(includeTitle: false), close: "Done", width: 560);

        var intro = UI.UI.Text("", Theme.Style.Body, Theme.TextSecondary);
        intro.TextAlignment = TextAlignment.Center;
        intro.Inlines.Add(new Run { Text = "Fanficly is a reader for fiction published on Archive of Our Own. Some works contain mature themes. You must be " });
        intro.Inlines.Add(new Run { Text = "17 or older", FontWeight = FontWeights.Bold });
        intro.Inlines.Add(new Run { Text = " to continue." });

        var title = UI.UI.Text("Welcome to Fanficly", Theme.Style.LargeTitle).A11yHeading();
        title.FontWeight = FontWeights.Bold;
        title.TextAlignment = TextAlignment.Center;
        AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);

        var terms = UI.UI.Text("By continuing you agree to the content policy and the Microsoft Store's standard application license terms.",
            Theme.Style.Caption2, Theme.TextTertiary);
        terms.TextAlignment = TextAlignment.Center;

        var top = UI.UI.VStack(24,
            UI.UI.Icon("book.closed.fill", 56, Theme.Accent).Also(i => i.HorizontalAlignment = HorizontalAlignment.Center),
            title,
            intro);
        var bottom = UI.UI.VStack(12, confirm, policy, terms);

        var layout = UI.UI.Grid("*", "*,Auto,*,Auto", rowSpacing: 24);
        layout.MaxWidth = 480;
        layout.Padding = new Thickness(24);
        layout.Children.Add(top.Row(1));
        layout.Children.Add(bottom.Row(3));

        var overlay = new Grid
        {
            Background = SolidBackground(),
        }.Id("agegate");
        AutomationProperties.SetName(overlay, "Welcome to Fanficly");
        overlay.Children.Add(layout);
        Grid.SetRow(overlay, 1);
        Grid.SetRowSpan(overlay, Math.Max(1, root.RowDefinitions.Count - 1));
        root.Children.Add(overlay);

        confirm.Click += (_, _) =>
        {
            KeyValueStores.Default.SetBool(ContentControl.AgeConfirmedKey, true);
            root.Children.Remove(overlay);
            foreach (var child in hidden) child.Visibility = Visibility.Visible;
            done.TrySetResult();
        };
        overlay.Loaded += (_, _) =>
        {
            confirm.Focus(FocusState.Programmatic);
            window.Announce("Welcome to Fanficly. You must be 17 or older to continue.");
        };

        await done.Task;
    }

    /// <summary>The window's opaque base fill (Fluent's SolidBackgroundFillColorBase).</summary>
    private static Brush SolidBackground() =>
        Application.Current.Resources.TryGetValue("SolidBackgroundFillColorBaseBrush", out var brush) && brush is Brush b
            ? b
            : Theme.CardBackground;

    // MARK: - Content policy

    /// <summary>The content policy / acceptable-use statement (ContentPolicyView).</summary>
    internal static FrameworkElement ContentPolicyContent(bool includeTitle = true)
    {
        static UIElement Part(string heading, string body) => UI.UI.VStack(6,
            UI.UI.Text(heading, Theme.Style.Headline).A11yHeading(),
            UI.UI.Secondary(body, Theme.Style.Body).Also(t => t.IsTextSelectionEnabled = true));

        var email = new HyperlinkButton
        {
            Content = UI.UI.Text("Email the developer", Theme.Style.Subheadline, Theme.Accent),
            NavigateUri = FeedbackMailto,
            Padding = new Thickness(0, 4, 0, 4),
            Margin = new Thickness(0, 4, 0, 0),
        }.Id("policy.email");
        AutomationProperties.SetName(email, "Email the developer");

        var stack = UI.UI.VStack(16,
            includeTitle ? UI.UI.Text("Content policy", Theme.Style.Title2).A11yHeading() : null,
            Part("Where the writing comes from",
                "Fanficly is a reader for works published on Archive of Our Own (AO3). All stories are created and hosted by AO3 and its users. Fanficly is not affiliated with AO3 or the Organization for Transformative Works, and does not host, edit, or moderate the works itself."),
            Part("No objectionable content",
                "We do not tolerate content that is illegal or that sexualizes minors. Works are rated by their authors; Fanficly lets you filter Mature and Explicit ratings and hide any individual work."),
            Part("Reporting",
                "Every work has a “Report this work” action (in the … menu) that opens AO3's official abuse-report form — AO3 is the host and can remove content. You can also email us, and we review reports about the app within 24 hours."),
            Part("Your controls",
                "• Mature/Explicit filtering (Settings → Content & Safety).\n• Hide any work from your results.\n• You confirmed you are 17 or older on first launch."),
            email);
        return stack;
    }
}

/// <summary>The content policy as a page (pushed from Settings).</summary>
public sealed class ContentPolicyScreen : Screen
{
    public ContentPolicyScreen()
    {
        Title = "Content policy";
    }

    protected override FrameworkElement Build() =>
        UI.UI.Scroll(ContentSafetyViews.ContentPolicyContent(includeTitle: false), maxWidth: 720);
}

/// <summary>
/// Works the user has hidden (HiddenWorksView), newest first. Unhide puts a
/// work back in search and browse results — the swipe action becomes an
/// Unhide button on the row, the row's context menu and the Delete key.
/// </summary>
public sealed class HiddenWorksScreen : Screen
{
    private readonly Grid _host = new();
    private VirtualList<HiddenWork>? _list;

    public HiddenWorksScreen()
    {
        Title = "Hidden works";
    }

    protected override FrameworkElement Build()
    {
        Render();
        return _host;
    }

    public override void OnAppearing()
    {
        if (IsBuilt) Render();
    }

    private void Render()
    {
        var hidden = AppHost.Library.All<HiddenWork>().OrderByDescending(h => h.HiddenAt).ToList();
        FrameworkElement content;
        if (hidden.Count == 0)
        {
            content = UI.UI.EmptyState("eye", "Nothing hidden",
                "Use the … menu on a work and choose “Hide this work” to keep it out of your search and browse results.");
        }
        else
        {
            _list ??= new VirtualList<HiddenWork>((h, _) => BuildRow(h), spacing: 0, maxWidth: 860)
                .Also(l => { l.Element.Id("hiddenWorks.list"); AutomationProperties.SetName(l.Element, "Hidden works"); });
            _list.Reset(hidden);
            content = _list.Element;
        }
        if (_host.Children.Count == 1 && _host.Children[0] == content) return;
        _host.Children.Clear();
        _host.Children.Add(content);
    }

    private UIElement BuildRow(HiddenWork item)
    {
        var title = item.Title.Length == 0 ? $"Work #{item.Ao3Id}" : item.Title;
        var when = $"Hidden {AccountKit.RelativeNamed(item.HiddenAt)}";
        var unhide = UI.UI.Button("Unhide", () => Unhide(item), "eye").Id($"hiddenWorks.unhide.{item.Ao3Id}");
        AutomationProperties.SetName(unhide, $"Unhide {title}");
        unhide.VerticalAlignment = VerticalAlignment.Center;

        var labels = UI.UI.VStack(2, UI.UI.Text(title), UI.UI.Caption(when));
        labels.VerticalAlignment = VerticalAlignment.Center;
        var row = UI.UI.Grid("*,Auto", columnSpacing: 12);
        row.Padding = new Thickness(14, 10, 14, 10);
        row.Children.Add(labels.Col(0));
        row.Children.Add(unhide.Col(1));
        row.ContextFlyout = UI.UI.Menu(UI.UI.MenuItem("Unhide", () => Unhide(item), "eye"));
        AutomationProperties.SetName(row, $"{title}, {when}");
        row.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Delete) { e.Handled = true; Unhide(item); }
        };
        return UI.UI.VStack(0, row, UI.UI.Divider(14));
    }

    private void Unhide(HiddenWork item)
    {
        var title = item.Title.Length == 0 ? $"Work #{item.Ao3Id}" : item.Title;
        HiddenWorkStore.Unhide(item.Ao3Id, AppHost.Library);
        Render();
        MainWindow.Current.Announce($"{title} unhidden");
    }
}
