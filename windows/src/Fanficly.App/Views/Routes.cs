using Fanficly.App.Shell;
using Fanficly.Core;

namespace Fanficly.App.Views;

/// <summary>
/// Screens one feature opens from another (SwiftUI's navigationDestination
/// table, <c>.workAndAuthorDestinations()</c>). The feature that owns a screen
/// sets its factory from a module initializer; callers push through these
/// helpers and never reference another feature's screen types.
/// </summary>
public static class Routes
{
    /// <summary>The live work page (WorkDetailView): reader + toolbar actions.</summary>
    public static Func<int, AO3WorkSummary?, Screen>? WorkDetail { get; set; }

    /// <summary>A saved work's reader (SavedWorkReader): offline if downloaded.</summary>
    public static Func<int, Screen>? SavedWork { get; set; }

    /// <summary>A reader opened at a widget / jump-list position.</summary>
    public static Func<ResumeWorkRoute, Screen>? Resume { get; set; }

    /// <summary>One author's works (AuthorWorksView).</summary>
    public static Func<AuthorRef, Screen>? AuthorWorks { get; set; }

    /// <summary>A series' works in order (SeriesView): its id and title.</summary>
    public static Func<int, string, Screen>? Series { get; set; }

    /// <summary>Works matching filters under a title (FandomWorksView driven by filters).</summary>
    public static Func<AO3SearchFilters, string, Screen>? FilteredWorks { get; set; }

    /// <summary>Comments on a work (CommentsView): work id, optional chapter id,
    /// work title, and the chapter's number and the chapter count when the
    /// caller knows them (the reader does; null → looked up from the library).</summary>
    public static Func<int, int?, string, int?, int?, Screen>? Comments { get; set; }

    /// <summary>The AO3 sign-in screen (LoginView).</summary>
    public static Func<Screen>? Login { get; set; }

    /// <summary>Import overlay for a shared / pasted AO3 link: fetch, download, open.</summary>
    public static Action<int>? Import { get; set; }

    /// <summary>Shows a Library folder (widget / deep link).</summary>
    public static Action<string>? LibraryFolder { get; set; }

    /// <summary>Runs a search typed elsewhere (deep link, jump list); the Search
    /// tab reads <see cref="DeepLink.PendingSearchQueryKey"/> when it appears.</summary>
    public static event Action<string>? SearchRequested;

    internal static void RequestSearch(string query) => SearchRequested?.Invoke(query);

    private static Navigator Nav => MainWindow.Current.Navigator;

    private static Screen Missing(string what) => new PlaceholderScreen(what);

    public static void OpenWork(int workId, AO3WorkSummary? summary = null) =>
        Nav.Push(WorkDetail?.Invoke(workId, summary) ?? Missing(summary?.Title ?? "Work"));

    public static void OpenSavedWork(int workId) =>
        Nav.Push(SavedWork?.Invoke(workId) ?? Missing("Work"));

    public static void OpenAuthor(AuthorRef author) =>
        Nav.Push(AuthorWorks?.Invoke(author) ?? Missing(author.DisplayName));

    public static void OpenSeries(int seriesId, string title) =>
        Nav.Push(Series?.Invoke(seriesId, title) ?? Missing(title));

    public static void OpenFilteredWorks(AO3SearchFilters filters, string title) =>
        Nav.Push(FilteredWorks?.Invoke(filters, title) ?? Missing(title));

    public static void OpenComments(int workId, int? chapterId, string title, int? chapterNumber = null, int? totalChapters = null) =>
        Nav.Push(Comments?.Invoke(workId, chapterId, title, chapterNumber, totalChapters) ?? Missing("Comments"));

    public static void OpenLogin() => Nav.Push(Login?.Invoke() ?? Missing("Sign In"));
}
