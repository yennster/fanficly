using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;

namespace Fanficly.Core;

/// <summary>After a library restore, offers to re-download the EPUB files for
/// works that were saved offline on the old device. Chapter text rides in the
/// backup but the EPUB files don't, so a restored library reads offline yet
/// loses its Downloaded state until the files are fetched again. Any restore
/// path (launch auto-sync, Settings) calls <see cref="ProposeRedownload"/>; the
/// app shows a prompt while <see cref="ProposedIds"/> is set and a progress
/// banner while <see cref="Progress"/> is. Downloads are cancellable at any
/// point — the restored library data is already saved and unaffected. A
/// folder's Download All (<see cref="StartFolderDownload"/>) runs through the
/// same queue, so only one run goes at a time and both share the banner.
///
/// The prompt offers only works whose text a restore just added, minus the
/// ones turned down with Not Now on this device, so a launch sync that brings
/// in nothing new doesn't ask again (#152). The queue stops on a rate limit or
/// a sign-in wall instead of trying every remaining story.
///
/// UI-agnostic: property changes and <see cref="Announcement"/>s are raised on
/// the thread that called <see cref="StartDownloads"/> when it has a
/// synchronization context (the UI thread), else on the thread pool.</summary>
public sealed class RestoreDownloadCenter : INotifyPropertyChanged
{
    public static RestoreDownloadCenter Shared { get; } = new();

    /// <summary>A run's tally. <paramref name="Stopped"/> says why it ended
    /// early, when AO3 refused it; the stories after that weren't tried.</summary>
    public readonly record struct DownloadProgress(int Done, int Failed, int Total, bool Finished, StopReason? Stopped = null)
    {
        /// <summary>The tally after one more work finished (or failed).</summary>
        public DownloadProgress Recording(bool succeeded) =>
            succeeded ? this with { Done = Done + 1 } : this with { Failed = Failed + 1 };

        /// <summary>The same tally, marked finished (early, with <paramref name="stopped"/>).</summary>
        public DownloadProgress Finishing(StopReason? stopped = null) => this with { Finished = true, Stopped = stopped };

        /// <summary>The finished banner's headline.</summary>
        public string FinishedTitle => Stopped switch
        {
            StopReason.RateLimited => "AO3 asked to slow down",
            StopReason.SignInNeeded => "Sign in to AO3 to download the rest",
            _ => Failed == 0 ? $"Downloaded {Done} stories" : $"Downloaded {Done} of {Total} stories",
        };

        /// <summary>The stories a stopped run didn't download: the one AO3
        /// refused and every one after it. Zero for a run that went to the end.</summary>
        public int Untried => Stopped is null ? 0 : Total - Done - Failed + 1;

        /// <summary>The finished banner's second line, for a stopped run.</summary>
        public string? StoppedDetail => Stopped switch
        {
            StopReason.RateLimited => $"Downloaded {Done} of {Total}. Try the other {Untried} again later.",
            StopReason.SignInNeeded => $"Downloaded {Done} of {Total}. AO3 wants a signed-in reader for the other {Untried}.",
            _ => null,
        };

        /// <summary>What Narrator says when the run ends.</summary>
        public string Announcement => StoppedDetail is { } detail
            ? $"Downloads stopped. {FinishedTitle}. {detail}"
            : Failed == 0
                ? $"Downloaded {Done} stories for offline reading."
                : $"Downloads finished. {Done} succeeded, {Failed} failed.";
    }

    /// <summary>AO3 answers that would fail every remaining story the same way,
    /// so the queue stops instead of sending one request a second into them.</summary>
    public enum StopReason
    {
        /// <summary>AO3 said slow down (429).</summary>
        RateLimited,
        /// <summary>AO3 sent a signed-in reader to its login page: the session expired.</summary>
        SignInNeeded,
    }

    /// <summary>The stop an error calls for, or null when the run goes on.
    /// Signed out, Unauthorized is just a restricted work (it needs an
    /// account), so it fails alone and the public ones still download.</summary>
    public static StopReason? StopReasonFor(Exception error, bool signedIn) => error switch
    {
        AO3Exception { Kind: AO3ErrorKind.RateLimited } => StopReason.RateLimited,
        AO3Exception { Kind: AO3ErrorKind.Unauthorized } when signedIn => StopReason.SignInNeeded,
        _ => null,
    };

    /// <summary>What the current (or last) run is for; it picks the banner's
    /// and Narrator's wording.</summary>
    public enum DownloadKind { Restore, Folder }

    private IReadOnlyList<int>? _proposedIds;
    private DownloadProgress? _progress;
    private IReadOnlyList<int> _lastProposal = [];
    private CancellationTokenSource? _downloadCts;
    private readonly Lock _restoredLock = new();
    private readonly IKeyValueStore? _settings;

    /// <summary><paramref name="settings"/> keeps the declined works (this
    /// device's settings, not the backup); the app's by default.</summary>
    public RestoreDownloadCenter(IKeyValueStore? settings = null) => _settings = settings;

    /// <summary>The settings key for the works declined with Not Now, as
    /// comma-separated AO3 ids. Kept on this device only.</summary>
    public const string DeclinedKey = "restore.declinedRedownloads";

    /// <summary>The settings key for the works a restore gave text since the
    /// last prompt, plus the ones a stopped run didn't get to. Kept on this
    /// device, so they survive a relaunch until the next restore offers them.</summary>
    public const string PendingKey = "restore.pendingRedownloads";

    private IKeyValueStore Settings => _settings ?? LibrarySyncManager.SharedSettings;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>An accessibility announcement for the app to post (screen readers).</summary>
    public event Action<string>? Announcement;

    /// <summary>How long the finished banner stays up.</summary>
    public TimeSpan FinishedBannerDuration { get; set; } = TimeSpan.FromSeconds(4);

    /// <summary>Non-null while the "re-download?" prompt should show.</summary>
    public IReadOnlyList<int>? ProposedIds
    {
        get => _proposedIds;
        private set
        {
            _proposedIds = value;
            OnPropertyChanged();
        }
    }

    /// <summary>Non-null while downloads run (or briefly after, with Finished set).</summary>
    public DownloadProgress? Progress
    {
        get => _progress;
        private set
        {
            if (_progress == value) return;
            _progress = value;
            OnPropertyChanged();
        }
    }

    public bool IsDownloading => _downloadCts is not null;

    /// <summary>What the current (or last) run is for.</summary>
    public DownloadKind Kind { get; private set; } = DownloadKind.Restore;

    /// <summary>Works whose offline text was restored but whose EPUB file is
    /// missing locally — i.e. downloaded on the device that made the backup.
    /// With <paramref name="restored"/>, only those works; <paramref name="declined"/>
    /// ones are left out.</summary>
    public static IReadOnlyList<int> RedownloadCandidates(
        LibraryStore store, IReadOnlySet<int>? restored = null, IReadOnlySet<int>? declined = null) =>
        store.All<Work>()
            .Where(w => restored?.Contains(w.Ao3Id) ?? true)
            .Where(w => declined?.Contains(w.Ao3Id) != true)
            // An imported book that isn't on AO3 has nothing to download.
            .Where(w => !EpubImport.IsLocalWork(w.Ao3Id))
            .Where(w => w.Chapters.Count > 0 && WorkPersistence.EpubPath(w.Ao3Id) is null)
            .OrderBy(w => w.Title, StringComparer.CurrentCultureIgnoreCase)
            .Select(w => w.Ao3Id)
            .ToList();

    /// <summary>A restore (<see cref="LibrarySyncManager"/>) records each work it
    /// gave chapter text, so the next prompt offers just those.</summary>
    public void NoteRestoredText(IEnumerable<int> workIds)
    {
        lock (_restoredLock)
        {
            var pending = ReadIds(PendingKey);
            pending.UnionWith(workIds);
            WriteIds(PendingKey, pending);
        }
    }

    /// <summary>Shows the prompt for the works the last restore gave text, when
    /// any still lack their EPUB and weren't turned down. Does nothing while a
    /// prompt or a run is up; the noted works wait for the next restore.</summary>
    public void ProposeRedownload(LibraryStore store)
    {
        if (_downloadCts is not null || Progress is not null || ProposedIds is not null) return;
        HashSet<int> restored;
        lock (_restoredLock)
        {
            restored = ReadIds(PendingKey);
            Settings.Remove(PendingKey);
        }
        var ids = RedownloadCandidates(store, restored, ReadIds(DeclinedKey));
        if (ids.Count == 0) return;
        _lastProposal = ids;
        ProposedIds = ids;
    }

    public void DismissProposal() => ProposedIds = null;

    /// <summary>Not Now: this device doesn't offer these works again. Each
    /// still has its own Save Offline, and a folder's Download All includes it.</summary>
    public void DeclineProposal()
    {
        ProposedIds = null;
        if (_lastProposal.Count == 0) return;
        var declined = ReadIds(DeclinedKey);
        declined.UnionWith(_lastProposal);
        WriteIds(DeclinedKey, declined);
        _lastProposal = [];
    }

    private HashSet<int> ReadIds(string key)
    {
        var ids = new HashSet<int>();
        foreach (var part in (Settings.GetString(key) ?? "").Split(','))
            if (int.TryParse(part, NumberStyles.Integer, CultureInfo.InvariantCulture, out var id)) ids.Add(id);
        return ids;
    }

    private void WriteIds(string key, IEnumerable<int> ids) =>
        Settings.SetString(key, string.Join(',', ids.Order().Select(id => id.ToString(CultureInfo.InvariantCulture))));

    /// <summary>Starts sequential EPUB downloads (the AO3 throttle spaces them
    /// out anyway). Uses the snapshot taken at proposal time, so it works
    /// whether the prompt clears <see cref="ProposedIds"/> before or after.
    /// The returned task completes when the run ends (finished or cancelled).</summary>
    /// <paramref name="signedIn"/> decides what an Unauthorized means (<see cref="StopReasonFor"/>).
    public Task StartDownloads(IAO3Client client, bool signedIn)
    {
        var ids = _lastProposal;
        if (ids.Count == 0 || _downloadCts is not null) return Task.CompletedTask;
        ProposedIds = null;
        _lastProposal = [];
        return Start(ids, DownloadKind.Restore, signedIn, (id, ct) => client.DownloadEpubAsync(id, ct));
    }

    // MARK: - Folder "Download All"

    /// <summary>The works in a folder that aren't downloaded yet, in the order
    /// given (the folder's on-screen order), each once. <paramref name="isDownloaded"/>
    /// defaults to the EPUB file check behind the Downloaded badge.</summary>
    public static IReadOnlyList<int> FolderDownloadCandidates(IEnumerable<Work> works, Func<int, bool>? isDownloaded = null)
    {
        isDownloaded ??= id => WorkPersistence.EpubPath(id) is not null;
        return works.Select(w => w.Ao3Id).Where(id => !EpubImport.IsLocalWork(id) && !isDownloaded(id)).Distinct().ToList();
    }

    /// <summary>Downloads a folder's stories one after another, each saved like
    /// the reader's Save Offline (<see cref="SaveOfflineAsync"/>). Ignored while
    /// another run is going. The returned task completes when the run ends.</summary>
    public Task StartFolderDownload(IAO3Client client, LibraryStore store, IReadOnlyList<int> ids, bool signedIn)
    {
        if (ids.Count == 0 || _downloadCts is not null) return Task.CompletedTask;
        return Start(ids, DownloadKind.Folder, signedIn, (id, ct) => SaveOfflineAsync(client, store, id, ct));
    }

    /// <summary>Saves one story for offline reading: its chapter text first
    /// when none is stored yet (so it reads offline in the app), then the EPUB.</summary>
    public static async Task SaveOfflineAsync(IAO3Client client, LibraryStore store, int workId, CancellationToken ct = default)
    {
        // Removed from the library mid-run: nothing to save it for.
        if (store.GetWork(workId) is not { } work) return;
        if (store.ChaptersOf(work).Count == 0)
        {
            var payload = await client.FetchWorkAsync(workId, ct);
            ct.ThrowIfCancellationRequested();
            // Deleted while its fetch waited: don't bring it back.
            if (!work.IsInserted) return;
            WorkPersistence.Upsert(payload, store);
            LibrarySyncManager.QueueBackupShared(store);
        }
        await client.DownloadEpubAsync(workId, ct);
    }

    // MARK: - The queue

    private Task Start(IReadOnlyList<int> ids, DownloadKind kind, bool signedIn, Func<int, CancellationToken, Task> download)
    {
        Kind = kind;
        Progress = new DownloadProgress(0, 0, ids.Count, false);
        Announcement?.Invoke($"Downloading {ids.Count} stories for offline reading.");
        var cts = _downloadCts = new CancellationTokenSource();
        return RunAsync(ids, kind, signedIn, download, cts);
    }

    /// <summary>Runs <paramref name="download"/> for each id in turn, never in
    /// parallel. A failure is counted and skipped (a deleted work mustn't stall
    /// the rest), except a rate limit or a sign-in wall, which ends the run
    /// (<see cref="DownloadProgress.Stopped"/>) since every story after it would
    /// fail the same way. Returns the finished tally, or null once
    /// <paramref name="ct"/> is cancelled; works downloaded before the cancel
    /// stay downloaded, since nothing here undoes them. <paramref name="report"/>
    /// gets the tally after each work.</summary>
    public static async Task<DownloadProgress?> RunQueueAsync(
        IReadOnlyList<int> ids,
        Func<int, CancellationToken, Task> download,
        Action<DownloadProgress> report,
        CancellationToken ct,
        bool signedIn = true)
    {
        var tally = new DownloadProgress(0, 0, ids.Count, false);
        foreach (var id in ids)
        {
            if (ct.IsCancellationRequested) return null;
            try
            {
                await download(id, ct);
                tally = tally.Recording(succeeded: true);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return null;
            }
            catch (Exception e)
            {
                tally = tally.Recording(succeeded: false);
                if (StopReasonFor(e, signedIn) is { } reason)
                    return ct.IsCancellationRequested ? null : tally.Finishing(reason);
            }
            if (ct.IsCancellationRequested) return null;
            report(tally);
        }
        return tally.Finishing();
    }

    private async Task RunAsync(IReadOnlyList<int> ids, DownloadKind kind, bool signedIn,
                                Func<int, CancellationToken, Task> download, CancellationTokenSource cts)
    {
        var ct = cts.Token;
        var final = await RunQueueAsync(ids, download, p => Progress = p, ct, signedIn);
        if (final is not { } done || ct.IsCancellationRequested) return;
        _downloadCts = null;
        Progress = done;
        // A stopped restore run offers what it didn't get to after the next
        // restore, as the banner promises. (A folder keeps its Download All.)
        if (kind == DownloadKind.Restore && done.Stopped is not null)
            NoteRestoredText(ids.Skip(ids.Count - done.Untried));
        Announcement?.Invoke(done.Announcement);
        try
        {
            // A stop asks the reader to do something, so it stays up longer.
            await Task.Delay(done.Stopped is null ? FinishedBannerDuration : FinishedBannerDuration * 2.5, ct);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (Progress?.Finished == true) Progress = null;
    }

    /// <summary>Stops the downloads; everything already restored (and already
    /// downloaded) stays.</summary>
    public void Cancel()
    {
        _downloadCts?.Cancel();
        _downloadCts = null;
        Progress = null;
        Announcement?.Invoke(Kind == DownloadKind.Restore
            ? "Downloads canceled. Your restored library is unaffected."
            : "Downloads canceled. Stories already downloaded stay downloaded.");
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
