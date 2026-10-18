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
/// (followed works are searchable from the OS). Optional on Windows.</summary>
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

    /// <summary>CoreSpotlight indexing of followed works.</summary>
    public static IWorkSearchIndexer? SearchIndexer { get; set; }

    /// <summary>The app's local log, for failures the library otherwise only
    /// reports as a false return (<see cref="LibraryStore.TrySave"/>).</summary>
    public static Action<string>? Log { get; set; }

    /// <summary>Tells the user a library save failed (its error message), so a
    /// change that only looks saved doesn't go unnoticed. Called on the saving
    /// thread.</summary>
    public static Action<string>? SaveFailed { get; set; }
}
