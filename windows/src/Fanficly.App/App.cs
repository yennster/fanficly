using Fanficly.App.Shell;
using Fanficly.Core;
using Fanficly.App.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.XamlTypeInfo;
using Microsoft.Windows.AppLifecycle;

namespace Fanficly.App;

/// <summary>
/// The WinUI application. The UI is built in code, so the app supplies the
/// XAML type metadata for the WinUI control library itself (normally
/// generated from XAML markup).
/// </summary>
public sealed partial class App : Application, IXamlMetadataProvider
{
    private readonly XamlControlsXamlMetaDataProvider _metadata = new();

    public static new App Current => (App)Application.Current;
    public MainWindow? Window { get; private set; }

    public App()
    {
        UnhandledException += (_, e) => UnexpectedErrors.OnXamlUnhandled(e);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Resources.MergedDictionaries.Add(new XamlControlsResources());
        Theme.InstallAccent(Resources);

        AppHost.Initialize();

        Window = new MainWindow { RootFactory = Views.Tabs.Root };
        AppHost.OnWindowCreated(Window);
        Views.Settings.AppearanceSettings.Apply();
        Views.Library.RestoreBanner.Attach(Window.MessagesHost);
        Views.Library.EpubImportBanner.Attach(Window.MessagesHost);
        Window.Start(AppHost.InitialTab);
        Window.Activate();
        Window.MaximizeIfItWasMaximized();
        if (AppHost.IsIconGallery) Window.Navigator.Push(new Views.Shared.IconGalleryScreen());
        // Before the 17+ gate can be answered: given already means an update,
        // not a fresh install (What's New, #422).
        var isExistingUser = KeyValueStores.Default.GetBool(Fanficly.Core.ContentControl.AgeConfirmedKey);
        _ = Views.Account.ContentSafetyViews.EnsureAgeGateAsync();

        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        AppHost.HandleActivation(activation, isLaunch: true);
        Views.Settings.WhatsNewDialog.CheckAtLaunch(isExistingUser, openedIntoContent: !IsPlainLaunch(activation));
    }

    /// <summary>Started from Start, the taskbar or a shortcut, with no link,
    /// file, share, jump-list or notification arguments.</summary>
    private static bool IsPlainLaunch(AppActivationArguments args) =>
        args.Kind == ExtendedActivationKind.Launch
        && (args.Data is not Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs l || string.IsNullOrWhiteSpace(l.Arguments));

    /// <summary>A second launch redirected here (see Program).</summary>
    internal static void OnRedirectedActivation(AppActivationArguments args)
    {
        var window = Current?.Window;
        window?.DispatcherQueue.TryEnqueue(() =>
        {
            AppHost.HandleActivation(args, isLaunch: false);
            window.Activate();
            AppHost.BringToFront(window);
        });
    }

    public IXamlType GetXamlType(Type type) => _metadata.GetXamlType(type);
    public IXamlType GetXamlType(string fullName) => _metadata.GetXamlType(fullName);
    public XmlnsDefinition[] GetXmlnsDefinitions() => _metadata.GetXmlnsDefinitions();
}
