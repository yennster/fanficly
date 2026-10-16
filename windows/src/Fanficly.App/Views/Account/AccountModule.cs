using System.Runtime.CompilerServices;
using Fanficly.Core;

namespace Fanficly.App.Views.Account;

/// <summary>Registers the Subscriptions and Bookmarks tabs and the sign-in and
/// comments routes.</summary>
internal static class AccountModule
{
    [ModuleInitializer]
    internal static void Register()
    {
        Tabs.Register(SidebarItem.Subscriptions, () => new SubscriptionsScreen());
        Tabs.Register(SidebarItem.Bookmarks, () => new BookmarksScreen());
        Routes.Login = () => new LoginScreen();
        Routes.Comments = (workId, chapterId, title) =>
        {
            var (number, total) = ChapterPosition(workId, chapterId);
            return new CommentsScreen(workId, chapterId, title, number, total);
        };
    }

    /// <summary>The chapter number and chapter count for a comments thread, read
    /// from the library when the work is saved (Routes.Comments carries only the
    /// chapter's AO3 id). Unknown → the plain "Comments" title.</summary>
    internal static (int? Number, int? Total) ChapterPosition(int workId, int? chapterId)
    {
        try
        {
            if (AppHost.Library?.GetWork(workId) is not { } work) return (null, null);
            var chapters = AppHost.Library.ChaptersOf(work);
            var total = Math.Max(work.ChapterCount, chapters.Count);
            if (chapterId is null) return (total > 1 ? 1 : null, total);
            var match = chapters.FirstOrDefault(c => c.AoId == chapterId);
            return (match?.Index, total);
        }
        catch (Exception e)
        {
            AppHost.Log($"Comments chapter lookup failed: {e.Message}");
            return (null, null);
        }
    }
}
