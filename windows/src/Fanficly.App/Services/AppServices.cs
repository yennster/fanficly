using Fanficly.App.Platform;
using Fanficly.App.Platform.Widgets;
using Fanficly.App.Services;
using Fanficly.App.Shell;
using Fanficly.Core;

namespace Fanficly.App;

/// <summary>The app's shared services (FanficlyApp's environment objects).</summary>
public static partial class AppHost
{
    /// <summary>The one seam to AO3 (the demo client offline in demo mode).</summary>
    public static IAO3Client Client { get; private set; } = null!;

    /// <summary>The library database (SwiftData's ModelContainer).</summary>
    public static LibraryStore Library { get; private set; } = null!;

    /// <summary>The AO3 sign-in state.</summary>
    public static AuthState Auth { get; private set; } = null!;

    public static LibrarySyncManager Sync { get; private set; } = null!;

    /// <summary>"settings.syncFolder": the folder backups and synced settings live in.</summary>
    public const string SyncFolderKey = "settings.syncFolder";

    public static string AppVersion { get; } =
        typeof(AppHost).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "1.0.0";

    static partial void InitializeServices()
    {
        WorkPersistence.LibraryFolder = AppPaths.Downloads;
        NotificationsAuthorization.IsSuppressed = IsDemoMode;
        ReviewPrompter.Shared.IsSuppressed = IsDemoMode;
        ReviewPrompter.Shared.CurrentVersion = AppVersion;
        ReaderProfile.CurrentDevice = ReaderDevice.Windows;

        if (IsDemoMode)
        {
            AppGroupStore.Shared = new InMemoryKeyValueStore();
            CredentialStore.Shared = new InMemoryCookieVault();
            DemoCatalog.LongChapters = IsDemoLongChapters;
            Client = new DemoAO3Client();
            Library = LibraryStore.OpenInMemory();
            DemoSeed.Seed(Library, DemoCatalog.Works);
            Auth = new AuthState(CredentialStore.Shared) { Username = "demo_reader" };
        }
        else
        {
            var shared = new JsonFileKeyValueStore(WidgetStorage.SharedStorePath);
            WidgetStorage.MirrorStreak(KeyValueStores.Default, shared);
            AppGroupStore.Shared = shared;
            CredentialStore.Shared = new ProtectedCookieVault(Path.Combine(AppPaths.LocalData, "Credentials"));
            Client = new AO3Client(AppPaths.Downloads, CredentialStore.Shared, AppVersion) { Log = Log };
            Library = OpenLibrary();
            Auth = new AuthState(CredentialStore.Shared);
        }

        Sync = new LibrarySyncManager(KeyValueStores.Default)
        {
            SyncFolder = KeyValueStores.Default.GetString(SyncFolderKey),
            MergeReaderProfiles = (local, incoming) => ReaderProfile.MergedProfiles(local, incoming),
            PublishReaderProfiles = ReaderProfileSyncStore.PublishLocalProfiles,
        };
        // Without the real library, a backup or restore would stamp the sync
        // folder as applied while this PC's library never saw it.
        LibrarySyncManager.Shared = IsDemoMode || LibraryOpenFailed is not null ? null : Sync;
        if (KeyValueStores.Synced is SyncFolderKeyValueStore synced && Sync.IsSyncEnabled)
            synced.Folder = Sync.SyncFolder;

        InstallLibraryHooks();
        SubscriptionPoller.RoutePayloads = new RoutePayloads();
        ReviewPrompter.Shared.Requester = new StoreReviewRequester();

        if (!IsDemoMode)
        {
            WidgetProgressStore.InstallCloudSyncObserver();
            ReaderProfileSyncStore.InstallCloudSyncObserver();
            StreakStore.InstallCloudSyncObserver();
            Notifications.Register();
            // The subscription poll: in-app while the window is open, and a
            // Windows background task (registered once) while it's closed.
            InAppPolling.Start();
            _ = BackgroundTaskRegistrar.EnsureRegisteredAsync();
        }
    }

    private static LibraryStore OpenLibrary()
    {
        // Waits for a background refresh that has the library open to save and
        // let go, so this load includes what it wrote.
        LibraryLock.AcquireForApp();
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return LibraryStore.Open(AppPaths.Database);
            }
            catch (Microsoft.Data.Sqlite.SqliteException e) when (e.SqliteErrorCode is 11 or 26)
            {
                // SQLITE_CORRUPT or SQLITE_NOTADB: a damaged database must not stop
                // the app, so keep it aside and start fresh.
                Log($"Library is damaged, starting a new one: {e}");
                try { File.Move(AppPaths.Database, AppPaths.Database + $".damaged-{DateTime.Now:yyyyMMddHHmmss}"); } catch { }
                return LibraryStore.Open(AppPaths.Database);
            }
            catch (Exception e) when (attempt < 3)
            {
                // Busy or locked (another copy of the app, a backup tool): wait.
                Log($"Library open failed, retrying: {e.Message}");
                Thread.Sleep(1000);
            }
            catch (Exception e)
            {
                // Never set a library aside over a lock: read nothing and save
                // nothing this run, and say so once the window is up.
                Log($"Library open failed, running without it: {e}");
                LibraryOpenFailed = e.Message;
                return LibraryStore.OpenInMemory();
            }
        }
    }

    /// <summary>Why the library couldn't be opened this run, if it couldn't.</summary>
    private static string? LibraryOpenFailed;

    private static void InstallLibraryHooks()
    {
        LibraryHooks.Log = Log;
        LibraryHooks.SaveFailed = ReportSaveFailure;
        LibraryHooks.RecordReadingEvent = () => StreakStore.RecordReadingEvent();
        LibraryHooks.SaveWidgetProgress = u =>
        {
            WidgetProgressStore.Save(u.Id, u.Title, u.Author, u.Progress, u.Chapter, u.Paragraph, u.UpdatedAt, u.SyncImmediately);
            MainWindow.Current?.DispatcherQueue.TryEnqueue(() => _ = JumpListService.RefreshAsync());
        };
        LibraryHooks.UpdateWidgetData = store => WidgetDataStore.UpdateAll(WidgetSources(store));
        if (!IsDemoMode) Library.Changed += _ => LibrarySyncManager.QueueBackupShared(Library);
    }

    private static long _lastSaveFailureShown;

    /// <summary>Says so when a library change didn't reach the disk, at most
    /// once a minute (every later save retries the same change).</summary>
    private static void ReportSaveFailure(string error)
    {
        var now = Environment.TickCount64;
        var last = Interlocked.Read(ref _lastSaveFailureShown);
        if (last != 0 && now - last < 60_000) return;
        if (Interlocked.CompareExchange(ref _lastSaveFailureShown, now, last) != last) return;
        MainWindow.Current?.DispatcherQueue.TryEnqueue(() => MainWindow.Current?.ShowMessage(
            "Couldn't save your library",
            $"Your latest change may be lost when Fanficly closes. {error}",
            Microsoft.UI.Xaml.Controls.InfoBarSeverity.Error, seconds: 10));
    }

    /// <summary>The rows the widgets show, read from the library.</summary>
    public static WidgetDataSources WidgetSources(LibraryStore store) => new(
        store.All<SavedSearch>().Select(s => new WidgetSavedSearchSource(s.Name, s.Prompt, s.SavedAt)).ToList(),
        store.All<SavedFilter>().Select(f => new WidgetSavedFilterSource(f.Name, f.FiltersJson, f.SavedAt)).ToList(),
        store.Folders().Select(f => new WidgetFolderSource(f.Name, f.Works.Count, f.CreatedAt)).ToList(),
        store.Works.Select(w => new WidgetWorkSource
        {
            Ao3Id = w.Ao3Id, Title = w.Title, AuthorName = w.AuthorName, Summary = w.Summary,
            Fandoms = w.Fandoms, Relationships = w.Relationships, Characters = w.Characters,
            ChapterCount = w.ChapterCount, IsFollowed = w.IsFollowed, IsStarred = w.IsStarred, IsPinned = w.IsPinned,
            SavedAt = w.SavedAt, UpdatedAt = w.UpdatedAt,
        }).ToList(),
        store.Subscriptions().Select(s => new WidgetSubscriptionSource(s.Key, s.Kind, s.DisplayName, s.AuthorName, s.LastSeenChapterCount, s.LastCheckedAt)).ToList());

    /// <summary>The launch task (FanficlyApp's .task): restore from the sync
    /// folder when it changed elsewhere, then backfill stats.</summary>
    public static async Task RunLaunchTasksAsync()
    {
        if (IsDemoMode) return;
        if (LibraryOpenFailed is { } why)
        {
            MainWindow.Current?.ShowMessage("Couldn't open your library",
                $"Fanficly can't save anything this time. Close other copies of Fanficly and restart it. {why}",
                Microsoft.UI.Xaml.Controls.InfoBarSeverity.Error, seconds: 20);
            return;
        }
        try
        {
            if (Sync.IsSyncEnabled && Sync.IsBackupAvailable && Sync.CloudBackupHasUnappliedChanges)
            {
                if (await Sync.RestoreAsync(Library))
                    RestoreDownloadCenter.Shared.ProposeRedownload(Library);
            }
            ReadingStatsBackfill.RunIfNeeded(Library);
            LibraryHooks.UpdateWidgetData?.Invoke(Library);
        }
        catch (Exception e)
        {
            Log($"Launch tasks failed: {e}");
        }
    }

    /// <summary>Saves everything on the way out (scene phase → background).</summary>
    public static void OnClosing()
    {
        try
        {
            Library.TrySave();
            if (!IsDemoMode && LibraryOpenFailed is null && Sync.IsSyncEnabled) Sync.Backup(Library);
            WidgetProgressStore.FlushPendingCloudWrite();
            StreakStore.FlushPendingCloudWrite();
            if (AppGroupStore.Shared is JsonFileKeyValueStore g) g.Flush();
        }
        catch (Exception e)
        {
            Log($"Saving on exit failed: {e}");
        }
    }

    /// <summary>Notification payloads in <see cref="NotificationRoute"/>'s format.</summary>
    internal sealed class RoutePayloads : INotificationRoutePayloads
    {
        public IReadOnlyDictionary<string, string> NewChapters(int workId) => new NotificationRoute.NewChapters(workId).ToArguments();
        public IReadOnlyDictionary<string, string> NewWork(int workId) => new NotificationRoute.NewWork(workId).ToArguments();
        public IReadOnlyDictionary<string, string> NewWorks(string authorUsername, string authorName) =>
            new NotificationRoute.NewWorks(new AuthorRef(authorUsername, authorName)).ToArguments();
    }

    /// <summary>The poller's notifications as Windows toasts.</summary>
    public sealed class ToastNotifier : ILocalNotifier
    {
        public Task PostAsync(LocalNotification n)
        {
            Notifications.Show(n.Title, n.Body, NotificationRoute.FromArguments(n.Payload), tag: n.Identifier.Length <= 64 ? n.Identifier : null);
            return Task.CompletedTask;
        }
    }
}
