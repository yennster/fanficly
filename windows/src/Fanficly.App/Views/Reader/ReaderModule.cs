using System.Runtime.CompilerServices;
using Fanficly.App.UI;
using Fanficly.Core;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// Registers the reader's screens with the app's routes (SwiftUI's
/// <c>.workAndAuthorDestinations()</c> / RootView's resume destination) and the
/// icons only the reader uses.
/// </summary>
internal static class ReaderModule
{
    [ModuleInitializer]
    internal static void Register()
    {
        Symbols.Add("arrow.down.right.and.arrow.up.left", ''); // BackToWindow
        Symbols.Add("bell.fill", '');                          // RingerSolid
        Symbols.Add("square.and.arrow.down", '');              // SaveAs
        Symbols.Add("pencil", '');                             // Edit
        Symbols.Add("plus", '');                               // Add

        Routes.WorkDetail = (id, summary) => new WorkDetailScreen(id, summary);
        Routes.SavedWork = id => SavedWorkReaderScreen.ForWork(id);
        Routes.Resume = OpenResume;
    }

    /// <summary>A widget / jump-list resume tap: install the position it carries
    /// when that can't move saved progress backwards (RootView's
    /// <c>installResumeProgressIfAvailable</c>), then open the saved reader, or the
    /// live work page when the work isn't in the Library.</summary>
    private static Shell.Screen OpenResume(ResumeWorkRoute route)
    {
        try
        {
            InstallResumeProgress(route, AppHost.Library);
        }
        catch (Exception e)
        {
            AppHost.Log($"Resume progress not installed: {e.Message}");
        }
        return AppHost.Library.GetWork(route.WorkId) is not null
            ? SavedWorkReaderScreen.ForWork(route.WorkId)
            : new WorkDetailScreen(route.WorkId, null);
    }

    internal static void InstallResumeProgress(ResumeWorkRoute route, LibraryStore store)
    {
        var widget = ResumeProgressPolicy.MatchingWidgetProgress(route.WorkId, WidgetProgressStore.Load());
        var existing = store.GetReadingProgress(route.WorkId);
        if (ResumeProgressPolicy.AnchorToInstall(route, widget, existing?.UpdatedAt) is not { } anchor) return;
        ReadingProgressStore.Save(
            route.WorkId, anchor.Chapter, anchor.Paragraph,
            widget?.Title ?? existing?.Title ?? "",
            widget?.Author ?? existing?.Author ?? "",
            store,
            progress: widget?.ClampedProgress,
            syncWidgetImmediately: false);
    }
}
