using Fanficly.App.Shell;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace Fanficly.App.Views.Search;

/// <summary>SwiftUI's ShareLink on Windows: the system Share sheet for a link,
/// with a title and a message. Falls back to copying the link when the Share
/// sheet isn't available.</summary>
internal static class ShareLink
{
    private static (string Title, Uri Url, string Message)? _pending;
    private static bool _hooked;

    public static void Share(string title, Uri url, string message)
    {
        try
        {
            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Current);
            var manager = DataTransferManagerInterop.GetForWindow(hwnd);
            if (!_hooked)
            {
                manager.DataRequested += OnDataRequested;
                _hooked = true;
            }
            _pending = (title, url, message);
            DataTransferManagerInterop.ShowShareUIForWindow(hwnd);
        }
        catch (Exception e)
        {
            AppHost.Log($"Share sheet failed: {e.Message}");
            var package = new DataPackage();
            package.SetText(url.ToString());
            Clipboard.SetContent(package);
            MainWindow.Current.ShowMessage("Link copied", title, InfoBarSeverity.Success);
        }
    }

    private static void OnDataRequested(DataTransferManager sender, DataRequestedEventArgs args)
    {
        if (_pending is not { } p) return;
        var data = args.Request.Data;
        data.Properties.Title = p.Title;
        data.Properties.Description = p.Message;
        data.SetWebLink(p.Url);
        data.SetText($"{p.Message} {p.Url}");
    }
}
