using Fanficly.App.Shell;
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
        UnhandledException += (_, e) =>
        {
            AppHost.Log($"Unhandled: {e.Exception}");
            e.Handled = true;
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Resources.MergedDictionaries.Add(new XamlControlsResources());
        Theme.InstallAccent(Resources);

        AppHost.Initialize();

        Window = new MainWindow { RootFactory = Views.Tabs.Root };
        AppHost.OnWindowCreated(Window);
        Window.Start(AppHost.InitialTab);
        Window.Activate();

        AppHost.HandleActivation(AppInstance.GetCurrent().GetActivatedEventArgs(), isLaunch: true);
    }

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
