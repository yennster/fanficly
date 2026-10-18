using System.ComponentModel;
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
/// UI-agnostic: property changes and <see cref="Announcement"/>s are raised on
/// the thread that called <see cref="StartDownloads"/> when it has a
/// synchronization context (the UI thread), else on the thread pool.</summary>
public sealed class RestoreDownloadCenter : INotifyPropertyChanged
{
    public static RestoreDownloadCenter Shared { get; } = new();

    public readonly record struct DownloadProgress(int Done, int Failed, int Total, bool Finished)
    {
        /// <summary>The tally after one more work finished (or failed).</summary>
        public DownloadProgress Recording(bool succeeded) =>
            succeeded ? this with { Done = Done + 1 } : this with { Failed = Failed + 1 };

        /// <summary>The same tally, marked finished.</summary>
        public DownloadProgress Finishing() => this with { Finished = true };
    }

    /// <summary>What the current (or last) run is for; it picks the banner's
    /// and Narrator's wording.</summary>
    public enum DownloadKind { Restore, Folder }

    private IReadOnlyList<int>? _proposedIds;
    private DownloadProgress? _progress;
    private IReadOnlyList<int> _lastProposal = [];
    private CancellationTokenSource? _downloadCts;

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
    /// missing locally — i.e. downloaded on the device that made the backup.</summary>
    public static IReadOnlyList<int> RedownloadCandidates(LibraryStore store) =>
        store.All<Work>()
            .Where(w => w.Chapters.Count > 0 && WorkPersistence.EpubPath(w.Ao3Id) is null)
            .OrderBy(w => w.Title, StringComparer.CurrentCultureIgnoreCase)
            .Select(w => w.Ao3Id)
            .ToList();

    public void ProposeRedownload(LibraryStore store)
    {
        if (_downloadCts is not null || Progress is not null || ProposedIds is not null) return;
        var ids = RedownloadCandidates(store);
        if (ids.Count == 0) return;
        _lastProposal = ids;
        ProposedIds = ids;
    }

    public void DismissProposal() => ProposedIds = null;

    /// <summary>Starts sequential EPUB downloads (the AO3 throttle spaces them
    /// out anyway). Uses the snapshot taken at proposal time, so it works
    /// whether the prompt clears <see cref="ProposedIds"/> before or after.
    /// The returned task completes when the run ends (finished or cancelled).</summary>
    public Task StartDownloads(IAO3Client client)
    {
        var ids = _lastProposal;
        if (ids.Count == 0 || _downloadCts is not null) return Task.CompletedTask;
        ProposedIds = null;
        _lastProposal = [];
        return Start(ids, DownloadKind.Restore, async (id, ct) => await client.DownloadEpubAsync(id, ct));
    }

    // MARK: - Folder "Download All"

    /// <summary>The works in a folder that aren't downloaded yet, in the order
    /// given (the folder's on-screen order), each once. <paramref name="isDownloaded"/>
    /// defaults to the EPUB file check behind the Downloaded badge.</summary>
    public static IReadOnlyList<int> FolderDownloadCandidates(IEnumerable<Work> works, Func<int, bool>? isDownloaded = null)
    {
        isDownloaded ??= id => WorkPersistence.EpubPath(id) is not null;
        return works.Select(w => w.Ao3Id).Where(id => !isDownloaded(id)).Distinct().ToList();
    }

    /// <summary>Downloads a folder's stories one after another, each saved like
    /// the reader's Save Offline (<see cref="SaveOfflineAsync"/>). Ignored while
    /// another run is going. The returned task completes when the run ends.</summary>
    public Task StartFolderDownload(IAO3Client client, LibraryStore store, IReadOnlyList<int> ids)
    {
        if (ids.Count == 0 || _downloadCts is not null) return Task.CompletedTask;
        return Start(ids, DownloadKind.Folder, (id, ct) => SaveOfflineAsync(client, store, id, ct));
    }

    /// <summary>Saves one story for offline reading: its chapter text first
    /// when none is stored yet (so it reads offline in the app), then the EPUB.</summary>
    public static async Task SaveOfflineAsync(IAO3Client client, LibraryStore store, int workId, CancellationToken ct = default)
    {
        if (store.GetWork(workId) is { } work && store.ChaptersOf(work).Count == 0)
        {
            var payload = await client.FetchWorkAsync(workId, ct);
            ct.ThrowIfCancellationRequested();
            WorkPersistence.Upsert(payload, store);
            LibrarySyncManager.QueueBackupShared(store);
        }
        await client.DownloadEpubAsync(workId, ct);
    }

    // MARK: - The queue

    private Task Start(IReadOnlyList<int> ids, DownloadKind kind, Func<int, CancellationToken, Task> download)
    {
        Kind = kind;
        Progress = new DownloadProgress(0, 0, ids.Count, false);
        Announcement?.Invoke($"Downloading {ids.Count} stories for offline reading.");
        var cts = _downloadCts = new CancellationTokenSource();
        return RunAsync(ids, download, cts);
    }

    /// <summary>Runs <paramref name="download"/> for each id in turn, never in
    /// parallel. A failure is counted and skipped (a deleted work mustn't stall
    /// the rest). Returns the finished tally, or null once
    /// <paramref name="ct"/> is cancelled; works downloaded before the cancel
    /// stay downloaded, since nothing here undoes them. <paramref name="report"/>
    /// gets the tally after each work.</summary>
    public static async Task<DownloadProgress?> RunQueueAsync(
        IReadOnlyList<int> ids,
        Func<int, CancellationToken, Task> download,
        Action<DownloadProgress> report,
        CancellationToken ct)
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
            catch (Exception)
            {
                tally = tally.Recording(succeeded: false);
            }
            if (ct.IsCancellationRequested) return null;
            report(tally);
        }
        return tally.Finishing();
    }

    private async Task RunAsync(IReadOnlyList<int> ids, Func<int, CancellationToken, Task> download, CancellationTokenSource cts)
    {
        var ct = cts.Token;
        var final = await RunQueueAsync(ids, download, p => Progress = p, ct);
        if (final is not { } done || ct.IsCancellationRequested) return;
        _downloadCts = null;
        Progress = done;
        Announcement?.Invoke(done.Failed == 0
            ? $"Downloaded {done.Done} stories for offline reading."
            : $"Downloads finished. {done.Done} succeeded, {done.Failed} failed.");
        try
        {
            await Task.Delay(FinishedBannerDuration, ct);
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
