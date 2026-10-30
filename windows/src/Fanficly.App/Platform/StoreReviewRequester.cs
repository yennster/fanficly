using Fanficly.App.Shell;
using Fanficly.Core;
using Windows.Services.Store;

namespace Fanficly.App.Platform;

/// <summary>The Microsoft Store's in-app rating dialog (SwiftUI's requestReview).</summary>
public sealed class StoreReviewRequester : IStoreReviewRequester
{
    public async Task<ReviewPromptOutcome> RequestReviewAsync()
    {
        if (!Services.AppPaths.IsPackaged || MainWindow.Current is null) return ReviewPromptOutcome.Unknown;
        try
        {
            var context = StoreContext.GetDefault();
            WinRT.Interop.InitializeWithWindow.Initialize(context, WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Current));
            var result = await context.RequestRateAndReviewAppAsync();
            if (result.ExtendedError is { } error) AppHost.Log($"Rating prompt: {result.Status} ({error.Message})");
            return result.Status switch
            {
                StoreRateAndReviewStatus.Succeeded => ReviewPromptOutcome.Rated,
                StoreRateAndReviewStatus.CanceledByUser => ReviewPromptOutcome.Dismissed,
                _ => ReviewPromptOutcome.Unknown,
            };
        }
        catch (Exception e)
        {
            AppHost.Log($"Rating prompt failed: {e.Message}");
            return ReviewPromptOutcome.Unknown;
        }
    }

    /// <summary>Opens the app's Store page at its reviews (Settings → About → Rate)
    /// and, once it opens, stops the automatic rating prompt.</summary>
    public static async Task OpenStoreReviewPageAsync()
    {
        try
        {
            var id = Windows.ApplicationModel.Package.Current.Id.FamilyName;
            if (await Windows.System.Launcher.LaunchUriAsync(new Uri($"ms-windows-store://review/?PFN={id}")))
                ReviewPrompter.Shared.OpenedReviewPage();
        }
        catch (Exception e)
        {
            AppHost.Log($"Store page failed: {e.Message}");
        }
    }
}
