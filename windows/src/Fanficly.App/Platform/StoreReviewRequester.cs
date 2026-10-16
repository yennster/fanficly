using Fanficly.App.Shell;
using Fanficly.Core;
using Windows.Services.Store;

namespace Fanficly.App.Platform;

/// <summary>The Microsoft Store's in-app rating dialog (SwiftUI's requestReview).</summary>
public sealed class StoreReviewRequester : IStoreReviewRequester
{
    public async Task RequestReviewAsync()
    {
        if (!Services.AppPaths.IsPackaged || MainWindow.Current is null) return;
        try
        {
            var context = StoreContext.GetDefault();
            WinRT.Interop.InitializeWithWindow.Initialize(context, WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Current));
            await context.RequestRateAndReviewAppAsync();
        }
        catch (Exception e)
        {
            AppHost.Log($"Rating prompt failed: {e.Message}");
        }
    }

    /// <summary>Opens the app's Store page at its reviews (Settings → About → Rate).</summary>
    public static async Task OpenStoreReviewPageAsync()
    {
        try
        {
            var id = Windows.ApplicationModel.Package.Current.Id.FamilyName;
            await Windows.System.Launcher.LaunchUriAsync(new Uri($"ms-windows-store://review/?PFN={id}"));
        }
        catch (Exception e)
        {
            AppHost.Log($"Store page failed: {e.Message}");
        }
    }
}
