namespace Fanficly.Core;

/// <summary>A reading-position update for the last-read widget store
/// (<c>WidgetProgressStore.save</c> in the Swift app).</summary>
public sealed record WidgetProgressUpdate(
    int Id,
    string Title,
    string Author,
    double Progress,
    int Chapter,
    int Paragraph,
    DateTimeOffset UpdatedAt,
    bool SyncImmediately);

/// <summary>The system search index the Swift app feeds through CoreSpotlight
/// (every library work is searchable from the OS). Windows installs none:
/// Windows Search has no public API for an app's own items (RM-108). Swift also
/// rebuilds its index after a library restore; an indexer added here would need
/// the same after <c>LibrarySyncManager</c>'s restore.</summary>
public interface IWorkSearchIndexer
{
    void Index(Work work);
    void Remove(int ao3Id);
}

/// <summary>Side effects the library code triggers in other parts of the app,
/// which live outside this area (or outside Core). The app installs them at
/// launch; left null (as in tests) they're skipped.</summary>
public static class LibraryHooks
{
    /// <summary><c>WidgetDataStore.updateAll(context:)</c> — refresh the widget's data.</summary>
    public static Action<LibraryStore>? UpdateWidgetData { get; set; }

    /// <summary><c>StreakStore.recordReadingEvent()</c> — the reading streak.</summary>
    public static Action? RecordReadingEvent { get; set; }

    /// <summary><c>WidgetProgressStore.save(...)</c> — the last-read widget store
    /// (app-group defaults + the synced key/value mirror).</summary>
    public static Action<WidgetProgressUpdate>? SaveWidgetProgress { get; set; }

    /// <summary>CoreSpotlight indexing of library works.</summary>
    public static IWorkSearchIndexer? SearchIndexer { get; set; }

    /// <summary>The app's local log, for failures the library otherwise only
    /// reports as a false return (<see cref="LibraryStore.TrySave"/>).</summary>
    public static Action<string>? Log { get; set; }

    /// <summary>Tells the user a library save failed (its error message), so a
    /// change that only looks saved doesn't go unnoticed. Called on the saving
    /// thread.</summary>
    public static Action<string>? SaveFailed { get; set; }
}
